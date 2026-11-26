import Foundation

/// Source-as-data handoff to the isolated builder. No host directory, executable,
/// npm invocation, lifecycle hook or signing operation is created by this type.
public struct RaycastStoreSourcePackage: Sendable {
    public struct Metadata: Decodable, Sendable {
        public struct Command: Decodable, Sendable {
            public let name: String
            public let title: String
            public let mode: String
        }
        public let name: String
        public let title: String
        public let author: String?
        public let license: String?
        public let platforms: [String]?
        public let commands: [Command]
        public let dependencies: [String: String]?
        public let devDependencies: [String: String]?
        public let optionalDependencies: [String: String]?
        public let peerDependencies: [String: String]?
        public struct PeerMetadata: Decodable, Sendable { public let optional: Bool? }
        public let peerDependenciesMeta: [String: PeerMetadata]?
    }
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case fileSetMismatch, integrityFailure(String), missingManifest, invalidManifest
        case unsupportedPlatform, missingDependencyLock, invalidDependencyLock
        public var errorDescription: String? {
            switch self {
            case .fileSetMismatch: return "源码文件清单不完整或包含额外文件，请重新获取固定版本。"
            case .integrityFailure: return "源码内容与官方固定版本摘要不符，已停止准备。"
            case .missingManifest: return "扩展缺少 package.json。"
            case .invalidManifest: return "扩展命令清单无效，需要修正后再安装。"
            case .unsupportedPlatform: return "此扩展未声明支持 macOS，仍可在商店中浏览。"
            case .missingDependencyLock: return "扩展声明了依赖但没有 package-lock.json，无法固定依赖版本。"
            case .invalidDependencyLock: return "扩展的依赖锁文件格式无效或版本不受支持。"
            }
        }
    }
    private struct LockMetadata: Decodable { let lockfileVersion: Int }
    public let source: RaycastStoreSource
    /// Includes original manifests, lockfiles, license notices and source verbatim.
    public let files: [String: Data]
    public let metadata: Metadata
    public let licensePaths: [String]

    public init(snapshot: RaycastStoreSnapshot, files: [String: Data]) throws {
        guard Set(files.keys) == Set(snapshot.files.map(\.path)) else { throw Failure.fileSetMismatch }
        for file in snapshot.files {
            guard let bytes = files[file.path], file.verifies(bytes) else { throw Failure.integrityFailure(file.path) }
        }
        guard let manifest = files["package.json"] else { throw Failure.missingManifest }
        let metadata = try Self.installableMetadata(manifest)
        if [metadata.dependencies, metadata.devDependencies, metadata.optionalDependencies, metadata.peerDependencies].contains(where: { !($0 ?? [:]).isEmpty }) {
            guard let lock = files["package-lock.json"] else { throw Failure.missingDependencyLock }
            guard let metadata = try? JSONDecoder().decode(LockMetadata.self, from: lock),
                  (1...3).contains(metadata.lockfileVersion) else {
                throw Failure.invalidDependencyLock
            }
            // This only establishes that pinned dependency metadata is present.
            // The isolated resolver must still check lock/manifest consistency,
            // tarball integrity, dependency limits and unsupported native modules.
        }
        source = snapshot.source
        self.files = files
        self.metadata = metadata
        licensePaths = files.keys.filter {
            let name = $0.split(separator: "/").last?.lowercased() ?? ""
            return name.hasPrefix("license") || name.hasPrefix("licence") || name.hasPrefix("notice") || name == "copying"
        }.sorted()
    }

    static func installableMetadata(_ manifest: Data) throws -> Metadata {
        guard let metadata = try? JSONDecoder().decode(Metadata.self, from: manifest),
              RaycastStoreSource.validSlug(metadata.name), !metadata.title.isEmpty,
              (1...256).contains(metadata.commands.count),
              Set(metadata.commands.map { $0.name.lowercased() }).count == metadata.commands.count,
              metadata.commands.allSatisfy({ RaycastStoreSource.validSlug($0.name) && !$0.title.isEmpty && !$0.mode.isEmpty }) else {
            throw Failure.invalidManifest
        }
        guard RaycastPublicCatalog.declaresMacOS(metadata.platforms) else { throw Failure.unsupportedPlatform }
        return metadata
    }
}

extension RaycastPublicCatalog {
    /// Download every bounded inventory member and verify it before the builder can
    /// see the package. The aggregate remains capped by RaycastStoreSnapshot.
    public func prepareSource(_ source: RaycastStoreSource) async throws -> RaycastStoreSourcePackage {
        let snapshot = try await loadSnapshot(source)
        guard snapshot.files.contains(where: { $0.path == "package.json" }) else {
            throw RaycastStoreSourcePackage.Failure.missingManifest
        }
        let manifest = try await loadSourceFile("package.json", from: snapshot)
        _ = try RaycastStoreSourcePackage.installableMetadata(manifest)
        var files = ["package.json": manifest]
        for file in snapshot.files where file.path != "package.json" {
            try Task.checkCancellation()
            files[file.path] = try await loadSourceFile(file.path, from: snapshot)
        }
        return try RaycastStoreSourcePackage(snapshot: snapshot, files: files)
    }
}
