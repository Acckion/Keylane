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
        XCTAssertTrue(Snippet.validKeyword("缩写"))
        XCTAssertFalse(Snippet.validKeyword("two words"))
    }

    func testRaycastJSONAndLegacyStorage() throws {
        let sample = Data(#"[{"name":"date","text":"today is {date}","keyword":"date","tags":["date"]}]"#.utf8)
        let imported = try JSONDecoder().decode([SnippetExchange].self, from: sample).map { $0.snippet() }
        XCTAssertEqual(imported.first?.text, "today is {date}")
        XCTAssertEqual(imported.first?.tags, ["date"])
        XCTAssertEqual(try JSONDecoder().decode([SnippetExchange].self, from: SnippetExchange.encode(imported)),
                       try JSONDecoder().decode([SnippetExchange].self, from: sample))
        let old = Data(#"{"id":"old","title":"Old","text":"{time}","keyword":";old"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Snippet.self, from: old),
                       Snippet(id: "old", title: "Old", text: "{time}", keyword: ";old"))
    }

    func testExpansionModesAndWordBoundary() {
        XCTAssertNotNil(SnippetExpansionMode.immediately.match(in: "!hi", caret: 3, keyword: "!hi", withinWords: false))
        XCTAssertNil(SnippetExpansionMode.immediately.match(in: "x!hi", caret: 4, keyword: "!hi", withinWords: false))
        XCTAssertNotNil(SnippetExpansionMode.immediately.match(in: "x!hi", caret: 4, keyword: "!hi", withinWords: true))
        XCTAssertNil(SnippetExpansionMode.immediately.match(in: "!hithere", caret: 3, keyword: "!hi", withinWords: false))
        XCTAssertEqual(SnippetExpansionMode.keepDelimiter.match(in: "!hi,", caret: 4, keyword: "!hi",
                                                                 delimiter: ",", withinWords: false)?.suffix, ",")
        XCTAssertEqual(SnippetExpansionMode.discardDelimiter.match(in: "!hi,", caret: 4, keyword: "!hi",
                                                                    delimiter: ",", withinWords: false)?.suffix, "")
    }

}
