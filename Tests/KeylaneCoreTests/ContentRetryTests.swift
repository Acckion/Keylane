import XCTest
import SQLite3
@testable import KeylaneCore

final class ContentRetryTests: XCTestCase {
    private func record(_ modified: Double = 1) -> FileIndexRecord {
        .init(path: "/fixture/doc.txt", name: "doc.txt", volume: "/", modified: modified, directory: false, symlink: false)
    }
    func testOneTimedRetryThenWaitsForFreshMetadataAndPermissionUsesEvents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.sqlite")
        var db = try FileSearchIndex(url: url)
        try db.stageMetadata(record(), root: "/fixture", epoch: "c:one", contentSearch: true)
        let job = try XCTUnwrap(db.nextContentJob())
        let now = Date()
        try db.failContent(job, reason: .transient, now: now, jitter: 1)
        XCTAssertEqual(try XCTUnwrap(db.nextContentRetry()).timeIntervalSince(now), 60, accuracy: 0.001)
        XCTAssertNil(try db.nextContentJob(now: now))
        db = try FileSearchIndex(url: url)
        let retry = try XCTUnwrap(db.nextContentJob(now: now.addingTimeInterval(60)))
        XCTAssertGreaterThan(retry.revision, job.revision)
        try db.failContent(job, reason: .permission)
        XCTAssertNotNil(try db.nextContentRetry(), "Stale job cannot alter timed retry")
        try db.failContent(retry, reason: .transient, now: now, jitter: 1)
        XCTAssertTrue(try db.hasEventDeferredContent())
        XCTAssertNil(try db.nextContentRetry())
        XCTAssertFalse(try db.completeContent(retry, body: "late"))
        try db.stageMetadata(record(2), root: "/fixture", epoch: "c:changed", contentSearch: true)
        let fresh = try XCTUnwrap(db.nextContentJob())
        XCTAssertNotEqual(fresh.token, retry.token)
        try db.failContent(fresh, reason: .permission)
        try db.stageMetadata(record(2), root: "/fixture", epoch: "c:unrelated", contentSearch: true)
        XCTAssertNil(try db.nextContentRetry(), "Unchanged full scan should not wake a permission wait")
        try db.stageMetadata(record(2), root: "/fixture", epoch: "c:permission-event", contentSearch: true, wakeFromEvent: true)
        let woke = try XCTUnwrap(db.nextContentJob())
        XCTAssertEqual(woke.token, fresh.token)
        XCTAssertGreaterThan(woke.revision, fresh.revision)
        try db.failContent(fresh, reason: .permission)
        XCTAssertNotNil(try db.nextContentJob(), "Late failure must not overwrite newer permission wakeup")
    }
    func testRetainedBodyHiddenUntilRevalidatedAndEqualBodySkipsFTSWrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.sqlite")
        let db = try FileSearchIndex(url: url)
        var options = FileSearchOptions(roots: ["/fixture"]); options.ignorePatterns = []; options.contentSearch = true
        try db.stageMetadata(record(), root: "/fixture", epoch: "c:one", contentSearch: true)
        XCTAssertTrue(try db.completeContent(XCTUnwrap(db.nextContentJob()), body: "stablebody xy"))
        try db.stageMetadata(record(2), root: "/fixture", epoch: "c:two", contentSearch: true)
        XCTAssertTrue(try db.search("stablebody", options: options).isEmpty)
        XCTAssertTrue(try db.search("xy", options: options).isEmpty)
        XCTAssertEqual(try db.search("doc", options: options).count, 1)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var q: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, "SELECT body FROM files", -1, &q, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(q), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(q, 0)), "stablebody xy", "Retain stored body for exact comparison, not for stale search")
        sqlite3_finalize(q)
        let writes = db.writeDiagnostics.contentWrites
        XCTAssertTrue(try db.completeContent(XCTUnwrap(db.nextContentJob()), body: "stablebody xy"), "Reuse still publishes newly valid matches")
        XCTAssertEqual(db.writeDiagnostics.contentWrites, writes)
        XCTAssertEqual(try db.search("stablebody", options: options).count, 1)
        XCTAssertEqual(try db.search("xy", options: options).count, 1)
        try db.stageMetadata(record(3), root: "/fixture", epoch: "c:three", contentSearch: true)
        let job = try XCTUnwrap(db.nextContentJob())
        try db.applyContent([.init(job: job, body: nil, failure: .permission)])
        XCTAssertTrue(try db.search("stablebody", options: options).isEmpty)
        XCTAssertThrowsError(try db.completeContent(job, body: "replacement", isCancelled: { true }))
        XCTAssertTrue(try db.hasEventDeferredContent())
        try db.clearBodies()
        XCTAssertFalse(try db.hasEventDeferredContent())
        XCTAssertTrue(try db.search("stablebody", options: options).isEmpty)
    }
    func testNativeUnreadableFileClassifiesAsPermission() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("fixture.txt")
        try Data("fixture".utf8).write(to: file)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).timeIntervalSince1970
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        let db = try FileSearchIndex(url: folder.appendingPathComponent("index.sqlite"))
        try db.stageMetadata(.init(path: file.path, name: file.lastPathComponent, volume: "/", modified: modified,
                                   directory: false, symlink: false), root: folder.path, epoch: "c:test", contentSearch: true)
        let job = try XCTUnwrap(db.nextContentJobs(certifiedOnly: true).first)
        XCTAssertThrowsError(try FileContentReader.read(job)) { XCTAssertEqual(FileContentReader.classify($0), .permission) }
    }
    func testVersionTwoQueueMigrationAndFailureClassification() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("index.sqlite")
        var db: FileSearchIndex? = try FileSearchIndex(url: url)
        try db!.stageMetadata(record(), root: "/fixture", epoch: "c:legacy", contentSearch: true)
        let token = try XCTUnwrap(db!.nextContentJob()).token
        db = nil
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, "ALTER TABLE file_content_queue DROP COLUMN attempts; ALTER TABLE file_content_queue DROP COLUMN failure; ALTER TABLE file_content_queue DROP COLUMN revision; PRAGMA user_version=2", nil, nil, nil), SQLITE_OK)
        db = try FileSearchIndex(url: url)
        XCTAssertEqual(try db!.nextContentJob()?.token, token)
        XCTAssertEqual(try db!.stats().entries, 1)
        XCTAssertEqual(FileContentReader.classify(FileContentReader.Failure.changed), .changed)
        XCTAssertEqual(FileContentReader.classify(CancellationError()), .cancelled)
        XCTAssertEqual(FileContentReader.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))), .permission)
        XCTAssertEqual(FileContentReader.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))), .missing)
        XCTAssertEqual(FileContentReader.classify(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))), .transient)
    }
}
