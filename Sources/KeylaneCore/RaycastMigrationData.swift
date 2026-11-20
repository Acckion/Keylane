import Foundation
import CryptoKit

/// Only normalized, currently usable records. Unsupported source payloads are never retained here.
public struct RaycastMigrationData: Codable, Equatable {
    public struct Command: Codable, Equatable { public let id: UUID; public let title: String; public let prompt: String }
    public struct Emoji: Codable, Equatable { public let symbol: String; public let keywords: [String]; public let usedAt: Date? }
    public struct Clip: Codable, Equatable {
        public let text: String; public let title: String; public let source: String; public let bundle: String
        public let created: Date; public let updated: Date; public let pinned: Bool; public let copyCount: Int
    }
    public struct Message: Codable, Equatable {
        public let id: UUID; public let role: String; public let text: String; public let reasoning: String; public let date: Date
    }
    public struct Chat: Codable, Equatable {
        public let id: UUID; public let title: String; public let modelName: String; public let updated: Date
        public let archived: Bool; public let messages: [Message]
    }
    public var snippets: [Snippet] = []
    public var commands: [Command] = []
    public var emoji: [Emoji] = []
    public var clips: [Clip] = []
    public var chats: [Chat] = []
    public var focusCategories: [FocusCategory] = []
    public var omissions: [String: Int] = [:]
    public var hasData: Bool { !snippets.isEmpty || !commands.isEmpty || !emoji.isEmpty || !clips.isEmpty || !chats.isEmpty || !focusCategories.isEmpty }
    public init() {}

    public static func stableID(_ source: String, namespace: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(("keylane.raycast." + namespace + ":" + source).utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    public static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
    static func parse(_ root: [String: Any]) -> Self {
        var result = Self()
        func category(_ name: String) -> [String:Any] {
            guard let value = root[name] as? [String:Any], value["schemaVersion"] as? Int == (name == "ai" ? 2 : 1) else { return [:] }
            return value
        }
        func records(_ name: String, _ field: String) -> [[String:Any]] { category(name)[field] as? [[String:Any]] ?? [] }
        func reject(_ category: String) { result.omissions[category, default: 0] += 1 }
        func text(_ raw: Any?, limit: Int = 4_000_000) -> String? {
            guard let value = raw as? String, value.utf8.count <= limit else { return nil }; return value
        }
        for record in records("snippets", "snippets") {
            guard let title = text(record["title"], limit: 4096), !title.isEmpty, let body = text(record["text"], limit: Snippet.maximumTextLength),
                  let source = text(record["id"], limit: 1024) else { reject("snippets.invalid"); continue }
            let keyword = text(record["keyword"], limit: 1024) ?? ""
            guard keyword.isEmpty || Snippet.validKeyword(keyword) else { reject("snippets.keyword"); continue }
            // Validate syntax without reading clipboard, files, snippets or requesting values.
            do { _ = try DynamicTemplate(body).plan() } catch { reject("snippets.template"); continue }
            let tags = (record["tags"] as? [String] ?? []).filter { $0.count <= 200 }
            result.snippets.append(Snippet(id: stableID(source, namespace: "snippet").uuidString,
                title: title, text: body, keyword: keyword, tags: Snippet.normalizedTags(tags)))
        }
        for record in records("ai", "commands") {
            guard let title = text(record["name"], limit: 100), !title.isEmpty,
                  let prompt = text(record["promptTemplate"], limit: 32_000), !prompt.isEmpty,
                  let source = text(record["id"], limit: 1024) else { reject("ai.commands"); continue }
            do { _ = try DynamicTemplate(prompt, usage: .aiCommand).plan() } catch { reject("ai.commandTemplates"); continue }
            result.commands.append(.init(id: stableID(source, namespace: "command"), title: title, prompt: prompt))
        }
        for record in records("emoji", "emojis") {
            guard let symbol = text(record["symbol"], limit: 128), !symbol.isEmpty else { reject("emoji"); continue }
            let keywords = (record["customKeywords"] as? [String] ?? []).filter { !$0.isEmpty && $0.count <= 200 }
            result.emoji.append(.init(symbol: symbol, keywords: keywords, usedAt: date(record["frecencyDate"])))
        }
        for record in records("focusCategories", "focusCategories") {
            guard let title = text(record["title"], limit: 200), !title.isEmpty else { reject("focusCategories"); continue }
            let apps = (record["applicationIds"] as? [String] ?? []).map { FocusApplication(id: $0, name: $0) }
            let websites = record["websiteHosts"] as? [String] ?? []
            let identity = title + "\u{0}" + apps.map(\.id).sorted().joined(separator: "\u{0}") + websites.sorted().joined(separator: "\u{0}")
            let value = FocusCategory(id: stableID(identity, namespace: "focus"), name: title, applications: apps, websites: websites)
            do { result.focusCategories.append(try value.validated()) } catch { reject("focusCategories"); continue }
        }
        for record in records("clipboardHistory", "clipboardEntries") {
            let representations = (record["items"] as? [[String:Any]] ?? []).flatMap { $0["representations"] as? [[String:Any]] ?? [] }
            let plain = representations.first { ($0["mimeType"] as? String)?.lowercased().split(separator: ";").first == "text/plain" && $0["contentType"] as? String == "text" }
            guard let body = text(plain?["content"], limit: 1_048_576), !body.isEmpty,
                  let created = date(record["createdAt"]) else { reject("clipboardHistory.nonTextOrInvalid"); continue }
            let source = record["source"] as? [String:Any] ?? [:]
            result.clips.append(.init(text: body, title: text(record["title"], limit: 4096) ?? "",
                source: text(source["name"], limit: 1024) ?? "Raycast", bundle: "",
                created: created, updated: date(record["updatedAt"]) ?? created,
                pinned: record["pinned"] as? Bool ?? false, copyCount: max(1, min(1_000_000, record["copyCount"] as? Int ?? 1))))
        }
        var modelNames: [String:String] = [:]
        for model in records("ai", "models") {
            if let id = model["id"] as? String, let name = text(model["model"] ?? model["name"], limit: 512) { modelNames[id] = name }
        }
        var grouped: [String:[Message]] = [:]
        for record in records("ai", "messages") {
            guard let chatID = record["chatId"] as? String, let sourceID = record["id"] as? String,
                  let role = record["role"] as? String, ["user", "assistant"].contains(role.lowercased()),
                  let content = record["content"] as? [String:Any], let created = date(record["createdAt"]) else { reject("ai.messages"); continue }
            let body = text(content["text"]) ?? "", reasoning = text(content["reasoning"]) ?? ""
            if reasoning.utf8.count > 16_000 { reject("ai.reasoningTruncated") }
            if let attachments = content["attachments"] as? [Any], !attachments.isEmpty { result.omissions["ai.attachments", default: 0] += attachments.count }
            if body.isEmpty && reasoning.isEmpty {
                reject("ai.nonTextMessages")
                // Keep only the boundary metadata for an unsupported user message. Removing
                // it would attach its following assistant replies to the previous question.
                guard role.lowercased() == "user" else { continue }
            }
            grouped[chatID, default: []].append(.init(id: stableID(sourceID, namespace: "message"), role: role.lowercased(), text: body, reasoning: reasoning, date: created))
        }
        for chat in records("ai", "chats") {
            guard let sourceID = chat["id"] as? String, let title = text(chat["title"], limit: 4096),
                  let messages = grouped[sourceID], messages.contains(where: { $0.role == "user" && !$0.text.isEmpty }) else { reject("ai.chats"); continue }
            result.chats.append(.init(id: stableID(sourceID, namespace: "chat"), title: title,
                modelName: modelNames[chat["modelId"] as? String ?? ""] ?? "Raycast imported model",
                updated: date(chat["updatedAt"]) ?? messages.last!.date, archived: date(chat["archivedAt"]) != nil,
                messages: messages.enumerated().sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date }.map(\.element)))
        }
        return result
    }
}
