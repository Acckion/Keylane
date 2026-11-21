import Foundation

/// Metadata only: never opens file contents or initiates cloud downloads.
public struct IncomingFile: Identifiable, Equatable, Sendable {
    public let url: URL
    public let modified: Date
    public let size: Int64
    public let directory: Bool
    public var id: String { url.standardizedFileURL.path }
    public init(url: URL, modified: Date, size: Int64, directory: Bool = false) {
        self.url = url; self.modified = modified; self.size = size; self.directory = directory
    }
}

public enum IncomingFiles {
    public static func isCompleteName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return !name.hasPrefix(".") && !["crdownload", "download", "part", "partial", "tmp", "temp", "filepart"].contains(url.pathExtension.lowercased())
    }
    /// One folder level, so browsing Downloads never walks the whole disk.
    public static func scan(_ folder: URL) throws -> [IncomingFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var files: [IncomingFile] = []
        for url in urls {
            if Task.isCancelled { throw CancellationError() }
            guard isCompleteName(url), let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else { continue }
            if values.isUbiquitousItem == true && values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded { continue }
            files.append(.init(url: url, modified: values.contentModificationDate ?? .distantPast,
                               size: Int64(values.fileSize ?? 0), directory: values.isDirectory == true))
        }
        return files.sorted { $0.modified == $1.modified ? $0.id < $1.id : $0.modified > $1.modified }
    }
}

/// Seed existing files without emitting them; emit each newly observed path once after it settles.
/// This is a filesystem heuristic, not a browser download-completion API.
public struct IncomingFileTracker {
    private var known: Set<String>?
    private var pending: [String: (file: IncomingFile, since: Date)] = [:]
    public init() {}
    public var needsRescan: Bool { !pending.isEmpty }
    public mutating func reset() { known = nil; pending = [:] }
    public mutating func update(_ files: [IncomingFile], now: Date = Date(), settle: TimeInterval = 2) -> [IncomingFile] {
        update(files, now: now, settleFor: { _ in settle })
    }

    public func nextRescanDelay(now: Date = Date(), settleFor: (IncomingFile) -> TimeInterval) -> TimeInterval? {
        pending.values.map { entry in
            let stableSince = max(entry.since, entry.file.modified)
            return max(0, settleFor(entry.file) - now.timeIntervalSince(stableSince))
        }.min()
    }

    public mutating func update(_ files: [IncomingFile], now: Date = Date(),
                                settleFor: (IncomingFile) -> TimeInterval) -> [IncomingFile] {
        let paths = Set(files.map(\.id))
        guard let old = known else { known = paths; return [] }
        pending = pending.filter { paths.contains($0.key) }
        var ready: [IncomingFile] = []
        for file in files where !old.contains(file.id) && IncomingFiles.isCompleteName(file.url) {
            if let previous = pending[file.id], previous.file == file {
                if now.timeIntervalSince(max(previous.since, file.modified)) >= settleFor(file) {
                    ready.append(file); pending.removeValue(forKey: file.id)
                }
            } else { pending[file.id] = (file, now) }
        }
        known = old.intersection(paths).union(ready.map(\.id))
        return ready
    }
}
