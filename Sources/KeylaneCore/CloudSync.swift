import Foundation
import CryptoKit

public enum SyncCategory: String, Codable, CaseIterable, Sendable {
    case preferences, commands, quicklinks, snippets, layouts, extensions, chats, clipboard
    public var title: String {
        switch self {
        case .preferences: return "通用偏好"
        case .commands: return "快捷键、别名与收藏"
        case .quicklinks: return "快捷链接"
        case .snippets: return "文字片段"
        case .layouts: return "窗口布局"
        case .extensions: return "扩展偏好"
        case .chats: return "AI 聊天记录"
        case .clipboard: return "剪贴板历史"
        }
    }
}

public struct SyncStamp: Codable, Equatable, Comparable, Sendable {
    public let counter: UInt64
    public let device: UUID
    public static func < (a: Self, b: Self) -> Bool {
        a.counter == b.counter ? a.device.uuidString < b.device.uuidString : a.counter < b.counter
    }
}
public struct SyncEntry: Codable, Equatable, Sendable {
    public let category: SyncCategory
    public let id: String
    public let stamp: SyncStamp
    /// Nil is a durable explicit deletion; absence in a device snapshot is never a deletion.
    public let digest: String?
    public var key: String { category.rawValue + ":" + id }
}
public struct SyncManifest: Codable, Sendable {
    public var format = "keylane.sync"
    public var version = 1
    public let device: UUID
    public var deviceName: String
    public var updated: Date
    public var entries: [SyncEntry]
    public init(device: UUID, deviceName: String, entries: [SyncEntry], updated: Date = .now) {
        self.device = device; self.deviceName = deviceName; self.entries = entries; self.updated = updated
    }
    public func validate() throws {
        guard format == "keylane.sync", version == 1, entries.count <= 50_000,
              deviceName.utf8.count <= 256, Set(entries.map(\.key)).count == entries.count,
              entries.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 4096 && $0.stamp.counter > 0 && $0.stamp.counter < UInt64.max - 1 &&
                  ($0.digest == nil || SyncHash.isValid($0.digest!)) }) else { throw SyncError.invalidData }
    }
}
public enum SyncHash {
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func isValid(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
public enum SyncError: LocalizedError {
    case invalidData, unavailable, newerVersion, limit, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidData: return "同步资料格式无效，尚未应用。"
        case .unavailable: return "同步文件尚不可用，请检查 iCloud Drive，稍后重试。"
        case .newerVersion: return "同步资料由较新版本创建，请先更新 Keylane。"
        case .limit: return "同步资料超过本次处理上限，尚未应用。"
        case .cancelled: return "同步已暂停。"
        }
    }
}

/// Thread-confined local journal. Each device owns one cloud manifest; concurrent devices never
/// overwrite each other's file. Tombstones and Lamport stamps make merges deterministic offline.
public struct SyncJournal: Codable {
    public let device: UUID
    public private(set) var counter: UInt64 = 0
    public private(set) var entries: [String: SyncEntry] = [:]
    private var baseline: [String: String] = [:]
    public init(device: UUID = UUID()) { self.device = device }
    public mutating func observeClock(_ manifests: [SyncManifest]) throws {
        for document in manifests {
            try document.validate()
            counter = max(counter, document.entries.map(\.stamp.counter).max() ?? 0)
        }
    }
    public func contains(category: SyncCategory, id: String) -> Bool { entries[category.rawValue + ":" + id] != nil }
    public func needsPayload(category: SyncCategory, id: String, fingerprint: String) -> Bool {
        baseline[category.rawValue + ":" + id] != fingerprint
    }
    public mutating func observe(category: SyncCategory, values: [String: Data],
                                 explicitDeletions: Set<String> = [], inferDeletions: Bool = true) throws {
        let hashes = values.mapValues(SyncHash.digest)
        try observe(category: category, fingerprints: hashes, digests: hashes,
                    explicitDeletions: explicitDeletions, inferDeletions: inferDeletions)
    }
    public mutating func observe(category: SyncCategory, fingerprints: [String: String], digests: [String: String],
                                 explicitDeletions: Set<String> = [], inferDeletions: Bool = true) throws {
        let prefix = category.rawValue + ":"
        for (id, fingerprint) in fingerprints {
            let key = prefix + id
            if baseline[key] != fingerprint {
                guard let hash = digests[id] else { throw SyncError.invalidData }
                try change(category, id, digest: hash)
            }
            baseline[key] = fingerprint
        }
        let missing = baseline.keys.filter { $0.hasPrefix(prefix) && fingerprints[String($0.dropFirst(prefix.count))] == nil }
        for key in missing where inferDeletions || explicitDeletions.contains(String(key.dropFirst(prefix.count))) {
            try change(category, String(key.dropFirst(prefix.count)), digest: nil); baseline[key] = nil
        }
        for id in explicitDeletions where fingerprints[id] == nil && (entries[prefix + id] == nil || entries[prefix + id]?.digest != nil) {
            try change(category, id, digest: nil)
        }
    }
    private mutating func change(_ category: SyncCategory, _ id: String, digest: String?) throws {
        guard counter < UInt64.max - 1, !id.isEmpty, id.utf8.count <= 4096 else { throw SyncError.limit }
        counter += 1
        let value = SyncEntry(category: category, id: id, stamp: .init(counter: counter, device: device), digest: digest)
        entries[value.key] = value
    }
    public mutating func merge(_ manifests: [SyncManifest], categories: Set<SyncCategory>) throws -> [SyncEntry] {
        var changes: [String: SyncEntry] = [:]
        for manifest in manifests {
            try manifest.validate()
            for item in manifest.entries where categories.contains(item.category) {
                counter = max(counter, item.stamp.counter)
                if let old = changes[item.key] ?? entries[item.key] {
                    guard item.stamp != old.stamp || item.digest == old.digest else { throw SyncError.invalidData }
                    if old.stamp >= item.stamp { continue }
                }
                changes[item.key] = item
            }
        }
        return changes.values.sorted { $0.key < $1.key }
    }
    /// Called only after the module transaction succeeds; failed applications are retried from
    /// the previous persisted journal. Expired clipboard rows keep their observed baseline.
    public mutating func applied(_ entry: SyncEntry, fingerprint: String? = nil) { entries[entry.key] = entry; baseline[entry.key] = fingerprint ?? entry.digest }
    public func manifest(name: String) -> SyncManifest {
        .init(device: device, deviceName: String(name.prefix(64)), entries: entries.values.sorted { $0.key < $1.key })
    }
}

public struct SyncPayload {
    public let fingerprint: String
    public let read: () throws -> Data
    public init(data: Data) { fingerprint = SyncHash.digest(data); read = { data } }
    public init(fingerprint: String, read: @escaping () throws -> Data) { self.fingerprint = fingerprint; self.read = read }
}
public struct SyncLocalSnapshot {
    public var payloads: [String: SyncPayload]
    public var values: [String: Data] { get throws { try payloads.mapValues { try $0.read() } } }
    public var deletions: Set<String>
    public var inferDeletions: Bool
    public init(values: [String: Data], deletions: Set<String> = [], inferDeletions: Bool = true) {
        payloads = values.mapValues(SyncPayload.init); self.deletions = deletions; self.inferDeletions = inferDeletions
    }
    public init(payloads: [String: SyncPayload], deletions: Set<String> = [], inferDeletions: Bool = true) {
        self.payloads = payloads; self.deletions = deletions; self.inferDeletions = inferDeletions
    }
}

/// A module owns validation and persistence. The coordinator never edits a module's database.
public protocol SyncParticipant: AnyObject {
    var category: SyncCategory { get }
    func snapshot() throws -> SyncLocalSnapshot
    func apply(id: String, data: Data?) throws
    func current(id: String) throws -> Data?
    func fingerprint(id: String) throws -> String?
}
public extension SyncParticipant {
    func current(id: String) throws -> Data? { try snapshot().payloads[id]?.read() }
    func fingerprint(id: String) throws -> String? { try snapshot().payloads[id]?.fingerprint }
}

public extension Notification.Name { static let keylaneSyncSourceChanged = Notification.Name("org.keylane.sync.sourceChanged") }
