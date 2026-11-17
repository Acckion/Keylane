import Foundation
import CryptoKit

/// Local-only shelf storage. External references and shelf-owned assets never share a cleanup path.
public final class DropShelfStore {
    public struct Item: Codable, Identifiable, Equatable {
        public enum Kind: String, Codable { case file, text, link, image }
        public let id: UUID
        public var kind: Kind
        public var title: String
        public var url: URL?
        public var bookmark: Data?
        public var value: String?
        public var asset: String?
        public var digest: String?
    }
    public struct Shelf: Codable, Identifiable, Equatable {
        public let id: UUID
        public var title: String
        public var pinned: Bool
        public var items: [Item]
    }
    private struct Archive: Codable { var version = 1; var shelves: [Shelf] }
    public enum Failure: LocalizedError {
        case invalidArchive, unavailable, invalidAsset, limit
        public var errorDescription: String? {
            switch self {
            case .invalidArchive: return "暂存记录无法读取，原记录已保留。"
            case .unavailable: return "文件已消失或无法读取。"
            case .invalidAsset: return "临时文件不属于此暂存架。"
            case .limit: return "暂存内容超出限制（最多 1000 项，单个生成内容 64 MiB）。"
            }
        }
    }
    public private(set) var shelves: [Shelf] = []
    public var didChange: (() -> Void)?
    public let directory: URL
    private let fm = FileManager.default
    public var assetsDirectory: URL { directory.appendingPathComponent("Assets", isDirectory: true) }
    public init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent("shelves.json")
        if fm.fileExists(atPath: archive.path) {
            guard let bytes = try? Data(contentsOf: archive), bytes.count <= 32 * 1024 * 1024,
                  let decoded = try? JSONDecoder().decode(Archive.self, from: bytes), decoded.version == 1,
                  Set(decoded.shelves.map(\.id)).count == decoded.shelves.count,
                  decoded.shelves.allSatisfy({ $0.items.count <= 1000 && $0.items.allSatisfy { Self.safeAsset($0.asset) } }) else {
                throw Failure.invalidArchive
            }
            shelves = decoded.shelves
        }
    }
    public func shelf(_ id: UUID) -> Shelf? { shelves.first { $0.id == id } }
    @discardableResult public func create() throws -> UUID {
        let id = UUID()
        try change { shelves.insert(Shelf(id: id, title: "暂存架", pinned: false, items: []), at: 0) }
        return id
    }
    public func rename(_ id: UUID, title: String) throws {
        try change { if let index = index(id) { shelves[index].title = String(title.prefix(120)) } }
    }
    public func pin(_ id: UUID, value: Bool) throws {
        try change { if let index = index(id) { shelves[index].pinned = value } }
    }
    /// Closing preserves recent contents. At most ten unpinned shelves survive history trimming.
    public func remember(_ id: UUID, keeping open: Set<UUID> = []) throws {
        try change {
            guard let index = index(id) else { return }
            let shelf = shelves.remove(at: index)
            shelves.insert(shelf, at: 0)
            var recent = 0
            shelves = shelves.filter { shelf in
                if shelf.pinned || open.contains(shelf.id) { return true }
                recent += 1
                return recent <= 10 && !shelf.items.isEmpty
            }
        }
        // Asset deletion is deliberately deferred: in-flight drags may still use an exported URL.
    }
    public func remove(_ id: UUID, items: Set<UUID>? = nil) throws {
        try change {
            guard let index = index(id) else { return }
            if let items { shelves[index].items.removeAll { items.contains($0.id) } }
            else { shelves[index].items.removeAll(); shelves[index].pinned = false }
        }
    }
    public func deleteShelf(_ id: UUID) throws {
        try change { shelves.removeAll { $0.id == id } }
    }
    public func reorder(_ id: UUID, item: UUID, before: UUID?) throws {
        try change {
            guard let index = index(id), let old = shelves[index].items.firstIndex(where: { $0.id == item }) else { return }
            let value = shelves[index].items.remove(at: old)
            let position = before.flatMap { next in shelves[index].items.firstIndex { $0.id == next } } ?? shelves[index].items.count
            shelves[index].items.insert(value, at: position)
        }
    }
    @discardableResult public func addFile(_ url: URL, to id: UUID) throws -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, fm.isReadableFile(atPath: url.path) else { throw Failure.unavailable }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let value = Item(id: UUID(), kind: .file, title: url.lastPathComponent, url: url, bookmark: bookmark)
        return try append(value, to: id)
    }
    @discardableResult public func addText(_ text: String, link: Bool = false, to id: UUID) throws -> Bool {
        guard text.utf8.count <= 64 * 1024 * 1024 else { throw Failure.limit }
        let title = String(text.prefix(80)).replacingOccurrences(of: "\n", with: " ")
        return try append(Item(id: UUID(), kind: link ? .link : .text, title: title, value: text), to: id)
    }
    @discardableResult public func addAsset(_ data: Data, name: String, kind: Item.Kind, to id: UUID) throws -> Bool {
        guard data.count <= 64 * 1024 * 1024 else { throw Failure.limit }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard shelf(id) != nil else { throw Failure.invalidArchive }
        if shelf(id)?.items.contains(where: { $0.kind == kind && $0.digest == digest }) == true { return false }
        let filename = UUID().uuidString + "." + (name as NSString).pathExtension
        let target = assetsDirectory.appendingPathComponent(filename)
        try data.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        do { return try append(Item(id: UUID(), kind: kind, title: name, bookmark: try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), asset: filename, digest: digest), to: id) }
        catch { try? fm.removeItem(at: target); throw error }
    }
    /// Promised directories/files are moved only from an explicitly supplied owned import directory.
    @discardableResult public func adoptPromise(_ url: URL, from batch: URL, to id: UUID) throws -> Bool {
        let root = batch.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
              batch.deletingLastPathComponent().standardizedFileURL == directory.appendingPathComponent("Incoming").standardizedFileURL,
              fm.isReadableFile(atPath: url.path), (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw Failure.invalidAsset }
        let filename = UUID().uuidString + "-" + url.lastPathComponent
        let target = assetsDirectory.appendingPathComponent(filename)
        try fm.moveItem(at: url, to: target)
        do { return try append(Item(id: UUID(), kind: .file, title: url.lastPathComponent, bookmark: try target.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), asset: filename), to: id) }
        catch { try? fm.removeItem(at: target); throw error }
    }
    public func resolve(_ item: Item) throws -> URL? {
        if item.asset != nil || item.kind == .file {
            if let bookmark = item.bookmark {
                var stale = false
                let options: URL.BookmarkResolutionOptions = item.asset == nil ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting]
                return try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            if let asset = item.asset {
                guard Self.safeAsset(asset) else { throw Failure.invalidAsset }
                return assetsDirectory.appendingPathComponent(asset)
            }
            guard let url = item.url, url.isFileURL else { throw Failure.unavailable }
            return url
        }
        return nil
    }
    /// Persist the new bookmark/path after external moves; never mutate the referenced file.
    public func refreshReference(_ item: Item, in id: UUID, resolved url: URL) throws {
        guard item.kind == .file, item.asset == nil,
              item.url != url || item.title != url.lastPathComponent,
              let shelfIndex = index(id), let itemIndex = shelves[shelfIndex].items.firstIndex(where: { $0.id == item.id }) else { return }
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try change {
            shelves[shelfIndex].items[itemIndex].url = url
            shelves[shelfIndex].items[itemIndex].bookmark = bookmark
            shelves[shelfIndex].items[itemIndex].title = url.lastPathComponent
        }
    }
    /// Run only at startup before any file promises or outgoing drags exist.
    public func collectUnusedAssets() throws {
        let retained = Set(shelves.flatMap(\.items).compactMap(\.asset))
        for url in try fm.contentsOfDirectory(at: assetsDirectory, includingPropertiesForKeys: nil) where !retained.contains(url.lastPathComponent) {
            try fm.removeItem(at: url)
        }
        let incoming = directory.appendingPathComponent("Incoming")
        if fm.fileExists(atPath: incoming.path) { try fm.removeItem(at: incoming) }
    }
    private static func safeAsset(_ name: String?) -> Bool {
        guard let name else { return true }
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\")
    }
    private func index(_ id: UUID) -> Int? { shelves.firstIndex { $0.id == id } }
    private func append(_ item: Item, to id: UUID) throws -> Bool {
        guard let index = index(id) else { throw Failure.invalidArchive }
        guard shelves[index].items.count < 1000 else { throw Failure.limit }
        let duplicate = shelves[index].items.contains {
            if item.kind == .file, item.asset == nil { return (try? resolve($0))?.standardizedFileURL == item.url?.standardizedFileURL }
            return item.value != nil && $0.kind == item.kind && $0.value == item.value
        }
        guard !duplicate else { return false }
        try change { shelves[index].items.append(item) }
        return true
    }
    private func change(_ body: () -> Void) throws {
        let old = shelves
        body()
        do {
            let data = try JSONEncoder().encode(Archive(shelves: shelves))
            guard data.count <= 32 * 1024 * 1024 else { throw Failure.limit }
            let url = directory.appendingPathComponent("shelves.json")
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { shelves = old; throw error }
        didChange?()
    }
}
