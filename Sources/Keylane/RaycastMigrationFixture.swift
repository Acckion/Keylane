#if DEBUG
import AppKit
import Foundation
import KeylaneCore

/// Synthetic end-to-end checks. Never uses the real support directory or preference domain.
enum RaycastMigrationFixture {
    struct Failure: Error { let reason: String }
    static func require(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        guard try condition() else { throw Failure(reason: reason) }
    }
    /// Read-only real-file check: secure native password input; only aggregate results leave memory.
    static func inspect(_ url: URL) throws {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        let prompt = NSAlert(); prompt.messageText = "验证 Raycast 导入预览（只读）"
        prompt.informativeText = "使用最终解析器检查可转换数量。不应用到 Keylane，不保存密码、正文或附件。"
        let field = NSSecureTextField(frame: NSRect(x:0,y:0,width:360,height:26))
        prompt.accessoryView = field; prompt.addButton(withTitle:"只读验证"); prompt.addButton(withTitle:"取消")
        prompt.window.initialFirstResponder = field
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        let source = try ConfigurationTransaction.read(url)
        let password = field.stringValue; field.stringValue = ""
        let preview = try RaycastConfiguration.decode(source,password:password)
        let data = preview.data
        let report: [String:Any] = ["status":"success", "snippets":data.snippets.count,"chats":data.chats.count,
            "messages":data.chats.reduce(0) { $0 + $1.messages.count },"commands":data.commands.count,"clipboard":data.clips.count,
            "emoji":data.emoji.count,"focus":data.focusCategories.count,"quicklinks":preview.archive.quicklinks?.count ?? 0,
            "settings":preview.archive.preferences.count,"omissions":data.omissions,
            "categories":preview.categories.map { ["source":$0.source,"status":$0.status.rawValue] }]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
    }
    static func run() throws {
        try attachmentTurnBoundaries()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RaycastFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let date = "2026-11-01T01:02:03Z"
        let source: [String:Any] = [
            "snippets":["schemaVersion":1,"snippets":[["id":"s","title":"Fixture","text":"Text","keyword":"fixture"]]],
            "clipboardHistory":["schemaVersion":1,"clipboardEntries":[["createdAt":date,"copyCount":4,"items":[["representations":[["contentType":"text","mimeType":"text/plain","content":"Fixture clipboard"]]]]]]],
            "ai":["schemaVersion":2,"commands":[["id":"command","name":"Fixture command","promptTemplate":"Explain this"]],
                  "chats":[["id":"chat","title":"Fixture chat","updatedAt":date]],
                  "messages":[["id":"1","chatId":"chat","role":"user","createdAt":date,"content":["type":"user-query","text":"Question"]],
                              ["id":"2","chatId":"chat","role":"assistant","createdAt":date,"content":["type":"text","text":"Answer"]]]],
            "focusCategories":["schemaVersion":1,"focusCategories":[["title":"Work","applicationIds":["org.example.Editor"],"websiteHosts":["example.com"]]]],
            "emoji":["schemaVersion":1,"emojis":[["symbol":"λ","customKeywords":["fixturelambda"],"frecencyDate":date]]],
            "notes":["schemaVersion":2,"notes":[["text":"Unsupported fixture note"]]]
        ]
        let data = try RaycastConfiguration.decode(JSONSerialization.data(withJSONObject: source)).data
        var prefs: [String:Any] = [:]
        let prepared = try RaycastDataMigration.prepare(data, current:prefs, root:root, overwrite:false)
        try require(prepared.resources.count == 4,"prepared store count")
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data.sqlite").path),"preview wrote live store")
        let directory = root.appendingPathComponent("ConfigurationRecovery")
        try RaycastMigrationTransaction.stage(changes:prepared.changes,current:prefs,resources:prepared.resources,directory:directory)
        _ = try RaycastMigrationTransaction.finish(directory:directory,root:root,read:{prefs},persist:{prefs=$0;return true})
        let snippets = try Store(url:root.appendingPathComponent("data.sqlite")).records(kind:"snippet")
        try require(snippets.count == 1,"snippet count")
        let clips = try ClipboardStore(directory:root.appendingPathComponent("Clipboard"))
        let clip = try clips.list().first
        try require(clip?.copyCount == 4,"clipboard metadata")
        let repository = AIConversationRepository(url:root.appendingPathComponent("AI/history.sqlite"))
        let summary = try repository.list().first!
        let chat = try repository.load(summary.id)!
        try require(chat.content.turns.first?.answer == "Answer","chat content")
        try require(chat.content.model.endpoint == "raycast-import:unavailable","unsafe model mapping")
        try require(try FocusStore(url:root.appendingPathComponent("Focus/state.json")).load().categories.count == 1,"focus count")
        try require((prefs["emojiCustomKeywords"] as? [String:[String]])?["λ"] == ["fixturelambda"],"emoji keywords")
        let repeated = try RaycastDataMigration.prepare(data,current:prefs,root:root,overwrite:false)
        try require(repeated.resources.isEmpty && repeated.changes.isEmpty,"repeat import changed data")
        // Existing data changed by the user must not be silently undone.
        try RaycastMigrationTransaction.stageUndo(directory:directory,root:root,current:prefs)
        _ = try RaycastMigrationTransaction.finish(directory:directory,root:root,read:{prefs},persist:{prefs=$0;return true})
        try require(prefs.isEmpty,"undo preferences")
        try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("AI/history.sqlite").path),"undo missing store")
        print("Raycast migration fixture passed: preview, 4 stores, metadata, history, repeat import and undo")
    }

    private static func attachmentTurnBoundaries() throws {
        let date = "2026-11-01T00:00:00Z"
        func message(_ id: String, _ role: String, _ content: [String:Any]) -> [String:Any] {
            ["id":id,"chatId":"chat","role":role,"content":content,"createdAt":date]
        }
        let source: [String:Any] = ["ai":["schemaVersion":2,"chats":[["id":"chat","title":"Synthetic"]],"messages":[
            message("1","user",["text":"First question"]), message("2","assistant",["text":"First answer"]),
            message("3","user",["attachments":[["path":"/synthetic/never-read","content":"never-import"]]]),
            message("4","assistant",["reasoning":"Attachment reasoning"]), message("5","assistant",["text":"Attachment answer"]),
            message("6","user",["text":"Next question"]), message("7","assistant",["text":"Next answer"])]]]
        let imported = try RaycastConfiguration.decode(JSONSerialization.data(withJSONObject:source)).data
        let turns = RaycastDataMigration.turns(imported.chats[0].messages)
        try require(turns.map(\.question) == ["First question","Next question"],"attachment boundary questions")
        try require(turns.map(\.answer) == ["First answer","Next answer"],"attachment boundary answers")
        try require(turns.allSatisfy { $0.progress == nil && $0.attachments == nil },"attachment content or reasoning reassigned")
        print("Raycast attachment-only user boundary fixture passed")
    }
}
#endif
