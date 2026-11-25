import Foundation

/// Ordered project files for the signed build protocol, kept as inert bytes.
/// This type never creates a directory, executes a command, or invokes npm.
public struct RaycastStoreBuildProject: Sendable {
    public enum Failure: Error, Equatable {
        case archiveSetMismatch, limit, unsafePath, conflictingPath
    }

    public struct File: Sendable {
        public let path: String
        public let body: Data
    }

    public let source: RaycastStoreSource
    public let files: [File]
    public let runtimeAPIVersion: String?
    public let target: RaycastStoreBuildDependencies.Target
    private static let maxFiles = 4_096
    private static let maxRawBytes = 32 * 1024 * 1024

    /// The caller fetches only the selected, pinned registry URLs. Content is
    /// independently validated against the plan recalculated from the source.
    public init(
        source: RaycastStoreSourcePackage, supportedRuntimeAPIVersions: Set<String>, tarballs: [String: Data],
        target: RaycastStoreBuildDependencies.Target = .linuxArm64
    ) throws {
        let selection = try RaycastStoreBuildDependencies(source: source, supportedRuntimeAPIVersions: supportedRuntimeAPIVersions, target: target)
        guard Set(tarballs.keys) == Set(selection.packages.map(\.path)) else { throw Failure.archiveSetMismatch }
        guard tarballs.values.reduce(into: 0, { total, body in
            total = min(Self.maxRawBytes + 1, total + min(Self.maxRawBytes + 1, body.count))
        }) <= Self.maxRawBytes else { throw Failure.limit }

        var entries: [File] = [], rawBytes = 0
        var fileKeys = Set<String>(), directories: [String: String] = [:]
        func append(_ path: String, body: Data) throws {
            guard Self.safe(path) else { throw Failure.unsafePath }
            guard entries.count < Self.maxFiles, body.count <= Self.maxRawBytes - rawBytes else { throw Failure.limit }
            let key = path.lowercased()
            guard directories[key] == nil, fileKeys.insert(key).inserted else { throw Failure.conflictingPath }
            var directoriesToCheck = path.split(separator: "/").dropLast()
            while !directoriesToCheck.isEmpty {
                let directory = directoriesToCheck.joined(separator: "/")
                let comparison = directory.lowercased()
                guard !fileKeys.contains(comparison),
                      directories[comparison] == nil || directories[comparison] == directory else { throw Failure.conflictingPath }
                directories[comparison] = directory
                directoriesToCheck = directoriesToCheck.dropLast()
            }
            rawBytes += body.count
            entries.append(.init(path: path, body: body))
        }

        for (path, body) in source.files {
            // Dependency slots can only be filled by verified registry archives.
            guard path.split(separator: "/").allSatisfy({ $0.lowercased() != "node_modules" }) else { throw Failure.conflictingPath }
            try append(path, body: body)
        }
        for node in selection.packages {
            guard let bytes = tarballs[node.path] else { throw Failure.archiveSetMismatch }
            let archive = try RaycastStoreDependencyArchive(tarball: bytes, node: node, target: target)
            if target == .macOSArm64,
               archive.installationPath.lowercased() == "node_modules/@keylane/reviewed-assets" {
                throw Failure.conflictingPath
            }
            for (path, body) in archive.files {
                try append(archive.installationPath + "/" + path, body: body)
            }
        }
        if target == .macOSArm64, let version = selection.runtimeAPIVersion {
            let reviewed = try MacOSReviewedRaycastCommand.buildEntries(for: source.source, apiVersion: version)
            if let capabilities = reviewed.first?.capabilities,
               !capabilities.isDisjoint(with: [MacOSReviewedRaycastAssets.capability, MacOSReviewedRaycastAssets.supportCapability, MacOSReviewedRaycastCache.capability]) {
                for file in MacOSReviewedRaycastAssets.files { try append(file.path, body: file.body) }
            }
            for file in MacOSReviewedRaycastAPI.files {
                try append(file.path, body: file.body)
            }
        }
        self.source = source.source
        files = entries.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        runtimeAPIVersion = selection.runtimeAPIVersion
        self.target = target
    }

    private static func safe(_ path: String) -> Bool {
        guard path.utf8.count <= 1_024, path.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
                [45, 46, 47, 64, 95, 43].contains($0)
        }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix("-")
        }
    }
}
