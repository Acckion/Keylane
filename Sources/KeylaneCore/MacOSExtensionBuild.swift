import CryptoKit
import Foundation

/// Inert, versioned build data. Source acquisition/SRI belongs to the Store
/// source verifier; a build digest is never an installation or execution grant.
public enum MacOSExtensionBuild {
    public enum Failure: Error, Equatable {
        case recipe, path, collision, limit, project, lifecycle, nativeContent
        case busy, stale, response, integrity, toolchainChanged
    }

    public struct Recipe: Codable, Equatable, Sendable {
        public let schema: Int
        public let policy: String
        public let target: String
        public let compilerVersion: String
        public let compilerSHA256: String
        public let helperSHA256: String

        /// Values come from the app-owned signed profile, never a manifest.
        public init(compilerSHA256: String, helperSHA256: String) throws {
            schema = 1; policy = "restricted-jsc-build-v1"; target = "darwin-arm64"
            compilerVersion = "0.25.5"
            self.compilerSHA256 = compilerSHA256; self.helperSHA256 = helperSHA256
            try validate()
        }

        public func validate() throws {
            guard schema == 1, policy == "restricted-jsc-build-v1", target == "darwin-arm64",
                  compilerVersion == "0.25.5", isDigest(compilerSHA256), isDigest(helperSHA256)
            else { throw Failure.recipe }
        }

        public var digest: String { get throws { try validate(); return hash(try MacOSExtensionBuild.encode(self)) } }
    }

    public struct File: Codable, Equatable, Sendable {
        public let path: String
        public let body: Data
        public init(path: String, body: Data) { self.path = path; self.body = body }
    }

    public struct Plan: Codable, Sendable {
        public let files: [File]
        public let entries: [String]

        public init(files: [File], entries: [String]) throws {
            guard (1...4096).contains(files.count), (1...256).contains(entries.count) else { throw Failure.limit }
            var seen = Set<String>(), directories: [String: String] = [:], total = 0
            for file in files {
                guard safePath(file.path) else { throw Failure.path }
                guard file.body.count <= 8 * 1024 * 1024, file.body.count <= 32 * 1024 * 1024 - total else { throw Failure.limit }
                total += file.body.count
                let folded = file.path.lowercased()
                guard seen.insert(folded).inserted, directories[folded] == nil else { throw Failure.collision }
                var parts = file.path.split(separator: "/"); parts.removeLast()
                while !parts.isEmpty {
                    let parent = parts.joined(separator: "/")
                    let key = parent.lowercased()
                    guard !seen.contains(key), directories[key] == nil || directories[key] == parent else { throw Failure.collision }
                    directories[key] = parent; parts.removeLast()
                }
                try rejectNative(file)
                if file.path == "package.json" || file.path.hasSuffix("/package.json") {
                    guard file.body.count <= 1024 * 1024,
                          let metadata = try JSONSerialization.jsonObject(with: file.body) as? [String: Any] else { throw Failure.project }
                    if let scripts = metadata["scripts"] {
                        guard let scripts = scripts as? [String: String] else { throw Failure.project }
                        guard !["preinstall", "install", "postinstall"].contains(where: { scripts[$0] != nil }) else { throw Failure.lifecycle }
                    }
                    guard metadata["gypfile"] as? Bool != true else { throw Failure.nativeContent }
                }
            }
            let exact = Set(files.map(\.path))
            guard exact.contains("package.json"), Set(entries).count == entries.count,
                  entries.allSatisfy({ safePath($0) && $0.hasPrefix("src/") && exact.contains($0)
                      && ["js", "jsx", "ts", "tsx"].contains(($0 as NSString).pathExtension) }) else { throw Failure.project }
            self.files = files.sorted { $0.path < $1.path }; self.entries = entries.sorted()
        }

        public init(from decoder: Decoder) throws {
            let value = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(files: value.decode([File].self, forKey: .files), entries: value.decode([String].self, forKey: .entries))
        }

        public var digest: String { get throws { hash(try MacOSExtensionBuild.encode(self)) } }
    }

    public struct Request: Codable, Sendable {
        public let id: UUID
        public let recipe: Recipe
        public let plan: Plan
        public init(id: UUID = UUID(), recipe: Recipe, plan: Plan) throws {
            try recipe.validate(); self.id = id; self.recipe = recipe; self.plan = plan
        }
        public func encoded() throws -> Data {
            try recipe.validate()
            let data = try MacOSExtensionBuild.encode(self)
            guard data.count <= 46 * 1024 * 1024 else { throw Failure.limit }
            return data
        }
        public static func decode(_ bytes: Data) throws -> Self {
            guard bytes.count <= 46 * 1024 * 1024 else { throw Failure.limit }
            let request = try JSONDecoder().decode(Self.self, from: bytes)
            try request.recipe.validate(); return request
        }
    }

    public struct Reply: Codable, Sendable {
        public let id: UUID
        public let recipeDigest: String
        public let projectDigest: String
        public let commands: [File]
        public init(id: UUID, recipeDigest: String, projectDigest: String, commands: [File]) {
            self.id = id; self.recipeDigest = recipeDigest; self.projectDigest = projectDigest; self.commands = commands
        }
    }

    public struct Inventory: Codable, Equatable, Sendable {
        public struct Item: Codable, Equatable, Sendable {
            public let path: String
            public let sha256: String
            public let bytes: Int
        }
        public let schema: Int
        public let recipeDigest: String
        public let projectDigest: String
        public let commands: [Item]
        public let resources: [Item]
    }

    /// Immutable verified output, not a signed receipt. The Store authority must
    /// seal this output and bind its source, installation, grants and generation.
    public struct Artifact: Sendable {
        public let inventory: Inventory
        public let commands: [File]
        public let resources: [File]
        public var digest: String { get throws { hash(try MacOSExtensionBuild.encode(inventory)) } }

        public init(request: Request, reply: Reply) throws {
            guard reply.id == request.id, reply.recipeDigest == (try request.recipe.digest),
                  reply.projectDigest == (try request.plan.digest), reply.commands.count == request.plan.entries.count,
                  Set(reply.commands.map(\.path)) == Set(request.plan.entries) else { throw Failure.response }
            var total = 0
            for file in reply.commands {
                guard !file.body.isEmpty, file.body.count <= 4 * 1024 * 1024,
                      file.body.count <= 12 * 1024 * 1024 - total else { throw Failure.limit }
                guard String(data: file.body, encoding: .utf8) != nil, !file.body.contains(0) else { throw Failure.integrity }
                total += file.body.count
            }
            commands = reply.commands.sorted { $0.path < $1.path }
            // Never accept a helper-supplied resource list. Preserve original
            // assets and license notices from the verified input snapshot.
            resources = request.plan.files.filter { file in
                let name = (file.path as NSString).lastPathComponent.lowercased()
                return file.path.hasPrefix("assets/") || name.hasPrefix("license") || name.hasPrefix("licence") || name.hasPrefix("notice") || name == "copying"
            }
            func item(_ file: File) -> Inventory.Item { .init(path: file.path, sha256: hash(file.body), bytes: file.body.count) }
            inventory = .init(schema: 1, recipeDigest: reply.recipeDigest, projectDigest: reply.projectDigest,
                              commands: commands.map(item), resources: resources.map(item))
        }
    }

    public protocol Service: Sendable {
        /// Verify OS signature, exact expected bytes, rights and app-owned profile.
        /// Returning a self-reported compiler hash is not verification.
        func verifiedRecipe() throws -> Recipe
        /// Return/throw only after all owned compiler processes have exited.
        func compile(_ request: Request) async throws -> Reply
        /// Idempotent cancellation for this request only, including pre-spawn.
        func cancel(_ requestID: UUID)
    }

    public actor Coordinator {
        private let expected: Recipe
        private let service: any Service
        private var building = false
        public init(expected: Recipe, service: any Service) throws {
            try expected.validate(); self.expected = expected; self.service = service
        }
        public func build(_ plan: Plan, isCurrent: @Sendable () async throws -> Bool) async throws -> Artifact {
            guard !building else { throw Failure.busy }
            building = true; defer { building = false }
            try Task.checkCancellation()
            guard try await isCurrent() else { throw Failure.stale }
            guard try service.verifiedRecipe() == expected else { throw Failure.toolchainChanged }
            let request = try Request(recipe: expected, plan: plan)
            let reply = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await service.compile(request)
            } onCancel: { service.cancel(request.id) }
            try Task.checkCancellation()
            guard try await isCurrent() else { throw Failure.stale }
            try Task.checkCancellation()
            guard try service.verifiedRecipe() == expected else { throw Failure.toolchainChanged }
            return try Artifact(request: request, reply: reply)
        }
    }

    public static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func safePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, path.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 64, 95, 43].contains($0)
        }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("-")
        }
    }
    private static func rejectNative(_ file: File) throws {
        let name = (file.path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let magic = Array(file.body.prefix(4))
        guard !["node", "so", "dylib", "dll", "exe", "a", "o", "wasm"].contains(ext), name != "binding.gyp",
              Array(file.body.prefix(2)) != [0x4d, 0x5a],
              ![[0x7f,0x45,0x4c,0x46], [0xcf,0xfa,0xed,0xfe], [0xce,0xfa,0xed,0xfe], [0xfe,0xed,0xfa,0xcf],
                [0xfe,0xed,0xfa,0xce], [0xca,0xfe,0xba,0xbe], [0xbe,0xba,0xfe,0xca], [0xca,0xfe,0xba,0xbf], [0xbf,0xba,0xfe,0xca]].contains(magic)
        else { throw Failure.nativeContent }
    }
}
