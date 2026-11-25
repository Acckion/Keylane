import Foundation
import CryptoKit

/// Static inventory only, never build authorization. Range satisfaction, manifest
/// agreement, archive contents and platform compatibility still need validation.
/// Does not download, extract, write files, run npm or execute package code.
public struct RaycastStoreDependencyPlan: Sendable {
    public enum Failure: Error, Equatable { case oversized, invalidLock, invalidPath(String), invalidVersion(String), invalidIntegrity(String) }
    public enum Blocker: String, Sendable { case unsupportedSource, installScript, nativeOrPlatformSpecific, linkedOrBundled, missingDependency }
    public struct Edge: Sendable {
        public enum Kind: String, Sendable { case production, development, optional, peer }
        public let name: String
        public let requestedVersion: String
        public let kind: Kind
        public let targetPath: String?
        public let optionalPeer: Bool
    }
    public struct Node: Sendable {
        public let path: String
        public let name: String
        public let version: String
        public let dev: Bool
        public let optional: Bool
        public let devOptional: Bool
        public let os: [String]?
        public let cpu: [String]?
        public let hasNativeBuild: Bool
        public let edges: [Edge]
        public let blockers: [Blocker]
        public let registryTarball: URL?
        public let integrity: String?
        func blockers(for target: RaycastStoreBuildDependencies.Target) -> [Blocker] {
            // Only the explicit Darwin projection can qualify platform-only
            // metadata. Native build markers and all other blockers remain.
            guard target == .macOSArm64, !hasNativeBuild, permits(target) else { return blockers }
            return blockers.filter { $0 != .nativeOrPlatformSpecific }
        }
        func permits(_ target: RaycastStoreBuildDependencies.Target) -> Bool {
            func accepts(_ value: String, _ rules: [String]?) -> Bool {
                guard let rules else { return true }
                return !rules.contains("!" + value) && (rules.allSatisfy { $0.hasPrefix("!") } || rules.contains(value))
            }
            return accepts(target.os, os) && accepts(target.cpu, cpu)
        }
        /// Compressed bytes only; not extraction, package review or permission to run.
        public func verifiesTarball(_ bytes: Data) -> Bool {
            guard registryTarball != nil, bytes.count > 0, bytes.count <= 16 * 1024 * 1024,
                  let integrity, let digest = Data(base64Encoded: String(integrity.dropFirst(7))) else { return false }
            return Data(SHA512.hash(data: bytes)) == digest
        }
    }
    public let nodes: [Node]
    public let rootEdges: [Edge]
    public let requiresIsolatedValidation = true
    /// Conservative production closure, including optional/peer edges. Dev-only
    /// roots are excluded, but platform selection is NOT performed here. This set
    /// must not be treated as a Linux arm64 ready-to-run or ready-to-build set.
    public var productionReachablePaths: Set<String> {
        let indexed = Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })
        var queue = rootEdges.filter { $0.kind != .development }.compactMap(\.targetPath)
        var seen = Set<String>()
        while let path = queue.popLast() {
            guard seen.insert(path).inserted, let node = indexed[path] else { continue }
            queue.append(contentsOf: node.edges.compactMap(\.targetPath))
        }
        return seen
    }
    /// npm optional declarations override production entries of the same
    /// name. Compare the normalized runtime edges, not dev-only declarations.
    static func matchesRuntimeDeclarations(_ edges: [Edge], dependencies: [String: String],
                                           optional: [String: String], peers: [String: String],
                                           optionalPeers: Set<String>) -> Bool {
        let declarations: [(Edge.Kind, [String: String])] = [
            (.production, dependencies.filter { optional[$0.key] == nil }),
            (.optional, optional), (.peer, peers)
        ]
        return declarations.allSatisfy { kind, fields in
            let locked = edges.filter { $0.kind == kind }
            return locked.count == fields.count && locked.allSatisfy { fields[$0.name] == $0.requestedVersion }
        } && optionalPeers == Set(edges.filter(\.optionalPeer).map(\.name))
    }

    private struct Lock: Decodable { let lockfileVersion: Int; let packages: [String: Entry] }
    private struct Entry: Decodable {
        struct PeerMetadata: Decodable { let optional: Bool? }
        var peerDependenciesMeta: [String: PeerMetadata]?
        var version: String?; var resolved: String?; var integrity: String?
        var dev: Bool?; var optional: Bool?; var devOptional: Bool?
        var hasInstallScript: Bool?; var link: Bool?; var inBundle: Bool?
        var os: [String]?; var cpu: [String]?; var gypfile: Bool?
        var dependencies: [String: String]?; var devDependencies: [String: String]?
        var optionalDependencies: [String: String]?; var peerDependencies: [String: String]?
    }
    public init(lockJSON: Data) throws {
        guard lockJSON.count <= 2 * 1024 * 1024 else { throw Failure.oversized }
        guard let lock = try? JSONDecoder().decode(Lock.self, from: lockJSON),
              lock.lockfileVersion == 3, let root = lock.packages[""], lock.packages.count <= 4097 else { throw Failure.invalidLock }
        let paths = Set(lock.packages.keys)
        var folded = Set<String>()
        for path in paths where !path.isEmpty {
            guard Self.packageName(path) != nil, path.utf8.count <= 1024,
                  folded.insert(path.lowercased()).inserted else { throw Failure.invalidPath(path) }
        }
        // Every nested installation must have its containing package in the lock.
        for path in paths where !path.isEmpty {
            if let marker = path.range(of: "/node_modules/", options: .backwards) {
                guard paths.contains(String(path[..<marker.lowerBound])) else { throw Failure.invalidPath(path) }
            }
        }
        var edgeCount = 0
        func edges(_ entry: Entry, at path: String, includeDev: Bool) throws -> [Edge] {
            var result: [Edge] = []
            let groups: [(Edge.Kind, [String: String])] = [(.production, entry.dependencies ?? [:]),
                (.development, includeDev ? entry.devDependencies ?? [:] : [:]),
                (.optional, entry.optionalDependencies ?? [:]), (.peer, entry.peerDependencies ?? [:])]
            for (kind, requirements) in groups {
                guard requirements.count <= 1024 else { throw Failure.oversized }
                for (name, spec) in requirements.sorted(by: { $0.key < $1.key }) {
                    guard Self.validName(name), !spec.isEmpty, spec.utf8.count <= 512 else { throw Failure.invalidLock }
                    if kind == .production, entry.optionalDependencies?[name] != nil { continue }
                    result.append(Edge(name: name, requestedVersion: spec, kind: kind,
                        targetPath: Self.resolve(name, from: path, peer: kind == .peer, paths: paths),
                        optionalPeer: kind == .peer && entry.peerDependenciesMeta?[name]?.optional == true))
                }
            }
            edgeCount += result.count
            guard edgeCount <= 32768 else { throw Failure.oversized }
            return result
        }
        rootEdges = try edges(root, at: "", includeDev: true)
        var result: [Node] = []
        for path in paths.sorted() where !path.isEmpty {
            let entry = lock.packages[path]!, name = Self.packageName(path)!
            guard let version = entry.version, Self.exactVersion(version) else { throw Failure.invalidVersion(path) }
            if let integrity = entry.integrity {
                guard integrity.hasPrefix("sha512-"),
                      let digest = Data(base64Encoded: String(integrity.dropFirst(7))), digest.count == 64,
                      "sha512-" + digest.base64EncodedString() == integrity else { throw Failure.invalidIntegrity(path) }
            }
            let basename = String(name.split(separator: "/").last!)
            let canonical = "https://registry.npmjs.org/\(name)/-/\(basename)-\(version).tgz"
            let url = entry.resolved == canonical && entry.integrity != nil ? URL(string: canonical) : nil
            var blockers: [Blocker] = []
            if url == nil { blockers.append(.unsupportedSource) }
            if entry.hasInstallScript == true { blockers.append(.installScript) }
            if entry.gypfile == true || entry.os != nil || entry.cpu != nil { blockers.append(.nativeOrPlatformSpecific) }
            if entry.link == true || entry.inBundle == true { blockers.append(.linkedOrBundled) }
            let dependencies = try edges(entry, at: path, includeDev: false)
            if dependencies.contains(where: { $0.targetPath == nil && $0.kind == .production }) { blockers.append(.missingDependency) }
            result.append(Node(path: path, name: name, version: version, dev: entry.dev ?? false,
                optional: entry.optional ?? false, devOptional: entry.devOptional ?? false, os: entry.os, cpu: entry.cpu, hasNativeBuild: entry.gypfile == true,
                edges: dependencies, blockers: blockers, registryTarball: url, integrity: entry.integrity))
        }
        nodes = result
    }
    private static func validName(_ value: String) -> Bool {
        value.range(of: #"^(?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil && value.utf8.count <= 214
    }
    private static func packageName(_ path: String) -> String? {
        let parts = path.components(separatedBy: "/")
        var i = 0, last: String?
        while i < parts.count {
            guard parts[i] == "node_modules", i + 1 < parts.count else { return nil }
            i += 1
            var name = parts[i]; i += 1
            if name.hasPrefix("@") {
                guard i < parts.count else { return nil }
                name += "/" + parts[i]; i += 1
            }
            guard validName(name), name != "node_modules" else { return nil }
            last = name
        }
        return last
    }
    private static func exactVersion(_ value: String) -> Bool {
        // Pre-release/build metadata unsupported in this first slice, not coerced.
        value.utf8.count <= 64 && value.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil
    }
    private static func resolve(_ name: String, from path: String, peer: Bool, paths: Set<String>) -> String? {
        var scope = path
        if peer, let marker = scope.range(of: "node_modules/", options: .backwards) {
            scope = String(scope[..<marker.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        while true {
            let candidate = (scope.isEmpty ? "" : scope + "/") + "node_modules/" + name
            if paths.contains(candidate) { return candidate }
            guard let marker = scope.range(of: "node_modules/", options: .backwards) else { return nil }
            scope = String(scope[..<marker.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
    }
}
