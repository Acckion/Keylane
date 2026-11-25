import Foundation

/// Commits both guest stores in one atomic replacement. An absent field falls
/// back to the corresponding pre-envelope file until that store is first written.
struct MacOSReviewedRaycastStorage: Sendable {
    private struct Snapshot: Codable {
        var cache: Data?
        var localStorage: Data?
        var supportFiles: Data?
    }

    let root: URL
    private static let limit = 168 * 1024

    func read(for ticket: StoreGuestRunTicket, cache allowedCache: Bool, localStorage allowedStorage: Bool,
              support allowedSupport: Bool = false) throws -> (cache: String?, localStorage: String?, supportFiles: [String: Data]?) {
        let snapshot = try load(ticket.installation.id)
        let cache = allowedCache
            ? try snapshot.cache.map { String(decoding: $0, as: UTF8.self) } ?? MacOSReviewedRaycastCache(root: root).read(for: ticket)
            : nil
        let storage = allowedStorage
            ? try snapshot.localStorage.map { String(decoding: $0, as: UTF8.self) } ?? MacOSReviewedRaycastLocalStorage(root: root).read(for: ticket)
            : nil
        let support = allowedSupport ? try snapshot.supportFiles.map {
            try JSONDecoder().decode([String: Data].self, from: $0)
        } ?? [:] : nil
        return (cache, storage, support)
    }

    func write(cache: Data?, localStorage: Data?, supportFiles: Data? = nil, for ticket: StoreGuestRunTicket) throws {
        var snapshot = try load(ticket.installation.id)
        if let cache {
            try MacOSReviewedRaycastCache.validate(cache)
            snapshot.cache = cache
        }
        if let localStorage {
            try MacOSReviewedRaycastLocalStorage.validate(localStorage)
            snapshot.localStorage = localStorage
        }
        if let supportFiles {
            try MacOSReviewedRaycastAssets.validateSupport(supportFiles)
            snapshot.supportFiles = supportFiles
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.limit else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: file(ticket.installation.id), options: .atomic)
    }

    func remove(installationID: UUID) {
        _ = Darwin.unlink(file(installationID.uuidString).path)
        MacOSReviewedRaycastCache(root: root).remove(installationID: installationID)
        MacOSReviewedRaycastLocalStorage(root: root).remove(installationID: installationID)
    }

    private func file(_ installationID: String) -> URL {
        let digest = MacOSExtensionBuild.hash(Data(installationID.utf8))
        return root.appendingPathComponent("storage-\(digest).json")
    }

    private func load(_ installationID: String) throws -> Snapshot {
        let descriptor = Darwin.open(file(installationID).path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor == -1 && errno == ENOENT { return .init() }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= Self.limit,
              let data = try handle.read(upToCount: Self.limit + 1), data.count <= Self.limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        if let cache = snapshot.cache { try MacOSReviewedRaycastCache.validate(cache) }
        if let localStorage = snapshot.localStorage { try MacOSReviewedRaycastLocalStorage.validate(localStorage) }
        if let supportFiles = snapshot.supportFiles { try MacOSReviewedRaycastAssets.validateSupport(supportFiles) }
        return snapshot
    }
}
