import Foundation
import CoreFoundation

/// Portable settings, deliberately separate from permissions, caches and private databases.
public struct ConfigurationArchive: Codable {
    public var format = "keylane.configuration"
    public var schemaVersion = 2
    public var preferences: [String: Value] = [:]
    public var aliases: [String: String]?
    public var shortcuts: [String: Shortcut]?
    public var quicklinks: [Quicklink]?
    public var disabledCommands: [String]?
    public var commandEnabled: [String: Bool]?

    public enum Value: Codable, Equatable {
        case string(String), bool(Bool), integer(Int)
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Int.self) { self = .integer(n) }
            else { self = .string(try c.decode(String.self)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self { case .string(let x): try c.encode(x); case .bool(let x): try c.encode(x); case .integer(let x): try c.encode(x) }
        }
        var object: Any { switch self { case .string(let x): x; case .bool(let x): x; case .integer(let x): x } }
    }

    static let enums: [String: Set<String>] = [
        "appearance": ["system", "light", "dark"], "placement": ["activeScreen", "primaryDisplay", "remember"],
        "rootSearchSensitivity": ["low", "medium", "high"], "interfaceSize": ["small", "medium", "large"],
        "windowMode": ["compact", "expanded"], "applicationHotkeyAction": ["toggle", "activate"],
        "navigation": ["arrows", "vim", "emacs"], "windowActivationBehavior": ["systemDefault", "activeSpace"],
        "launcherEscapeBehavior": ["backOrClose", "closeWindow"], "pageNavigationKeys": ["brackets", "arrows"]
    ]
    static let flags: Set<String> = ["rootFileContentSearch", "compactFavorites", "applicationsEnabled", "escapeClosesUtilityWindows", "replaceHyperKeycaps"]
    public init() {}

    public static func capture(_ defaults: UserDefaults, includePersonalContent: Bool = false) throws -> Self {
        var archive = Self()
        for key in enums.keys { if let value = defaults.string(forKey: key) { archive.preferences[key] = .string(value) } }
        for key in flags { if let value = defaults.object(forKey: key) as? Bool { archive.preferences[key] = .bool(value) } }
        if let value = defaults.object(forKey: "launcherReturnDelay") as? Int { archive.preferences["launcherReturnDelay"] = .integer(value) }
        if let data = defaults.data(forKey: "shortcuts") { archive.shortcuts = try JSONDecoder().decode([String: Shortcut].self, from: data) }
        else { archive.shortcuts = ["launcher": .launcher] }
        archive.disabledCommands = defaults.stringArray(forKey: "disabledLauncherCommands") ?? []
        if includePersonalContent {
            archive.aliases = defaults.dictionary(forKey: "aliases") as? [String: String] ?? [:]
            if let data = defaults.data(forKey: QuicklinkLibrary.storageKey) {
                archive.quicklinks = try JSONDecoder().decode(QuicklinkLibrary.self, from: data).links
            } else { archive.quicklinks = [] }
        }
        return archive
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16 * 1024 * 1024 else { throw ConfigurationError("文件超过 16 MB。") }
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["schemaVersion"] as? Int == 1, root["format"] == nil,
           let preferences = root["preferences"] {
            var legacy = Self()
            legacy.preferences = try JSONDecoder().decode([String: Value].self, from: JSONSerialization.data(withJSONObject: preferences))
            return legacy
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.format == "keylane.configuration", value.schemaVersion == 2 else {
            throw ConfigurationError("不支持此配置格式或版本；请使用兼容版本的 Keylane。")
        }
        return value
    }

    public struct Plan {
        public let changes: [String: Any]
        public let messages: [String]
        public let conflicts: Int
        public let omitted: Int
    }

    /// Merge-only restoration: missing categories/keys never delete existing configuration.
    public func plan(current: [String: Any], overwrite: Bool) throws -> Plan {
        guard disabledCommands == nil || commandEnabled == nil else { throw ConfigurationError("命令状态包含两种不兼容的表示。") }
        var changes: [String: Any] = [:], messages: [String] = []
        var conflicts = 0, omitted = 0
        func choose(_ key: String, _ value: Any) {
            if let old = current[key], !Self.equal(old, value) {
                conflicts += 1
                if !overwrite { return }
            }
            if !Self.equal(current[key], value) { changes[key] = value }
        }
        for (key, value) in preferences {
            if let allowed = Self.enums[key] {
                guard case .string(let text) = value, allowed.contains(text) else { throw ConfigurationError("偏好值无效：\(key)。") }
            } else if Self.flags.contains(key) {
                guard case .bool = value else { throw ConfigurationError("偏好类型无效：\(key)。") }
            } else if key == "launcherReturnDelay" {
                guard case .integer(let n) = value, [-1, 0, 30, 90, 300].contains(n) else { throw ConfigurationError("返回延迟无效。") }
            } else { omitted += 1; continue }
            choose(key, value.object)
        }
        if let disabledCommands {
            guard Set(disabledCommands).count == disabledCommands.count, disabledCommands.allSatisfy({ !$0.isEmpty && $0.count < 1024 }) else { throw ConfigurationError("命令启用状态无效。") }
            choose("disabledLauncherCommands", disabledCommands.sorted())
        }
        if let commandEnabled {
            var disabled = Set(current["disabledLauncherCommands"] as? [String] ?? [])
            for (id, enabled) in commandEnabled {
                guard !id.isEmpty, id.count < 1024 else { throw ConfigurationError("命令状态记录无效。") }
                let wasEnabled = !disabled.contains(id)
                if wasEnabled != enabled { conflicts += 1; if !overwrite { continue } }
                if enabled { disabled.remove(id) } else { disabled.insert(id) }
            }
            let proposed = disabled.sorted()
            let old = (current["disabledLauncherCommands"] as? [String] ?? []).sorted()
            if proposed != old { changes["disabledLauncherCommands"] = proposed }
        }
        if let aliases {
            var merged = current["aliases"] as? [String: String] ?? [:]
            for key in aliases.keys.sorted() {
                let value = aliases[key]!
                guard !key.isEmpty, key.count < 1024, value.count <= 4096 else { throw ConfigurationError("别名记录无效。") }
                if let old = merged[key], old != value { conflicts += 1; if !overwrite { continue } }
                if !value.isEmpty, merged.contains(where: { $0.key != key && $0.value.localizedCaseInsensitiveCompare(value) == .orderedSame }) {
                    omitted += 1; continue
                }
                merged[key] = value
            }
            if !Self.equal(current["aliases"], merged) { changes["aliases"] = merged }
        }
        var bindings: [String: Shortcut] = ["launcher": .launcher]
        if let stored = current["shortcuts"] {
            guard let data = stored as? Data else { throw ConfigurationError("现有快捷键损坏，未写入任何配置。") }
            bindings = try JSONDecoder().decode([String: Shortcut].self, from: data)
        }
        if let shortcuts {
            guard ShortcutValidation.conflict(in: shortcuts) == nil else { throw ConfigurationError("导入文件中的快捷键无效或相互冲突。") }
            for key in shortcuts.keys.sorted() {
                let value = shortcuts[key]!
                guard !key.isEmpty, key.count < 1024, value.modifiers & ~UInt32(256 | 512 | 2048 | 4096) == 0 else {
                    throw ConfigurationError("快捷键记录无效。")
                }
                if let old = bindings[key], old != value { conflicts += 1; if !overwrite { continue } }
                var candidate = bindings; candidate[key] = value
                if ShortcutValidation.conflict(in: candidate) != nil { omitted += 1; continue }
                bindings = candidate
            }
            let data = try JSONEncoder().encode(bindings)
            if let old = current["shortcuts"] as? Data,
               (try? JSONDecoder().decode([String: Shortcut].self, from: old)) == bindings {} else { changes["shortcuts"] = data }
        }
        if let quicklinks {
            var existing: [Quicklink] = []
            if let stored = current[QuicklinkLibrary.storageKey] {
                guard let data = stored as? Data else { throw ConfigurationError("现有 Quicklinks 损坏。") }
                existing = try JSONDecoder().decode(QuicklinkLibrary.self, from: data).links
            }
            var seen: Set<String> = []
            for link in quicklinks {
                guard (link.id == QuicklinkLibrary.legacyID || link.id.hasPrefix("quicklink:")),
                      seen.insert(link.id).inserted, !link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationError("Quicklinks 标识或名称无效。") }
                _ = try link.parsedTemplate()
                if let index = existing.firstIndex(where: { $0.id == link.id }) {
                    if existing[index] != link { conflicts += 1; if overwrite { existing[index] = link } }
                } else if existing.contains(where: { $0.title == link.title && $0.template == link.template && $0.openingApplicationID == link.openingApplicationID }) {
                    omitted += 1
                } else { existing.append(link) }
            }
            let data = try JSONEncoder().encode(QuicklinkLibrary(links: existing))
            if let old = current[QuicklinkLibrary.storageKey] as? Data,
               (try? JSONDecoder().decode(QuicklinkLibrary.self, from: old))?.links == existing {} else { changes[QuicklinkLibrary.storageKey] = data }
        }
        messages.append("偏好 \(preferences.count) 项；快捷键 \(shortcuts?.count ?? 0) 项；禁用命令 \(disabledCommands?.count ?? 0) 项；别名 \(aliases?.count ?? 0) 项；Quicklinks \(quicklinks?.count ?? 0) 条。")
        messages.append("冲突 \(conflicts) 项（\(overwrite ? "覆盖同名项" : "保留现有项")）；跳过不支持、重复或热键冲突 \(omitted) 项。缺失项目保留现状。")
        messages.append("将更改 \(changes.count) 个存储分组。系统占用的热键需重启后检查；缺失命令或应用的映射可能暂不生效。")
        return Plan(changes: changes, messages: messages, conflicts: conflicts, omitted: omitted)
    }
    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return NSDictionary(dictionary: ["v": a]).isEqual(to: ["v": b])
    }
}

public struct ConfigurationError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
