import XCTest
@testable import KeylaneCore

final class RaycastMigrationDataTests: XCTestCase {
    private func decode(_ root: [String:Any]) throws -> RaycastMigrationData {
        try RaycastConfiguration.decode(JSONSerialization.data(withJSONObject: root)).data
    }
    func testVersionedDataAndStableIdentity() throws {
        let raw: [String:Any] = ["snippets": ["schemaVersion":1,"snippets":[["id":"source-id","title":"Example","text":"Hello {clipboard}","keyword":"hi","tags":["one","ONE"]]]],
            "notes":["schemaVersion":2,"notes":[["text":"must not retain"]]],
            "focusCategories":["schemaVersion":1,"focusCategories":[["title":"Work","applicationIds":["org.example.editor"],"websiteHosts":["example.com"]]]]]
        let first = try decode(raw), second = try decode(raw)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.snippets.count,1)
        XCTAssertEqual(first.snippets.first?.tags,["one"])
        XCTAssertEqual(first.focusCategories.first?.applications.first?.id,"org.example.editor")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(first), as: UTF8.self).contains("must not retain"))
        XCTAssertTrue(try decode(["snippets":["schemaVersion":99,"snippets":[["id":"a","title":"b","text":"c"]]]]).snippets.isEmpty)
    }
    func testClipboardAcceptsOnlyInlinePlainText() throws {
        func entry(_ contentType: String, _ mime: String, _ body: String) -> [String:Any] {
            ["createdAt":"2026-11-01T01:02:03.123Z","items":[["representations":[["contentType":contentType,"mimeType":mime,"content":body]]]]]
        }
        let data = try decode(["clipboardHistory":["schemaVersion":1,"clipboardEntries":[entry("text","text/plain;charset=utf-8","Plain"),entry("blob","text/plain","SGVsbG8="),entry("url","text/plain","/private/file"),entry("text","text/html","<b>HTML</b>")]]])
        XCTAssertEqual(data.clips.map(\.text),["Plain"])
        XCTAssertEqual(data.omissions["clipboardHistory.nonTextOrInvalid"],3)
    }
    func testAIv2TextAndReasoningWithoutToolOrAttachmentPayloads() throws {
        let timestamp = "2026-11-01T00:00:00Z"
        func message(_ id: String, _ role: String, _ content: [String:Any]) -> [String:Any] {
            ["id":id,"chatId":"chat","role":role,"content":content,"createdAt":timestamp]
        }
        let data = try decode(["ai":["schemaVersion":2,"chats":[["id":"chat","title":"Example","modelId":"model","updatedAt":timestamp]],
            "models":[["id":"model","model":"example-model"]],
            "messages":[message("1","user",["type":"user-query","text":"Question","attachments":[["path":"/private/missing"]]]),
                        message("2","assistant",["type":"reasoning","reasoning":"Thought"]),
                        message("3","assistant",["type":"text","text":"Answer"]),
                        message("4","tool",["type":"tool","result":["secret":"must not retain"]])]]])
        XCTAssertEqual(data.chats.count,1)
        XCTAssertEqual(data.chats[0].messages.map(\.text),["Question","","Answer"])
        XCTAssertEqual(data.chats[0].messages[1].reasoning,"Thought")
        XCTAssertEqual(data.omissions["ai.attachments"],1)
        let encoded = String(decoding: try JSONEncoder().encode(data),as:UTF8.self)
        XCTAssertFalse(encoded.contains("/private/missing")); XCTAssertFalse(encoded.contains("must not retain"))
    }
    func testUnsupportedTemplateAndInvalidFocusAreSkipped() throws {
        let data = try decode(["snippets":["schemaVersion":1,"snippets":[["id":"a","title":"bad","text":"{snippet name=missing}"]]],
                               "focusCategories":["schemaVersion":1,"focusCategories":[["title":"bad","applicationIds":["/private/path"]]]]])
        XCTAssertTrue(data.snippets.isEmpty); XCTAssertTrue(data.focusCategories.isEmpty)
    }

    func testAttachmentOnlyUserMessageRetainsBoundaryWithoutPayload() throws {
        let timestamp = "2026-11-01T00:00:00Z"
        func message(_ id: String, _ role: String, _ content: [String:Any]) -> [String:Any] {
            ["id":id,"chatId":"chat","role":role,"content":content,"createdAt":timestamp]
        }
        let data = try decode(["ai":["schemaVersion":2,"chats":[["id":"chat","title":"Example"]],
            "messages":[message("1","user",["text":"First question"]), message("2","assistant",["text":"First answer"]),
                        message("3","user",["attachments":[["path":"/synthetic/never-read","content":"never-import"]]]),
                        message("4","assistant",["text":"Attachment answer"]),
                        message("5","user",["text":"Next question"]), message("6","assistant",["text":"Next answer"])]]])
        let messages = try XCTUnwrap(data.chats.first?.messages)
        XCTAssertEqual(messages.map(\.role), ["user","assistant","user","assistant","user","assistant"])
        XCTAssertEqual(messages[2].text, "")
        XCTAssertEqual(messages[2].reasoning, "")
        XCTAssertEqual(data.omissions["ai.nonTextMessages"], 1)
        XCTAssertEqual(data.omissions["ai.attachments"], 1)
        let encoded = String(decoding: try JSONEncoder().encode(data), as: UTF8.self)
        XCTAssertFalse(encoded.contains("never-read")); XCTAssertFalse(encoded.contains("never-import"))
    }
}
