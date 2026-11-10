import XCTest
@testable import KeylaneCore
final class CoreTests: XCTestCase {
    func testCalculator() {
        XCTAssertEqual(Calculator.evaluate("2+3*4"),14)
        XCTAssertEqual(Calculator.evaluate("-(2+3)/2"),-2.5)
        for invalid in ["", "1/0", "2+", "1..3", "system(1)", "()", String(repeating: "(", count: 80)] { XCTAssertNil(Calculator.evaluate(invalid), invalid) }
    }
    func testSearch() {
        XCTAssertGreaterThan(SearchRanker.score("Safari", query: "saf")!, SearchRanker.score("Safe", query: "sf")!)
        XCTAssertNotNil(SearchRanker.score("计算器", query: "jisuan"))
        XCTAssertNil(SearchRanker.score("Safari", query: "xyz"))
    }
    func testStoreRoundtripAndIsolation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.sqlite")
        let note = Record(kind: "note", title: "中文 ' quote", body: "hello\nworld")
        do { let db = try Store(url: url); try db.save(note); try db.save(Record(kind: "link", title: "other", body: "url")); XCTAssertEqual(try db.records(kind: "note"),[note]); var updated = note; updated.body = "edited"; try db.save(updated); XCTAssertEqual(try db.records(kind: "note").count,1) }
        let reopened = try Store(url: url); XCTAssertEqual(try reopened.records(kind: "note").first?.body,"edited"); try reopened.remove(id: note.id); XCTAssertTrue(try reopened.records(kind: "note").isEmpty)
    }
}
