import Foundation

/// Coordinates immutable content and a per-device manifest with iCloud Drive. No live SQLite
/// file, access bookmark or credential is ever placed in this directory.
public final class SyncDriveTransport {
    public static let maximumBlobBytes = 96 * 1024 * 1024
    private let root: URL
    private let fm = FileManager.default
    private let discoveredManifests: [URL]
    public init(directory: URL, discoveredManifests: [URL] = []) throws {
        self.discoveredManifests = discoveredManifests
        root = directory.standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try validate(root, directory: true)
        for folder in ["devices", "objects"] {
            let url = root.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try validate(url, directory: true)
        }
    }
    private func validate(_ url: URL, directory: Bool = false) throws {
        let resource = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard resource.isSymbolicLink != true, directory ? resource.isDirectory == true : resource.isRegularFile == true else { throw SyncError.invalidData }
    }
    private func read(_ url: URL, maximum: Int) throws -> Data {
        guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw SyncError.invalidData }
        var error: NSError?, result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = Result {
                try self.validate(coordinated)
                let values = try coordinated.resourceValues(forKeys: [.fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try? self.fm.startDownloadingUbiquitousItem(at: coordinated); throw SyncError.unavailable
                }
                guard let size = values.fileSize, size <= maximum else { throw SyncError.limit }
                let data = try Data(contentsOf: coordinated)
                guard data.count <= maximum else { throw SyncError.limit }
                return data
            }
        }
        if let error { throw error }; return try result?.get() ?? { throw SyncError.unavailable }()
    }
    private func write(_ data: Data, to url: URL) throws {
        guard (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw SyncError.invalidData }
        var error: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { coordinated in
            result = Result {
                if self.fm.fileExists(atPath: coordinated.path) { try self.validate(coordinated) }
                try data.write(to: coordinated, options: .atomic)
            }
        }
        if let error { throw error }; try result?.get()
    }
    public func store(_ data: Data) throws -> String {
        guard data.count <= Self.maximumBlobBytes else { throw SyncError.limit }
        let digest = SyncHash.digest(data), url = root.appendingPathComponent("objects/" + digest)
        if !fm.fileExists(atPath: url.path) { try write(data, to: url) }
        else {
            try validate(url)
            guard SyncHash.digest(try read(url, maximum: Self.maximumBlobBytes)) == digest else { throw SyncError.invalidData }
        }
        return digest
    }
    public func load(_ digest: String) throws -> Data {
        guard SyncHash.isValid(digest) else { throw SyncError.invalidData }
        let data = try read(root.appendingPathComponent("objects/" + digest), maximum: Self.maximumBlobBytes)
        guard SyncHash.digest(data) == digest else { throw SyncError.invalidData }
        return data
    }
    public func manifests() throws -> [SyncManifest] {
        let directory = root.appendingPathComponent("devices", isDirectory: true)
        let listed = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let files = Set((listed + discoveredManifests).filter {
            $0.pathExtension == "json" && $0.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        })
        guard files.count <= 128 else { throw SyncError.limit }
        var totalEntries = 0
        return try files.flatMap { url -> [SyncManifest] in
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return [] }
            // File coordination does not resolve iCloud conflict versions automatically.
            let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
            return try ([url] + versions.map(\.url)).map {
                let document = try JSONDecoder().decode(SyncManifest.self, from: read($0, maximum: 16 * 1024 * 1024))
                try document.validate()
                totalEntries += document.entries.count
                guard totalEntries <= 100_000 else { throw SyncError.limit }
                return document
            }
        }
    }
    public func publish(_ manifest: SyncManifest) throws {
        try manifest.validate()
        try write(SyncHash.encode(manifest), to: root.appendingPathComponent("devices/" + manifest.device.uuidString + ".json"))
    }
}
