import XCTest
@testable import KeylaneCore

final class IncomingFilesTests: XCTestCase {
    func testBaselineSettlingAndNoRepeatedDelivery() {
        let now = Date(timeIntervalSince1970: 100)
        let old = IncomingFile(url: URL(fileURLWithPath: "/tmp/old.zip"), modified: now, size: 1)
        let new = IncomingFile(url: URL(fileURLWithPath: "/tmp/new.zip"), modified: now, size: 2)
        var tracker = IncomingFileTracker()
        XCTAssertTrue(tracker.update([old], now: now).isEmpty)
        XCTAssertTrue(tracker.update([old, new], now: now).isEmpty)
        XCTAssertEqual(tracker.update([old, new], now: now.addingTimeInterval(3)), [new])
        XCTAssertTrue(tracker.update([old, new], now: now.addingTimeInterval(6)).isEmpty)
        tracker.reset()
        XCTAssertTrue(tracker.update([old, new], now: now).isEmpty)
    }
    func testWritesRestartSettlingAndRemovedPendingDoesNotDeliver() {
        let now = Date(timeIntervalSince1970: 100)
        var tracker = IncomingFileTracker()
        _ = tracker.update([], now: now)
        var file = IncomingFile(url: URL(fileURLWithPath: "/tmp/new.zip"), modified: now, size: 2)
        XCTAssertTrue(tracker.update([file], now: now).isEmpty)
        file = .init(url: file.url, modified: now.addingTimeInterval(2), size: 3)
        XCTAssertTrue(tracker.update([file], now: now.addingTimeInterval(3)).isEmpty)
        XCTAssertTrue(tracker.update([], now: now.addingTimeInterval(6)).isEmpty)
        XCTAssertFalse(tracker.needsRescan)
    }
    func testCatalogExcludesTemporaryAndSymbolicLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("done.zip"))
        try Data([1]).write(to: folder.appendingPathComponent("pending.crdownload"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: folder.appendingPathComponent("done.zip"))
        XCTAssertEqual(try IncomingFiles.scan(folder).map { $0.url.lastPathComponent }, ["done.zip"])
    }
}
