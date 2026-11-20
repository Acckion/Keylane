import Foundation
import KeylaneCore

/// Prepares only owned-store copies. No live controller, network, external attachment or source app access.
enum RaycastDataMigration {
    struct Prepared {
        var changes: [String: Any] = [:]
        var resources: [RaycastMigrationTransaction.Resource] = []
        var messages: [String] = []
    }
    struct CommandArchive: Codable { var version = 1; var commands: [CustomAICommand] }

    static func prepare(_ data: RaycastMigrationData, current: [String:Any], root: URL, overwrite: Bool) throws -> Prepared {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneRaycast-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        var result = Prepared()
        func resource(_ id: MigrationResourceID, action: (URL) throws -> Int) throws {
            let before = try RaycastMigrationTransaction.snapshot(id, root: root)
            let target = temporary.appendingPathComponent(id.relativePath)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let before { try before.write(to: target, options: .atomic) }
            let count = try action(target)
            guard count > 0, let after = try RaycastMigrationTransaction.snapshot(id, root: temporary),
                  try RaycastMigrationTransaction.fingerprint(before, id: id) != RaycastMigrationTransaction.fingerprint(after, id: id) else { return }
            result.resources.append(.init(id: id, before: before, after: after))
            result.messages.append("\(id.rawValue)：准备合并 \(count) 项。")
        }
        if !data.snippets.isEmpty {
            try resource(.snippets) { url in
                let store = try Store(url: url)
                var existing = try store.records(kind: "snippet").compactMap(Snippet.fromRecord)
                var changed = 0, collisions = 0
                for var snippet in data.snippets {
                    let index = existing.firstIndex { $0.id == snippet.id || ($0.title == snippet.title && $0.text == snippet.text) }
                    if let index, !overwrite || existing[index] == snippet { continue }
                    if let index { snippet = Snippet(id: existing[index].id, title: snippet.title, text: snippet.text, keyword: snippet.keyword, tags: snippet.tags) }
                    if !snippet.keyword.isEmpty, existing.contains(where: { $0.id != snippet.id && $0.keyword.lowercased() == snippet.keyword.lowercased() }) {
                        snippet.keyword = ""; collisions += 1
                    }
                    try store.save(snippet.record())
                    if let index { existing[index] = snippet } else { existing.append(snippet) }
                    changed += 1
                }
                if collisions > 0 { result.messages.append("片段关键词冲突 \(collisions) 项：保留正文，清空导入项的重复关键词。") }
                return changed
            }
        }
        if !data.clips.isEmpty {
            try resource(.clipboard) { url in
                let store = try ClipboardStore(directory: url.deletingLastPathComponent())
                var count = 0
                for clip in data.clips { if try store.importText(clip, overwrite: overwrite) { count += 1 } }
                return count
            }
            result.messages.append("剪贴板导入不启用自动采集。导入后仍遵循现有保存时长和容量限制，过期记录可能在正常清理时移除。")
        }
        if !data.focusCategories.isEmpty {
            try resource(.focus) { url in
                let store = FocusStore(url: url)
                var archive = try store.load(), count = 0
                for value in data.focusCategories {
                    if let index = archive.categories.firstIndex(where: { $0.id == value.id || $0.name == value.name }) {
                        guard overwrite, archive.categories[index] != value else { continue }
                        // Existing sessions reference category IDs; preserve those IDs.
                        var value = value; value.id = archive.categories[index].id
                        archive.categories[index] = value
                    } else { archive.categories.append(value) }
                    count += 1
                }
                guard archive.categories.count <= 200 else { throw ConfigurationError("专注分类合并后超过 200 项，未保存导入。") }
                if count > 0 { try store.save(archive) }
                return count
            }
        }
        if !data.chats.isEmpty {
            try resource(.conversations) { url in
                let repository = AIConversationRepository(url: url)
                let existing = Set(try repository.list().map(\.id))
                var count = 0
                for chat in data.chats {
                    guard overwrite || !existing.contains(chat.id) else { continue }
                    let turns = turns(chat.messages)
                    guard !turns.isEmpty else { continue }
                    // Deliberately unavailable reference: historical Raycast model names are not credentials.
                    let reference = AIChatRecord.ModelReference(importedModel: chat.modelName)
                    let record = AIChatRecord(id: chat.id, content: .init(model: reference, turns: turns))
                    try repository.importHistory(record, title: chat.title, updated: chat.updated, archived: chat.archived)
                    count += 1
                }
                return count
            }
            result.messages.append("AI 历史可查看、复制；原 Raycast 模型不可在 Keylane 调用。这批导入历史不支持继续生成或重试。")
        }
        if !data.commands.isEmpty {
            let key = "customAICommands.v1"
            var archive = CommandArchive(commands: [])
            if let raw = current[key] as? Data {
                archive = try JSONDecoder().decode(CommandArchive.self, from: raw)
                guard archive.version == 1 else { throw ConfigurationError("当前 AI 命令版本不支持合并。") }
            }
            var count = 0
            for incoming in data.commands {
                let command = try CustomAICommand(id: incoming.id, title: incoming.title, prompt: incoming.prompt).validated()
                if let index = archive.commands.firstIndex(where: { $0.id == command.id }) {
                    guard overwrite, archive.commands[index] != command else { continue }
                    archive.commands[index] = command
                } else { archive.commands.append(command) }
                count += 1
            }
            if count > 0 {
                let encoded = try JSONEncoder().encode(archive)
                guard encoded.count <= CustomAICommandLibrary.maximumArchiveBytes else { throw ConfigurationError("AI 命令合并后超过大小限制。") }
                result.changes[key] = encoded
                result.messages.append("AI 命令：准备合并 \(count) 项，不导入模型账号或开启 AI。")
            }
        }
        if !data.emoji.isEmpty {
            let known = Set(try EmojiCatalog.load().map(\.glyph))
            var usage = current["emojiRecentUsage"] as? [String:Int] ?? [:]
            var keywords = current["emojiCustomKeywords"] as? [String:[String]] ?? [:]
            let ordered = data.emoji.sorted { ($0.usedAt ?? .distantPast) < ($1.usedAt ?? .distantPast) }
            var count = 0
            for (index, item) in ordered.enumerated() where known.contains(item.symbol) {
                if item.usedAt != nil, overwrite || usage[item.symbol] == nil { usage[item.symbol] = index + 1 }
                if !item.keywords.isEmpty, overwrite || keywords[item.symbol] == nil { keywords[item.symbol] = item.keywords }
                count += 1
            }
            if !NSDictionary(dictionary: usage).isEqual(to: current["emojiRecentUsage"] as? [String:Int] ?? [:]) { result.changes["emojiRecentUsage"] = usage }
            if !NSDictionary(dictionary: keywords).isEqual(to: current["emojiCustomKeywords"] as? [String:[String]] ?? [:]) { result.changes["emojiCustomKeywords"] = keywords }
            result.messages.append("Emoji：匹配目录 \(count) 项；使用时间转换为常用排序权重，不保留原始时间。")
        }
        result.messages += data.omissions.keys.sorted().map { "跳过 \($0)：\(data.omissions[$0]!) 项。" }
        return result
    }

    static func turns(_ messages: [RaycastMigrationData.Message]) -> [AIConversationTurn] {
        var turns: [AIConversationTurn] = []
        var currentTurn: Int?
        for message in messages {
            if message.role == "user" {
                currentTurn = nil
                // A boundary without imported text intentionally suppresses that whole turn,
                // including its assistant text/reasoning, without importing any attachment.
                guard !message.text.isEmpty else { continue }
                var turn = AIConversationTurn(question: message.text); turn.id = message.id; turn.complete = true
                turns.append(turn)
                currentTurn = turns.count - 1
            } else if let index = currentTurn {
                if !message.text.isEmpty { turns[index].answer += message.text }
                if !message.reasoning.isEmpty {
                    var progress = turns[index].progress ?? AIResponseProgress()
                    let previous = progress.activities.filter { $0.kind == .thinking }.map(\.text).joined()
                    progress = AIResponseProgress()
                    progress.apply(.thinking(id: "imported", delta: previous + message.reasoning)); progress.apply(.completed)
                    turns[index].progress = progress
                }
            }
        }
        return turns
    }
}
