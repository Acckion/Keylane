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
    func testMixedSettleTimesUseTheEarliestSafeRescanAndWaitForChangedWrites() {
        let now = Date(timeIntervalSince1970: 100)
        let image = IncomingFile(url: URL(fileURLWithPath: "/tmp/capture.png"), modified: now, size: 2)
        let movie = IncomingFile(url: URL(fileURLWithPath: "/tmp/recording.mov"), modified: now, size: 16)
        let settle: (IncomingFile) -> TimeInterval = { $0.url.pathExtension == "png" ? 0.35 : 2 }
        var tracker = IncomingFileTracker()
        XCTAssertTrue(tracker.update([], now: now, settleFor: settle).isEmpty)
        XCTAssertTrue(tracker.update([image, movie], now: now, settleFor: settle).isEmpty)
        XCTAssertEqual(tracker.nextRescanDelay(now: now, settleFor: settle), 0.35)
        let rewriteTime = now.addingTimeInterval(0.20)
        let rewritten = IncomingFile(url: image.url, modified: rewriteTime, size: 4)
        XCTAssertTrue(tracker.update([rewritten, movie], now: rewriteTime, settleFor: settle).isEmpty)
        XCTAssertTrue(tracker.update([rewritten, movie], now: now.addingTimeInterval(0.36), settleFor: settle).isEmpty)
        XCTAssertEqual(tracker.update([rewritten, movie], now: now.addingTimeInterval(0.56), settleFor: settle), [rewritten])
        XCTAssertEqual(tracker.update([rewritten, movie], now: now.addingTimeInterval(2.01), settleFor: settle), [movie])
        XCTAssertNil(tracker.nextRescanDelay(now: now.addingTimeInterval(3), settleFor: settle))
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
