import Foundation

/// The first signed guest uses Linux/arm64. This projection does not install
/// anything; it selects the exact registry archives a build would need.
public struct RaycastStoreBuildDependencies: Sendable {
    public enum Target: String, Codable, Sendable {
        case linuxArm64, macOSArm64
        var os: String { self == .macOSArm64 ? "darwin" : "linux" }
        var cpu: String { "arm64" }
    }
    public enum Failure: Error, Equatable {
        case rootLockMismatch
        case missing(String)
        case unsatisfiedVersion(String)
        case unsupportedRuntimeAPI(String)
        case unsupportedPackage(String)
    }

    public let packages: [RaycastStoreDependencyPlan.Node]
    public let runtimeAPIVersion: String?

    /// The versions must come from the signed runtime capability record, not
    /// extension metadata. Only @raycast/api may be supplied by that runtime.
    public init(source: RaycastStoreSourcePackage, supportedRuntimeAPIVersions: Set<String>, target: Target = .linuxArm64) throws {
        if let lockJSON = source.files["package-lock.json"] {
            self = try Self(
                plan: .init(lockJSON: lockJSON),
                dependencies: source.metadata.dependencies ?? [:],
                optionalDependencies: source.metadata.optionalDependencies ?? [:],
                peerDependencies: source.metadata.peerDependencies ?? [:],
                optionalPeers: Set((source.metadata.peerDependenciesMeta ?? [:]).filter { $0.value.optional == true }.keys),
                supportedRuntimeAPIVersions: supportedRuntimeAPIVersions, target: target
            )
        } else {
            packages = []
            runtimeAPIVersion = nil
        }
    }

    init(
        plan: RaycastStoreDependencyPlan, dependencies: [String: String],
        optionalDependencies: [String: String] = [:], peerDependencies: [String: String] = [:],
        optionalPeers: Set<String> = [],
        supportedRuntimeAPIVersions: Set<String>, target: Target = .linuxArm64
    ) throws {
        guard RaycastStoreDependencyPlan.matchesRuntimeDeclarations(plan.rootEdges, dependencies: dependencies,
            optional: optionalDependencies, peers: peerDependencies, optionalPeers: optionalPeers) else {
            throw Failure.rootLockMismatch
        }
        let indexed = Dictionary(uniqueKeysWithValues: plan.nodes.map { ($0.path, $0) })
        var queue = Array(plan.rootEdges.filter { $0.kind != .development }.reversed())
        var selected = Set<String>(), apiVersion: String?
        while let edge = queue.popLast() {
            let soft = edge.kind == .optional || edge.optionalPeer
            guard let path = edge.targetPath, let node = indexed[path] else {
                if soft { continue }
                throw Failure.missing(edge.name)
            }
            guard Version.satisfies(node.version, requirement: edge.requestedVersion) else {
                throw Failure.unsatisfiedVersion(edge.name)
            }
            if node.name == "@raycast/api" {
                guard supportedRuntimeAPIVersions.contains(node.version),
                      node.registryTarball != nil, !node.blockers.contains(.linkedOrBundled),
                      apiVersion == nil || apiVersion == node.version else {
                    throw Failure.unsupportedRuntimeAPI(node.version)
                }
                apiVersion = node.version
                // Only this edge is replaced. Its own build dependencies never
                // enter the worktree; an ordinary edge to esbuild is not exempt.
                continue
            }
            if !Self.permits(target.os, restrictions: node.os) || !Self.permits(target.cpu, restrictions: node.cpu) {
                if soft { continue }
                throw Failure.unsupportedPackage(node.name)
            }
            guard node.blockers(for: target).isEmpty else { throw Failure.unsupportedPackage(node.name) }
            if selected.insert(path).inserted { queue.append(contentsOf: node.edges.reversed()) }
        }
        packages = selected.sorted().compactMap { indexed[$0] }
        runtimeAPIVersion = apiVersion
    }

    private static func permits(_ value: String, restrictions: [String]?) -> Bool {
        guard let restrictions else { return true }
        if restrictions.contains("!" + value) { return false }
        let positive = restrictions.filter { !$0.hasPrefix("!") }
        return positive.isEmpty || positive.contains(value)
    }

    /// First supported subset: explicit stable versions, exact/caret/tilde,
    /// comparators, logical ranges, and wildcard. Do not approximate npm ranges we don't parse.
    private struct Version: Comparable {
        let major: Int, minor: Int, patch: Int

        init?(_ value: String) {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts.allSatisfy({
                      !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
                          && ($0 == "0" || $0.first != "0")
                  }),
                  let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
            else { return nil }
            self.major = major; self.minor = minor; self.patch = patch
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }

        static func satisfies(_ version: String, requirement: String) -> Bool {
            guard let candidate = Version(version) else { return false }
            let clauses = requirement.components(separatedBy: "||")
            guard clauses.count <= 8 else { return false }
            return clauses.contains { clause in
                let terms = clause.split(whereSeparator: \.isWhitespace)
                return (1...8).contains(terms.count) && terms.allSatisfy { term(candidate, String($0)) }
            }
        }

        static func term(_ candidate: Version, _ requirement: String) -> Bool {
            if let prefix = [">=", "<=", ">", "<", "="].first(where: { requirement.hasPrefix($0) }) {
                guard let bound = Version(String(requirement.dropFirst(prefix.count))) else { return false }
                switch prefix {
                case ">=": return candidate >= bound
                case "<=": return candidate <= bound
                case ">": return candidate > bound
                case "<": return candidate < bound
                default: return candidate == bound
                }
            }
            if requirement == "*" { return true }
            if requirement.hasPrefix("^") || requirement.hasPrefix("~") {
                guard let lower = Version(String(requirement.dropFirst())), candidate >= lower else { return false }
                if requirement.hasPrefix("~") {
                    return candidate.major == lower.major && candidate.minor == lower.minor
                }
                if lower.major > 0 { return candidate.major == lower.major }
                if lower.minor > 0 { return candidate.major == 0 && candidate.minor == lower.minor }
                return candidate == lower
            }
            return candidate == Version(requirement)
        }
    }
}
