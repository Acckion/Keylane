import Foundation
import XCTest
@testable import KeylaneCore

final class SnippetTests: XCTestCase {
    func testSnippetStorageCanReopenUpdateAndRemove() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("snippets.sqlite")
        var snippet = Snippet(title: "中文标题", text: "第一行\n第二行 {cursor}", keyword: ";test")
        try Store(url: database).save(snippet.record())
        let reopened = try Store(url: database)
        XCTAssertEqual(try reopened.records(kind: "snippet").map(Snippet.fromRecord), [snippet])
        snippet.title = "更新"
        try reopened.save(snippet.record())
        XCTAssertEqual(try reopened.records(kind: "snippet").map(Snippet.fromRecord), [snippet])
        try reopened.remove(id: snippet.record().id)
        XCTAssertTrue(try reopened.records(kind: "snippet").isEmpty)
    }

    func testCursorUsesUTF16AndPlaceholdersRenderAtUseTime() {
        let snippet = Snippet(text: "😀{cursor}你好 {date} {time}")
        let rendered = snippet.render(now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(rendered.cursorOffset, 2)
        XCTAssertTrue(rendered.text.hasPrefix("😀你好 "))
        XCTAssertFalse(rendered.text.contains("{"))
    }

    func testExpansionRequiresExactTokenAndSpace() {
        XCTAssertEqual(Snippet.expansionRange(in: "😀 ;test suffix", caret: 9, keyword: ";test"), NSRange(location: 3, length: 6))
        XCTAssertNil(Snippet.expansionRange(in: "word;test ", caret: 10, keyword: ";test"))
        XCTAssertNil(Snippet.expansionRange(in: ";test", caret: 5, keyword: ";test"))
        XCTAssertNil(Snippet.expansionRange(in: "", caret: 0, keyword: ""))
        XCTAssertFalse(Snippet.validKeyword("缩写"))
    }
}
