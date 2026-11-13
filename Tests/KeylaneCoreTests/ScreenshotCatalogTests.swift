import XCTest
@testable import KeylaneCore

final class ScreenshotCatalogTests: XCTestCase {
    func testScopeOnlyIncludesMediaAndAvoidsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sub = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["截屏 2026-11-11.png", "Screen Recording.mov", "ordinary.jpeg", "notes.txt", ".hidden.png",
                     "Bildschirmfoto 2026-11-11.png", "Capture d’écran 2026-11-11.png"] {
            try Data([1]).write(to: sub.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Screenshot Linked.png"),
                                                  withDestinationURL: sub.appendingPathComponent("ordinary.jpeg"))
        let captures = ScreenshotCatalog.scan(folders: [root, sub], includeAllMedia: false)
        XCTAssertEqual(Set(captures.items.map(\.name)),
                       ["截屏 2026-11-11.png", "Screen Recording.mov",
                        "Bildschirmfoto 2026-11-11.png", "Capture d’écran 2026-11-11.png"])
        XCTAssertEqual(captures.items.count, 4)
        XCTAssertEqual(captures.inaccessibleFolders, 0)
        let media = ScreenshotCatalog.scan(folders: [root], includeAllMedia: true)
        XCTAssertEqual(media.items.count, 5)
        XCTAssertEqual(media.items.filter { $0.kind == .movie }.count, 1)
    }

    func testRelativeDatesUseLocalCalendarWithExclusiveEnd() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let parser = ISO8601DateFormatter()
        let now = try XCTUnwrap(parser.date(from: "2026-11-04T12:00:00Z"))

        func matches(_ query: String, _ timestamp: String) throws -> Bool {
            let date = try XCTUnwrap(parser.date(from: timestamp))
            let item = ScreenshotMedia(url: URL(fileURLWithPath: "/tmp/Screenshot.png"), date: date,
                                       modified: date, size: 1, kind: .image, needsCloudAccess: false)
            return ScreenshotQuery(query, calendar: calendar, now: now).matchesMetadata(item)
        }

        XCTAssertFalse(try matches("date:last week", "2026-10-26T03:59:59Z"))
        XCTAssertTrue(try matches("date:last week", "2026-10-26T04:00:00Z"))
        XCTAssertTrue(try matches("日期：上週", "2026-11-02T04:59:59Z"))
        XCTAssertFalse(try matches("日期：上周", "2026-11-02T05:00:00Z"))
        XCTAssertTrue(try matches("date:this week", "2026-11-02T05:00:00Z"))
        XCTAssertTrue(try matches("上个月", "2026-11-01T03:59:59Z"))
        XCTAssertFalse(try matches("date:last month", "2026-11-01T04:00:00Z"))
        XCTAssertTrue(try matches("日期:去年", "2026-01-01T04:59:59Z"))
        XCTAssertFalse(try matches("date:last year", "2026-01-01T05:00:00Z"))
    }

    func testChineseAndEnglishQueryFieldsAndDates() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 14))!
        let item = ScreenshotMedia(url: URL(fileURLWithPath: "/tmp/截屏 设置预览.png"), date: day, modified: day,
                                   size: 42, kind: .image, needsCloudAccess: false)
        let query = ScreenshotQuery("名称：设置预览 text: \"Keylane Search\" 日期:2026-11-11", calendar: calendar, now: day)
        XCTAssertTrue(query.matchesMetadata(item))
        XCTAssertEqual(query.text, "Keylane Search")
        XCTAssertTrue(ScreenshotQuery("date:today", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertTrue(ScreenshotQuery("2026-11", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertTrue(ScreenshotQuery("date:2026/11/11", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertTrue(ScreenshotQuery("date:2026 name:设置", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertFalse(ScreenshotQuery("date:2026//11 name:设置", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertFalse(ScreenshotQuery("date:2026-11-12", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertFalse(ScreenshotQuery("date:2026-99", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertFalse(ScreenshotQuery("name:无关", calendar: calendar, now: day).matchesMetadata(item))
    }
}
