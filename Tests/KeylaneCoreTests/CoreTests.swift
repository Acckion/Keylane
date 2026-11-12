import XCTest
import SQLite3
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
        let link = Record(kind: "link", title: "中文 ' quote", body: "hello\nworld")
        do {
            let db = try Store(url: url)
            try db.save(link)
            XCTAssertEqual(try db.records(kind: "link"), [link])
            var updated = link
            updated.body = "edited"
            try db.save(updated)
        }
        let reopened = try Store(url: url)
        XCTAssertEqual(try reopened.records(kind: "link").first?.body, "edited")
        try reopened.remove(id: link.id)
        XCTAssertTrue(try reopened.records(kind: "link").isEmpty)
    }

    func testRemovingLegacyNotesPreservesOtherRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        let marker = "keylane-legacy-note-" + UUID().uuidString
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
            PRAGMA journal_mode=WAL;
            PRAGMA user_version=1;
            CREATE TABLE records(id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, updated REAL NOT NULL);
            CREATE VIRTUAL TABLE records_fts USING fts5(id UNINDEXED,title,body);
            INSERT INTO records VALUES('scratchpad','note','Old note','\(marker)',1),
                                      ('link','link','Old link','https://example.com',2),
                                      ('snippet','snippet','Keep snippet','Example',3);
            INSERT INTO records_fts SELECT id,title,body FROM records;
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let migrated = try Store(url: url)
        XCTAssertTrue(try migrated.records(kind: "note").isEmpty)
        XCTAssertEqual(try migrated.records(kind: "link").first?.id, "link")
        XCTAssertEqual(try migrated.records(kind: "snippet").first?.id, "snippet")
        let export = directory.appendingPathComponent("export.json")
        try migrated.export(to: export)
        XCTAssertEqual(Set(try JSONDecoder().decode([Record].self, from: Data(contentsOf: export)).map(\.kind)), ["link", "snippet"])
        for file in [url, URL(fileURLWithPath: url.path + "-wal")] where FileManager.default.fileExists(atPath: file.path) {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(marker.utf8)))
        }
        XCTAssertTrue(try Store(url: url).records(kind: "note").isEmpty)
    }
}
