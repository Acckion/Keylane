import XCTest
@testable import KeylaneCore

final class ScreenshotCatalogTests: XCTestCase {
    func testScopeOnlyIncludesMediaAndAvoidsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sub = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["截屏 2026-11-11.png", "Screen Recording.mov", "ordinary.jpeg", "notes.txt", ".hidden.png"] {
            try Data([1]).write(to: sub.appendingPathComponent(name))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Screenshot Linked.png"),
                                                  withDestinationURL: sub.appendingPathComponent("ordinary.jpeg"))
        let captures = ScreenshotCatalog.scan(folders: [root, sub], includeAllMedia: false)
        XCTAssertEqual(Set(captures.items.map(\.name)), ["截屏 2026-11-11.png", "Screen Recording.mov"])
        XCTAssertEqual(captures.items.count, 2)
        XCTAssertEqual(captures.inaccessibleFolders, 0)
        let media = ScreenshotCatalog.scan(folders: [root], includeAllMedia: true)
        XCTAssertEqual(media.items.count, 3)
        XCTAssertEqual(media.items.filter { $0.kind == .movie }.count, 1)
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
        XCTAssertFalse(ScreenshotQuery("date:2026-11-12", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertFalse(ScreenshotQuery("date:2026-99", calendar: calendar, now: day).matchesMetadata(item))
        XCTAssertFalse(ScreenshotQuery("name:无关", calendar: calendar, now: day).matchesMetadata(item))
    }
}
