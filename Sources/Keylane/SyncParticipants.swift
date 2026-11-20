import Foundation
import KeylaneCore

/// Explicit fields only: adding a feature never accidentally publishes its tokens or grants.
final class DefaultsSyncParticipant: SyncParticipant {
    let category: SyncCategory
    private let defaults: UserDefaults
    private let keys: [String]
    private let dictionaries: Set<String>
    init(_ category: SyncCategory, defaults: UserDefaults = .standard, keys: [String], dictionaries: Set<String> = []) {
        self.category = category; self.defaults = defaults; self.keys = keys; self.dictionaries = dictionaries
    }
    func snapshot() throws -> SyncLocalSnapshot {
        var values: [String: Data] = [:]
        for key in keys {
            guard let value = defaults.object(forKey: key) else { continue }
            if dictionaries.contains(key), let map = value as? [String: Any] {
                for (id, item) in map { values[key + "/" + id] = try encode(item) }
            } else { values[key] = try encode(value) }
        }
        return .init(values: values)
    }
    private func encode(_ value: Any) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
    }
    func apply(id: String, data: Data?) throws {
        let key = keys.first { id == $0 || (dictionaries.contains($0) && id.hasPrefix($0 + "/")) }
        guard let key else { throw SyncError.invalidData }
        let value: Any?
        if let data {
            guard data.count <= 2 * 1024 * 1024,
                  let wrapper = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let item = wrapper["value"] else { throw SyncError.invalidData }
            value = item
        } else { value = nil }
        if dictionaries.contains(key), id != key {
            let item = String(id.dropFirst(key.count + 1))
            var map = defaults.dictionary(forKey: key) ?? [:]
            map[item] = value; defaults.set(map, forKey: key)
        } else { defaults.set(value, forKey: key) }
    }
}
final class QuicklinksSyncParticipant: SyncParticipant {
    let category = SyncCategory.quicklinks
    func snapshot() throws -> SyncLocalSnapshot {
        .init(values: try Dictionary(uniqueKeysWithValues: QuicklinkLibrary.load(from: .standard).links.map { ($0.id, try SyncHash.encode($0)) }))
    }
    func apply(id: String, data: Data?) throws {
        var library = try QuicklinkLibrary.load(from: .standard)
        var links = library.links.filter { $0.id != id }
        if let data {
            let link = try JSONDecoder().decode(Quicklink.self, from: data)
            guard link.id == id else { throw SyncError.invalidData }
            // Same validation as local library persistence; no automatic URL execution.
            links.append(link)
        }
        library = QuicklinkLibrary(links: links); try library.save(to: .standard)
    }
}
final class SnippetsSyncParticipant: SyncParticipant {
    let category = SyncCategory.snippets
    private let url: URL
    init(url: URL) { self.url = url }
    func snapshot() throws -> SyncLocalSnapshot {
        .init(values: try Dictionary(uniqueKeysWithValues: Store(url: url).records(kind: "snippet").map { ($0.id, try SyncHash.encode($0)) }))
    }
    func apply(id: String, data: Data?) throws {
        let store = try Store(url: url)
        if let data {
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.id == id, record.kind == "snippet" else { throw SyncError.invalidData }
            _ = try Snippet.fromRecord(record)
            try store.save(record)
        } else { try store.remove(id: id) }
    }
}
final class ClipboardSyncParticipant: SyncParticipant {
    let category = SyncCategory.clipboard
    private let directory: URL
    private var cachedStore: ClipboardStore?
    init(directory: URL) { self.directory = directory }
    private func store() throws -> ClipboardStore {
        let defaults = UserDefaults.standard
        if let cachedStore { return cachedStore }
        let result = try ClipboardStore(directory: directory, limits: .init(
            maxItems: defaults.object(forKey: "clipboardMaxItems") as? Int ?? 500,
            retentionDays: defaults.object(forKey: "clipboardRetentionDays") as? Int ?? 30))
        cachedStore = result; return result
    }
    func snapshot() throws -> SyncLocalSnapshot { try store().syncSnapshot() }
    func current(id: String) throws -> Data? { try store().syncValue(id: id) }
    func fingerprint(id: String) throws -> String? { try store().syncFingerprint(id: id) }
    func apply(id: String, data: Data?) throws {
        if let data {
            let clip = try JSONDecoder().decode(SyncedClip.self, from: data)
            let days = UserDefaults.standard.object(forKey: "clipboardRetentionDays") as? Int ?? 30
            if !clip.pinned && days > 0 && clip.copied < Date().addingTimeInterval(-Double(days) * 86400) { return }
        }
        try store().applySync(id: id, data: data)
    }
}

extension AIChatHistory: SyncParticipant {
    var category: SyncCategory { .chats }
    struct SyncChat: Codable {
        let id: UUID
        let content: AIChatRecord.Content
        let title: String
        let updated: Date
        let pinned: Bool
        let archived: Bool
    }
    func snapshot() throws -> SyncLocalSnapshot {
        var values: [String: Data] = [:]
        for summary in try list() {
            if let record = try load(summary.id) {
                values[summary.id.uuidString] = try SyncHash.encode(SyncChat(id: summary.id, content: record.content,
                    title: summary.title, updated: summary.updated, pinned: summary.pinned, archived: summary.archived))
            }
        }
        return .init(values: values)
    }
    func apply(id: String, data: Data?) throws {
        guard let uuid = UUID(uuidString: id) else { throw SyncError.invalidData }
        if let data {
            let chat = try JSONDecoder().decode(SyncChat.self, from: data)
            guard chat.id == uuid, chat.content.turns.count <= 10000 else { throw SyncError.invalidData }
            try save(.init(id: uuid, content: chat.content))
            try update(uuid, change: .rename(chat.title)); try update(uuid, change: .pin(chat.pinned)); try update(uuid, change: .archive(chat.archived))
            try preserveSyncDate(uuid, date: chat.updated)
        } else { try remove(uuid) }
    }
}

final class LayoutsSyncParticipant: SyncParticipant {
    let category = SyncCategory.layouts
    private let key = "windowManagement.customActions"
    private func archive() throws -> WindowActionsArchive {
        guard let data = UserDefaults.standard.data(forKey: key) else { return WindowActionsArchive(actions: []) }
        let result = try JSONDecoder().decode(WindowActionsArchive.self, from: data)
        guard result.isValid else { throw SyncError.invalidData }; return result
    }
    func snapshot() throws -> SyncLocalSnapshot {
        .init(values: try Dictionary(uniqueKeysWithValues: archive().actions.map { ($0.id.uuidString, try SyncHash.encode($0)) }))
    }
    func apply(id: String, data: Data?) throws {
        var actions = try archive().actions.filter { $0.id.uuidString != id }
        if let data {
            let action = try JSONDecoder().decode(CustomWindowAction.self, from: data)
            guard action.id.uuidString == id, action.isValid else { throw SyncError.invalidData }; actions.append(action)
        }
        UserDefaults.standard.set(try SyncHash.encode(WindowActionsArchive(actions: actions)), forKey: key)
    }
}

final class CommandsSyncParticipant: SyncParticipant {
    let category = SyncCategory.commands
    private let defaults = UserDefaults.standard
    func snapshot() throws -> SyncLocalSnapshot {
        var values: [String: Data] = [:]
        for (id, alias) in defaults.dictionary(forKey: "aliases") as? [String: String] ?? [:] {
            values["alias/" + id] = try SyncHash.encode(alias)
        }
        if let data = defaults.data(forKey: "shortcuts") {
            for (id, shortcut) in try JSONDecoder().decode([String: Shortcut].self, from: data) {
                values["shortcut/" + id] = try SyncHash.encode(shortcut)
            }
        }
        let order = defaults.stringArray(forKey: "favoriteOrder") ?? []
        for id in defaults.stringArray(forKey: "favorites") ?? [] {
            values["favorite/" + id] = try SyncHash.encode(order.firstIndex(of: id) ?? order.count)
        }
        return .init(values: values)
    }
    func apply(id: String, data: Data?) throws {
        if id.hasPrefix("alias/") {
            let command = String(id.dropFirst(6)); var aliases = defaults.dictionary(forKey: "aliases") as? [String: String] ?? [:]
            aliases[command] = try data.map { try JSONDecoder().decode(String.self, from: $0) }
            defaults.set(aliases, forKey: "aliases")
        } else if id.hasPrefix("shortcut/") {
            let command = String(id.dropFirst(9))
            var bindings = try defaults.data(forKey: "shortcuts").map { try JSONDecoder().decode([String: Shortcut].self, from: $0) } ?? [:]
            let shortcut = try data.map { try JSONDecoder().decode(Shortcut.self, from: $0) }
            bindings[command] = shortcut
            guard ShortcutValidation.conflict(in: bindings) == nil else { throw ConfigurationError("同步快捷键与本机快捷键冲突，请先在快捷键设置中调整。") }
            defaults.set(try SyncHash.encode(bindings), forKey: "shortcuts")
        } else if id.hasPrefix("favorite/") {
            let command = String(id.dropFirst(9)); var favorites = Set(defaults.stringArray(forKey: "favorites") ?? [])
            var order = (defaults.stringArray(forKey: "favoriteOrder") ?? []).filter { $0 != command }
            if let data {
                let position = try JSONDecoder().decode(Int.self, from: data)
                favorites.insert(command); order.insert(command, at: max(0, min(order.count, position)))
            } else { favorites.remove(command) }
            defaults.set(Array(favorites).sorted(), forKey: "favorites"); defaults.set(order, forKey: "favoriteOrder")
        } else { throw SyncError.invalidData }
    }
}
