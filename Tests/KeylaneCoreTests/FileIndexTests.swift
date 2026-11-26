import XCTest
import SQLite3
@testable import KeylaneCore

final class FileIndexTests: XCTestCase {
    func testRecoveryPointPersistenceInvalidationRollbackAndClear() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let db = try FileSearchIndex(url: url)
        XCTAssertNil(try db.recoveryPoint(), "Existing indexes without an event cursor require recovery")
        let point = FileSearchIndex.RecoveryPoint(eventID: UInt64.max - 1, configuration: "授权目录与规则")
        try db.saveRecoveryPoint(point)
        XCTAssertEqual(try FileSearchIndex(url: url).recoveryPoint(), point)
        enum Interrupted: Error { case fixture }
        XCTAssertThrowsError(try db.transaction {
            try db.invalidateRecoveryPoint()
            throw Interrupted.fixture
        })
        XCTAssertEqual(try db.recoveryPoint(), point)
        try db.invalidateRecoveryPoint()
        XCTAssertNil(try db.recoveryPoint())
        try db.saveRecoveryPoint(point)
        try db.clear()
        XCTAssertNil(try FileSearchIndex(url: url).recoveryPoint())
    }

    func testCheckpointTriggersAndClearAreTransactionalAcrossConnections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try FileSearchIndex(url: url)
        let reader = try FileSearchIndex(url: url)
        var old: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &old), SQLITE_OK)
        defer { sqlite3_close(old) }
        func raw(_ sql: String, expected: Int32 = SQLITE_OK) {
            XCTAssertEqual(sqlite3_exec(old, sql, nil, nil, nil), expected, sql)
        }
        let row = "INSERT INTO files(path,name,root,volume,modified,directory,symlink,epoch) VALUES('/fixture/needle','needle','/fixture','/',1,0,0,'scan')"
        let point = FileSearchIndex.RecoveryPoint(eventID: 10, configuration: "fixture")
        try writer.saveRecoveryPoint(point)
        raw("BEGIN IMMEDIATE; " + row)
        XCTAssertEqual(try reader.recoveryPoint(), point)
        XCTAssertEqual(try reader.stats().entries, 0)
        raw("ROLLBACK")
        XCTAssertEqual(try reader.recoveryPoint(), point)
        raw(row)
        XCTAssertNil(try reader.recoveryPoint())
        XCTAssertEqual(try reader.stats().entries, 1)
        XCTAssertEqual(try reader.search("needle", options: .init(roots: ["/fixture"])).count, 1)
        try writer.saveRecoveryPoint(point)
        raw("UPDATE files SET name='changed' WHERE path='/fixture/needle'")
        XCTAssertNil(try reader.recoveryPoint())
        XCTAssertEqual(try reader.search("changed", options: .init(roots: ["/fixture"])).count, 1)
        try writer.saveRecoveryPoint(point)
        raw("DELETE FROM files")
        XCTAssertNil(try reader.recoveryPoint())
        XCTAssertEqual(try reader.stats().entries, 0)
        raw(row)
        try writer.saveRecoveryPoint(point)
        raw("CREATE TRIGGER test_abort_clear BEFORE DELETE ON files BEGIN SELECT RAISE(ABORT,'fixture'); END;")
        XCTAssertThrowsError(try writer.clear())
        XCTAssertEqual(try reader.recoveryPoint(), point)
        XCTAssertEqual(try reader.stats().entries, 1)
        raw("DROP TRIGGER test_abort_clear")
        try writer.clear()
        XCTAssertNil(try reader.recoveryPoint())
        XCTAssertEqual(try reader.stats().entries, 0)
    }

    func testScansRejectOutsideCommitsAndIdleCannotRestoreMissingBaseline() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try FileSearchIndex(url: url)
        let outside = try FileSearchIndex(url: url)
        let point = FileSearchIndex.RecoveryPoint(eventID: 10, configuration: "fixture")
        let newer = FileSearchIndex.RecoveryPoint(eventID: 12, configuration: "fixture")
        let row = FileIndexRecord(path: "/fixture/needle", name: "needle", volume: "/", modified: 1, directory: false, symlink: false)
        let scan = try XCTUnwrap(writer.beginRecoveryScan())
        XCTAssertNil(try outside.recoveryPoint())
        XCTAssertFalse(try outside.completeRecoveryScan(scan, point: point))
        enum Abort: Error { case fixture }
        XCTAssertThrowsError(try outside.transaction {
            try outside.put(row, root: "/fixture", epoch: "rolled-back")
            throw Abort.fixture
        })
        try writer.put(row, root: "/fixture", epoch: "own")
        XCTAssertTrue(try writer.completeRecoveryScan(scan, point: point))
        XCTAssertTrue(try writer.advanceExistingRecoveryPoint(newer))
        XCTAssertTrue(try writer.advanceExistingRecoveryPoint(point))
        XCTAssertEqual(try outside.recoveryPoint(), newer, "An idle writer cannot rewind a newer cursor")
        XCTAssertNil(try writer.beginRecoveryScan(requiring: ["wrong baseline"]))
        let overlapping = try XCTUnwrap(writer.beginRecoveryScan(requiring: [point.configuration]))
        try outside.put(row, root: "/fixture", epoch: "outside committed")
        XCTAssertFalse(try writer.completeRecoveryScan(overlapping, point: newer))
        XCTAssertNil(try outside.recoveryPoint())
        XCTAssertFalse(try writer.advanceExistingRecoveryPoint(newer))
        XCTAssertNil(try writer.beginRecoveryScan(requiring: [point.configuration]))
        let fresh = try XCTUnwrap(writer.beginRecoveryScan())
        XCTAssertTrue(try writer.completeRecoveryScan(fresh, point: newer))
        try outside.put(row, root: "/fixture", epoch: "after publication")
        XCTAssertNil(try writer.recoveryPoint())
    }

    func testBodyCompletionPreservesCheckpointButOwnershipAndForeignScanWritesDoNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document.txt")
        try Data("fixture body".utf8).write(to: file)
        let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let row = FileIndexRecord(path: file.path, name: file.lastPathComponent, volume: "/",
                                  modified: modified.timeIntervalSince1970, directory: false, symlink: false)
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try FileSearchIndex(url: url)
        let other = try FileSearchIndex(url: url)
        let point = FileSearchIndex.RecoveryPoint(eventID: 10, configuration: "fixture", historyDomain: UUID())
        try writer.stageMetadata(row, root: directory.path, epoch: "c:initial", contentSearch: true)
        let job = try XCTUnwrap(writer.nextContentJobs(certifiedOnly: true).first)
        try writer.saveRecoveryPoint(point)
        XCTAssertTrue(try writer.completeContent(job, body: FileContentReader.read(job)))
        XCTAssertEqual(try other.recoveryPoint(), point)
        XCTAssertFalse(try other.completeContent(job, body: "stale"))
        XCTAssertEqual(try other.recoveryPoint(), point)
        XCTAssertTrue(try writer.touchUnchanged(row, root: directory.path, epoch: "c:initial", contentSearch: true))
        XCTAssertEqual(try other.recoveryPoint(), point, "An unchanged row must not invalidate the cursor")
        XCTAssertTrue(try other.touchUnchanged(row, root: directory.deletingLastPathComponent().path, epoch: "c:initial", contentSearch: true))
        XCTAssertNil(try writer.recoveryPoint(), "Foreign ownership mutation invalidates the cursor")
        try writer.stageMetadata(row, root: directory.path, epoch: "c:next", contentSearch: true, force: true)
        let next = try XCTUnwrap(writer.nextContentJobs(certifiedOnly: true).first)
        let scan = try XCTUnwrap(writer.beginRecoveryScan())
        XCTAssertTrue(try other.completeContent(next, body: FileContentReader.read(next)))
        XCTAssertFalse(try writer.completeRecoveryScan(scan, point: point), "Any foreign commit during a baseline invalidates its scan")
        XCTAssertNil(try writer.recoveryPoint())
        try writer.saveRecoveryPoint(point)
        try writer.clearBodies()
        XCTAssertNil(try other.recoveryPoint(), "Body-policy epoch changes are structural")
    }

    func testRetiredWatcherCannotPublishScanOrAdvanceIdleCursor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let point = FileSearchIndex.RecoveryPoint(eventID: 500, configuration: "test-domain")
        let scan = try XCTUnwrap(writer.beginRecoveryScan())
        XCTAssertFalse(try writer.completeRecoveryScan(scan, point: point, whileCurrent: { false }))
        XCTAssertNil(try writer.recoveryPoint())
        let next = try XCTUnwrap(writer.beginRecoveryScan())
        let newPoint = FileSearchIndex.RecoveryPoint(eventID: 12, configuration: "test-domain")
        XCTAssertTrue(try writer.completeRecoveryScan(next, point: newPoint))
        XCTAssertFalse(try writer.advanceExistingRecoveryPoint(point, whileCurrent: { false }))
        XCTAssertEqual(try writer.recoveryPoint(), newPoint)
    }

    func testRecoverySQLiteUpdatesRequireSameHistoryDomain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let domain = UUID()
        let old = FileSearchIndex.RecoveryPoint(eventID: 21, configuration: "fixture", historyDomain: domain)
        try db.saveRecoveryPoint(old)
        XCTAssertEqual(try db.recoveryPoint(), old)
        XCTAssertNil(try db.beginRecoveryScan(requiring: ["fixture"], historyDomain: UUID()))
        XCTAssertNil(try db.beginRecoveryScan(requiring: ["fixture"]))
        XCTAssertFalse(try db.advanceExistingRecoveryPoint(.init(eventID: 22, configuration: "fixture")))
        XCTAssertFalse(try db.advanceExistingRecoveryPoint(.init(eventID: 22, configuration: "fixture", historyDomain: UUID())))
        XCTAssertEqual(try db.recoveryPoint(), old)
        XCTAssertNotNil(try db.beginRecoveryScan(requiring: ["fixture"], historyDomain: domain))
        XCTAssertNil(try db.recoveryPoint())
    }

    func testInstallingMissingCheckpointTriggersInvalidatesOnceWithoutClearingRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let initial = try FileSearchIndex(url: url)
        try initial.put(.init(path: "/fixture/item", name: "item", volume: "/", modified: 1, directory: false, symlink: false),
                        root: "/fixture", epoch: "old")
        let point = FileSearchIndex.RecoveryPoint(eventID: 10, configuration: "fixture")
        try initial.saveRecoveryPoint(point)
        var old: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &old), SQLITE_OK)
        defer { sqlite3_close(old) }
        XCTAssertEqual(sqlite3_exec(old, "DROP TRIGGER file_recovery_files_structural_update", nil, nil, nil), SQLITE_OK)
        let migrated = try FileSearchIndex(url: url)
        XCTAssertNil(try migrated.recoveryPoint())
        XCTAssertEqual(try migrated.stats().entries, 1)
        try migrated.saveRecoveryPoint(point)
        XCTAssertEqual(try FileSearchIndex(url: url).recoveryPoint(), point)
    }

    func testPartialRecoveryKeepsUnreadableSubtreesAndPrunesOtherStaleRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        for i in 0..<1100 {
            let path = i % 2 == 0 ? "/fixture/locked/item-\(i)" : "/fixture/removed-\(i)"
            try db.put(.init(path: path, name: "item", volume: "/", modified: 1, directory: false, symlink: false), root: "/fixture", epoch: "old")
        }
        try db.put(.init(path: "/fixture/locked-sibling", name: "sibling", volume: "/", modified: 1, directory: false, symlink: false), root: "/fixture", epoch: "old")
        try db.removeUnseen(root: "/fixture", epoch: "new", preserving: ["/fixture/locked"])
        XCTAssertEqual(try db.stats().entries, 550)
        let point = FileSearchIndex.RecoveryPoint(eventID: 42, configuration: "fixture", retryPaths: ["/fixture/locked"])
        try db.saveRecoveryPoint(point)
        XCTAssertEqual(try db.recoveryPoint(), point)
        try db.removeUnseen(root: "/fixture", subtree: "/fixture/locked", epoch: "new", preserving: [])
        XCTAssertEqual(try db.stats().entries, 0)
        let legacy = Data(#"{"eventID":42,"configuration":"fixture"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(FileSearchIndex.RecoveryPoint.self, from: legacy).retryPaths, [])
    }

    func testDurableContentJobsRejectStaleResultsAndSurviveMetadataTouches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let db = try FileSearchIndex(url: url)
        func record(_ modified: Double) -> FileIndexRecord {
            .init(path: "/fixture/document.txt", name: "document.txt", volume: "/", modified: modified, directory: false, symlink: false)
        }
        try db.transaction { try db.stageMetadata(record(1), root: "/fixture", epoch: "c:first", contentSearch: true) }
        let old = try XCTUnwrap(db.nextContentJob())
        try db.removeUnseen(root: "/fixture", epoch: "c:first")
        XCTAssertEqual(try db.stats().entries, 1, "Pending content must not alter metadata reconciliation epochs")
        XCTAssertThrowsError(try db.completeContent(old, body: "cancelled", isCancelled: { true }))
        XCTAssertEqual(try db.nextContentJob()?.token, old.token)
        var cancellationChecks = 0
        XCTAssertThrowsError(try db.completeContent(old, body: "rolledback", isCancelled: { cancellationChecks += 1; return cancellationChecks == 2 }))
        XCTAssertEqual(try db.nextContentJob()?.token, old.token, "Cancellation during a write must roll back the job deletion")
        try db.stageMetadata(record(1), root: "/fixture", epoch: "c:touch", contentSearch: true)
        XCTAssertEqual(try db.nextContentJob()?.token, old.token)
        XCTAssertTrue(try db.completeContent(old, body: "firstbody"))
        var options = FileSearchOptions(roots: ["/fixture"]); options.contentSearch = true; options.ignorePatterns = []
        XCTAssertEqual(try db.search("firstbody", options: options).count, 1)
        try db.stageMetadata(record(2), root: "/fixture", epoch: "c:changed", contentSearch: true)
        XCTAssertTrue(try db.search("firstbody", options: options).isEmpty, "Changed metadata must immediately clear stale body matches")
        let fresh = try XCTUnwrap(FileSearchIndex(url: url).nextContentJob())
        XCTAssertNotEqual(fresh.token, old.token)
        XCTAssertFalse(try db.completeContent(old, body: "stale"))
        XCTAssertEqual(try db.nextContentJob()?.token, fresh.token)
        try db.deferContent(fresh, until: Date().addingTimeInterval(60))
        XCTAssertNil(try db.nextContentJob())
        XCTAssertNotNil(try db.nextContentRetry())
        XCTAssertTrue(try db.completeContent(fresh, body: "freshbody"))
        XCTAssertNil(try db.nextContentJob())
        try db.stageMetadata(record(3), root: "/fixture", epoch: "c:third", contentSearch: true)
        let pending = try XCTUnwrap(db.nextContentJob())
        try db.clearBodies()
        XCTAssertNil(try db.nextContentJob())
        XCTAssertFalse(try db.completeContent(pending, body: "disabled"))
        try db.stageMetadata(record(3), root: "/fixture", epoch: "c:enabled", contentSearch: true)
        XCTAssertNotNil(try db.nextContentJob(), "Cleared pending bodies must be extracted after reenable")
        try db.removeScope("/fixture")
        XCTAssertNil(try db.nextContentJob(), "Deleted rows cannot retain extraction work")
        try db.clear()
        try db.stageMetadata(record(4), root: "/fixture", epoch: "c:after-vacuum", contentSearch: true)
        XCTAssertNotNil(try db.nextContentJob(), "Cached SQL plans must remain valid after clear/VACUUM")
    }

    func testDeferredContentReaderBoundsAndRejectsSymlinkPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("bounded.txt")
        try Data(("safe" + String(repeating: "x", count: 120_000)).utf8).write(to: file)
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).timeIntervalSince1970
        try db.stageMetadata(.init(path: file.path, name: "bounded.txt", volume: "/", modified: modified, directory: false, symlink: false), root: directory.path, epoch: "c:scan", contentSearch: true)
        let job = try XCTUnwrap(db.nextContentJob())
        XCTAssertEqual(try FileContentReader.read(job).count, 100_000)
        XCTAssertThrowsError(try FileContentReader.read(job, cancelled: { true }))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("outside.txt"))
        XCTAssertThrowsError(try FileContentReader.read(job))
    }

    func testContentBatchIsBoundedAndCancelledCommitRollsBackEveryJob() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        for i in 0..<10 {
            try db.stageMetadata(.init(path: "/fixture/doc-\(i).txt", name: "doc-\(i).txt", volume: "/", modified: 1, directory: false, symlink: false), root: "/fixture", epoch: "c:scan", contentSearch: true)
        }
        let jobs = try db.nextContentJobs(limit: 999)
        XCTAssertEqual(jobs.count, 8)
        let updates = jobs.map { FileSearchIndex.ContentUpdate(job: $0, body: "batchbody") }
        var checks = 0
        XCTAssertThrowsError(try db.applyContent(updates, isCancelled: { checks += 1; return checks == 4 }))
        XCTAssertEqual(try db.nextContentJobs().map(\.token), jobs.map(\.token))
        var options = FileSearchOptions(roots: ["/fixture"]); options.ignorePatterns = []; options.contentSearch = true
        XCTAssertTrue(try db.search("batchbody", options: options).isEmpty)
        XCTAssertTrue(try db.applyContent(updates))
        XCTAssertEqual(try db.nextContentJobs().count, 2)
        XCTAssertEqual(try db.search("batchbody", options: options).count, 8)
    }

    func testContentSessionRejectsRootReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = directory.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        let file = scope.appendingPathComponent("document.txt")
        try Data("approved".utf8).write(to: file)
        let modified = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).timeIntervalSince1970
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        try db.stageMetadata(.init(path: file.path, name: "document.txt", volume: "/", modified: modified, directory: false, symlink: false),
                             root: scope.path, epoch: "c:scope", contentSearch: true)
        let job = try XCTUnwrap(db.nextContentJob())
        let session = FileContentReader.Session()
        XCTAssertEqual(try session.read(job), "approved")
        var bodyReads = 0
        XCTAssertThrowsError(try session.read(job, allows: { false }, extraction: { bodyReads += 1; return "" }))
        XCTAssertEqual(bodyReads, 0)
        try FileManager.default.moveItem(at: scope, to: directory.appendingPathComponent("moved"))
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: false)
        try Data("replacement".utf8).write(to: file)
        XCTAssertThrowsError(try session.read(job), "A pinned root must not silently follow a replacement directory")
        XCTAssertThrowsError(try FileContentReader.Session().read(job, extraction: { bodyReads += 1; return "" }))
        XCTAssertEqual(bodyReads, 0, "A fresh worker may not use an unapproved root")
    }

    func testContentQueueTracksOverlappingScopeOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let record = FileIndexRecord(path: "/fixture/sub/document.txt", name: "document.txt", volume: "/", modified: 1, directory: false, symlink: false)
        try db.stageMetadata(record, root: "/fixture", epoch: "c:parent", contentSearch: true)
        let parent = try XCTUnwrap(db.nextContentJob())
        try db.stageMetadata(record, root: "/fixture/sub", epoch: "c:child", contentSearch: true)
        let child = try XCTUnwrap(db.nextContentJob())
        XCTAssertEqual(child.root, "/fixture/sub")
        XCTAssertFalse(try db.completeContent(parent, body: "staleparent"))
        XCTAssertEqual(try db.nextContentJob()?.root, child.root, "Old owner must not delete the retargeted request")
        try db.deferContent(parent, until: Date().addingTimeInterval(60))
        XCTAssertNotNil(try db.nextContentJob(), "Old owner must not delay a different scope's request")
        let other = try FileSearchIndex(url: db.url)
        try other.deferContent(child, until: .distantFuture)
        let abandoned = try FileSearchIndex(url: db.url)
        enum Fixture: Error { case rollback }
        XCTAssertThrowsError(try abandoned.transaction {
            try abandoned.stageMetadata(record, root: "/fixture", epoch: "c:rollback", contentSearch: true)
            throw Fixture.rollback
        })
        XCTAssertNil(try db.nextContentJob(), "Rollback must also roll back token and retry state")
        try other.stageMetadata(record, root: "/fixture", epoch: "c:returned", contentSearch: true)
        let reopened = try FileSearchIndex(url: db.url)
        let returned = try XCTUnwrap(reopened.nextContentJob())
        XCTAssertNotEqual(child.token, parent.token)
        XCTAssertNotEqual(returned.token, child.token)
        XCTAssertNotEqual(returned.token, parent.token)
        for stale in [parent, child] {
            XCTAssertFalse(try db.completeContent(stale, body: "stalebody"))
            try db.deferContent(stale, until: .distantFuture)
            XCTAssertEqual(try reopened.nextContentJob()?.token, returned.token)
        }
        XCTAssertTrue(try reopened.completeContent(returned, body: "currentbody"))
        var options = FileSearchOptions(roots: ["/fixture", "/fixture/sub"]); options.contentSearch = true; options.ignorePatterns = []
        XCTAssertEqual(try db.search("currentbody", options: options).count, 1)
        XCTAssertTrue(try db.search("stalebody", options: options).isEmpty)
    }

    func testUncertifiedDeferredEntryRequiresRescanAndChangedEntryNeverCallsReader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document.txt")
        try Data("old version".utf8).write(to: file)
        let date = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let record = FileIndexRecord(path: file.path, name: "document.txt", volume: "/", modified: date.timeIntervalSince1970, directory: false, symlink: false)
        try db.stageMetadata(record, root: directory.path, epoch: "c:legacy", contentSearch: true, allowCertification: false)
        let legacy = try XCTUnwrap(db.nextContentJob())
        XCTAssertTrue(try db.nextContentJobs(certifiedOnly: true).isEmpty)
        var reads = 0
        let reader = FileContentReader.Session()
        XCTAssertThrowsError(try reader.read(legacy, extraction: { reads += 1; return "" }))
        try db.stageMetadata(record, root: directory.path, epoch: "c:certify", contentSearch: true)
        let original = try XCTUnwrap(db.nextContentJobs(certifiedOnly: true).first)
        XCTAssertNotEqual(original.token, legacy.token)
        XCTAssertEqual(try reader.read(original), "old version")
        // An ordinary editor-style replacement retains the name and document
        // date. Only the new certified scan may authorize extraction.
        try Data("new version".utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        XCTAssertThrowsError(try reader.read(original, extraction: { reads += 1; return "" }))
        XCTAssertEqual(reads, 0)
        try db.stageMetadata(record, root: directory.path, epoch: "c:recertify", contentSearch: true)
        let latest = try XCTUnwrap(db.nextContentJobs(certifiedOnly: true).first)
        XCTAssertNotEqual(latest.token, original.token)
        XCTAssertEqual(try reader.read(latest), "new version")
    }

    func testDeferredFailuresParkAndRequireRestagingInsteadOfIdleRetries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("document.txt")
        try Data("fixture".utf8).write(to: file)
        let date = try XCTUnwrap(file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let row = FileIndexRecord(path: file.path, name: file.lastPathComponent, volume: "/",
                                  modified: date.timeIntervalSince1970, directory: false, symlink: false)
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        try db.stageMetadata(row, root: directory.path, epoch: "c:first", contentSearch: true)
        let first = try XCTUnwrap(db.nextContentJobs(certifiedOnly: true).first)
        XCTAssertFalse(try db.applyContent([.init(job: first, body: nil)]))
        XCTAssertTrue(try db.nextContentJobs(certifiedOnly: true).isEmpty)
        let reopened = try FileSearchIndex(url: db.url)
        let retry = try XCTUnwrap(reopened.nextContentJobs(now: .distantFuture, certifiedOnly: true).first)
        XCTAssertEqual(retry.token, first.token)
        XCTAssertFalse(try reopened.applyContent([.init(job: retry, body: nil)]))
        XCTAssertNil(try db.nextContentRetry(certifiedOnly: true))
        XCTAssertFalse(try db.completeContent(retry, body: "parked"))
        try db.stageMetadata(row, root: directory.path, epoch: "c:rescan", contentSearch: true)
        let changed = try XCTUnwrap(db.nextContentJobs(certifiedOnly: true).first)
        XCTAssertNotEqual(changed.token, retry.token)
        XCTAssertFalse(try db.applyContent([.init(job: changed, body: nil, parkUntilScan: true)]))
        XCTAssertNil(try reopened.nextContentRetry(certifiedOnly: true), "Rejected proof does not schedule a retry")
        XCTAssertFalse(try reopened.completeContent(changed, body: "revoked"))
    }

    func testStatisticsStayConsistentAcrossConnectionsAndRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        let writer = try FileSearchIndex(url: url)
        let reader = try FileSearchIndex(url: url)
        func put(_ name: String, directory: Bool = false, symlink: Bool = false) throws {
            try writer.put(.init(path: "/fixture/" + name, name: name, volume: "/", modified: 1,
                                 directory: directory, symlink: symlink), root: "/fixture", epoch: "first")
        }
        try put("text")
        try put("folder", directory: true)
        try put("link", symlink: true)
        let initial = try reader.stats()
        XCTAssertEqual([initial.entries, initial.files, initial.directories, initial.symlinks], [3, 1, 1, 1])
        try put("text", directory: true)
        let changed = try reader.stats()
        XCTAssertEqual([changed.entries, changed.files, changed.directories, changed.symlinks], [3, 0, 2, 1])
        enum Failure: Error { case rollback }
        XCTAssertThrowsError(try writer.transaction {
            try put("rolled-back")
            try writer.removeScope("/fixture")
            throw Failure.rollback
        })
        XCTAssertEqual(try reader.stats().entries, 3)
        try writer.removeUnseen(root: "/fixture", subtree: "/fixture/folder", epoch: "next")
        XCTAssertEqual(try reader.stats().directories, 1)
        try writer.clear()
        XCTAssertEqual(try reader.stats().entries, 0)
    }

    func testStatisticsInitializeExistingDatabaseOnceAndTrackOlderWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        var index: FileSearchIndex? = try FileSearchIndex(url: url)
        try index!.put(.init(path: "/fixture/retained", name: "retained", volume: "/", modified: 1,
                             directory: false, symlink: false), root: "/fixture", epoch: "old")
        index = nil
        var legacy: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &legacy), SQLITE_OK)
        defer { sqlite3_close(legacy) }
        // Recreate the pre-counter state without changing the file records.
        XCTAssertEqual(sqlite3_exec(legacy, "DROP TRIGGER file_counts_insert; DROP TRIGGER file_counts_delete; DROP TRIGGER file_counts_update; DROP TABLE file_counts", nil, nil, nil), SQLITE_OK)
        let migrated = try FileSearchIndex(url: url)
        XCTAssertEqual(try migrated.stats().entries, 1)
        XCTAssertEqual(sqlite3_exec(legacy, "DELETE FROM files", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try migrated.stats().entries, 0)
        XCTAssertEqual(try FileSearchIndex(url: url).stats().entries, 0)
    }

    func testSubtreeCleanupPreservesEpochOwnerAndSiblingBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let root = "/fixture"
        let rows = [
            ("/fixture/target", root, "old"),
            ("/fixture/target/removed.txt", root, "old"),
            ("/fixture/target/current.txt", root, "current"),
            ("/fixture/target/other-owner.txt", "/other", "old"),
            ("/fixture/target-extra.txt", root, "old"),
            ("/fixture/target0/sibling.txt", root, "old")
        ]
        for (path, owner, epoch) in rows {
            try db.put(.init(path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                             volume: "/", modified: 1, directory: false, symlink: false),
                       body: String(repeating: "body ", count: 1024), root: owner, epoch: epoch)
        }
        try db.removeUnseen(root: root, subtree: "/fixture/target", epoch: "current")
        XCTAssertEqual(try db.stats().entries, 4)
        let options = FileSearchOptions(roots: [root, "/other"])
        XCTAssertTrue(try db.search("removed", options: options).isEmpty)
        for query in ["current", "other-owner", "target-extra", "sibling"] {
            XCTAssertEqual(try db.search(query, options: options).count, 1)
        }
    }

    func testChineseMultiwordNamesAndLiteralPunctuation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        var options = FileSearchOptions(roots:["/fixtures"])
        let db = try FileSearchIndex(url:directory.appendingPathComponent("index.sqlite"))
        func put(_ name: String, body: String = "", external: Bool = false) throws {
            try db.put(.init(path:"/fixtures/"+name,name:name,volume:"/",modified:1,directory:false,symlink:false,external:external),body:body,root:"/fixtures",epoch:"first")
        }
        try put("作业-2.pdf"); try put("报告 预算2026.txt"); try put("100%_value.txt")
        XCTAssertEqual(try db.search("作业",options:options).map(\.name),["作业-2.pdf"])
        XCTAssertEqual(try db.search("预算 报告",options:options).map(\.name),["报告 预算2026.txt"])
        XCTAssertEqual(try db.search("100%_",options:options).map(\.name),["100%_value.txt"])
        XCTAssertTrue(try db.search("100__",options:options).isEmpty)
        XCTAssertEqual(try db.search("%_", options: options).map(\.name), ["100%_value.txt"])
        XCTAssertEqual(try db.search("ＶＡ", options: options).map(\.name), ["100%_value.txt"])
        try put("正文测试.txt",body:"独立内容关键词")
        XCTAssertTrue(try db.search("内容关键词",options:options).isEmpty)
        options.contentSearch = true
        XCTAssertEqual(try db.search("内容关键词",options:options).map(\.name),["正文测试.txt"])
        XCTAssertEqual(try db.search("内容",options:options).map(\.name),["正文测试.txt"])
        try db.clearBodies()
        XCTAssertTrue(try db.search("内容关键词",options:options).isEmpty)
        try put("外接磁盘.txt",external:true)
        options.externalVolumes = false
        XCTAssertTrue(try db.search("外接",options:options).isEmpty)
        XCTAssertEqual(try db.stats().entries,5)
        try db.removeUnseen(root:"/fixtures",epoch:"new")
        XCTAssertEqual(try db.stats().entries,0)
    }
    func testRelevanceBeforeCandidateLimit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let root = "/fixture"
        func insert(_ name: String, modified: Double) throws {
            try db.put(.init(path: root + "/" + name, name: name, volume: "/", modified: modified,
                             directory: false, symlink: false), root: root, epoch: "n:fixture")
        }
        try db.transaction {
            try insert("作业", modified: 0)
            try insert("作业原稿", modified: 1)
            for i in 0..<2000 { try insert("备份作业-\(i)", modified: Double(i + 2)) }
        }
        let hits = try db.search("作业", options: .init(roots: [root]), limit: 2)
        XCTAssertEqual(hits.map(\.name), ["作业", "作业原稿"])
    }
    func testLauncherOptionDecodesOldSettingsWithoutLosingScopes() throws {
        var config = FileSearchOptions(roots:["/preserved-scope"]); config.contentSearch = true
        let data = try JSONEncoder().encode(config)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        json.removeValue(forKey:"searchFromLauncher")
        let previous = try JSONSerialization.data(withJSONObject:json)
        let restored = try JSONDecoder().decode(FileSearchOptions.self,from:previous)
        XCTAssertEqual(restored.roots,["/preserved-scope"]); XCTAssertTrue(restored.contentSearch); XCTAssertFalse(restored.searchFromLauncher)
    }
    func testCancelledDatabaseSearchCanBeFollowedByAnotherSearch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let db = try FileSearchIndex(url:directory.appendingPathComponent("index.sqlite"))
        try db.transaction { for index in 0..<2000 { try db.put(.init(path:"/fixture/作业-\(index).pdf",name:"作业-\(index).pdf",volume:"/",modified:1,directory:false,symlink:false),root:"/fixture",epoch:"n:1") } }
        let config = FileSearchOptions(roots:["/fixture"])
        var checks = 0
        XCTAssertTrue(try db.search("作业",options:config,isCancelled:{ checks += 1; return checks > 4 }).isEmpty)
        XCTAssertEqual(try db.search("作业",options:config).count,200)
    }
    func testGlobsAndInheritedIgnoreRules() {
        let patterns = ["*.tmp", "build/", "**/[Cc]ache/**", "/root/exact.txt"]
        let paths = ["/root/build", "/root/Cache", "/root/a.tmp", "/root/exact.txt", "/root/文档"]
        for directory in [false, true] {
            let filter = FileSearchRules.pathFilter(patterns, directory: directory)
            for path in paths {
                let name = URL(fileURLWithPath: path).lastPathComponent
                XCTAssertEqual(filter(path, name), patterns.contains {
                    FileSearchRules.glob($0, matches: path, directory: directory)
                }, path)
            }
        }
        XCTAssertTrue(FileSearchRules.glob("node_modules",matches:"/root/node_modules",directory:true))
        XCTAssertTrue(FileSearchRules.glob("**/[Cc]ache/**",matches:"/root/Cache",directory:true))
        XCTAssertTrue(FileSearchRules.glob("**/.git/**",matches:"/root/.git",directory:true))
        XCTAssertTrue(FileSearchRules.glob("*.tmp",matches:"/root/sub/file.tmp"))
        XCTAssertFalse(FileSearchRules.glob("*.tmp",matches:"/root/sub/file.txt"))
        let rules = [FileSearchRules.IgnoreRule(base:"/root",line:"*.log"),FileSearchRules.IgnoreRule(base:"/root",line:"!keep.log")]
        XCTAssertTrue(FileSearchRules.ignored(URL(fileURLWithPath:"/root/no.log"),directory:false,patterns:[],rules:rules))
        XCTAssertFalse(FileSearchRules.ignored(URL(fileURLWithPath:"/root/keep.log"),directory:false,patterns:[],rules:rules))
        XCTAssertFalse(FileSearchRules.ignored(URL(fileURLWithPath:"/other/no.log"),directory:false,patterns:[],rules:rules))
        let anchored = [FileSearchRules.IgnoreRule(base:"/root",line:"/only.txt")]
        XCTAssertTrue(FileSearchRules.ignored(URL(fileURLWithPath:"/root/only.txt"),directory:false,patterns:[],rules:anchored))
        XCTAssertFalse(FileSearchRules.ignored(URL(fileURLWithPath:"/root/sub/only.txt"),directory:false,patterns:[],rules:anchored))
        let escaped = [FileSearchRules.IgnoreRule(base:"/root",line:"\\!literal.txt")]
        XCTAssertTrue(FileSearchRules.ignored(URL(fileURLWithPath:"/root/!literal.txt"),directory:false,patterns:[],rules:escaped))
    }
    func testIndexPersistsAndDisabledSearchDoesNotExposeRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("index.sqlite")
        do { let db = try FileSearchIndex(url:url); try db.put(.init(path:"/offline/作业.pdf",name:"作业.pdf",volume:"/offline",modified:1,directory:false,symlink:false),root:"/offline",epoch:"1") }
        let reopened = try FileSearchIndex(url:url)
        var config = FileSearchOptions(roots:["/offline"])
        XCTAssertEqual(try reopened.search("作业",options:config).count,1)
        config.enabled = false
        XCTAssertTrue(try reopened.search("作业",options:config).isEmpty)
        try reopened.removeScope("/offline")
        XCTAssertEqual(try reopened.stats().entries,0)
    }

    func testAncestorExclusionsPrecedeBothCandidateAndResultCaps() throws {
        let parent = try XCTUnwrap(FileSearchLocation.canonicalPath(FileManager.default.temporaryDirectory.path))
        let fixture = URL(fileURLWithPath: parent).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        for excludedCount in [240, 2400] {
            let root = fixture.appendingPathComponent("scope-\(excludedCount)").path
            let db = try FileSearchIndex(url: fixture.appendingPathComponent("index-\(excludedCount).sqlite"))
            var options = FileSearchOptions(roots: [root])
            options.ignorePatterns = ["__pycache__", "custom-excluded"]
            options.useIgnoreFiles = false
            try db.transaction {
                for i in 0..<excludedCount {
                    let folder = i.isMultiple(of: 2) ? "package/__pycache__/nested" : "custom-excluded/nested"
                    let name = "needle-obsolete-\(i).txt"
                    try db.put(.init(path: root + "/" + folder + "/" + name, name: name, volume: "/",
                                     modified: Double(10_000 + i), directory: false, symlink: false), root: root, epoch: "saved")
                }
                for i in 0..<250 {
                    let name = "needle-visible-\(i).txt"
                    try db.put(.init(path: root + "/" + name, name: name, volume: "/", modified: Double(i),
                                     directory: false, symlink: false), root: root, epoch: "saved")
                }
            }
            let expected = (50..<250).reversed().map { "needle-visible-\($0).txt" }
            XCTAssertEqual(try db.search("needle", options: options).map(\.name), expected)
            XCTAssertEqual(try db.search("needle", options: options, limit: 5).map(\.name), Array(expected.prefix(5)))
            // Cover the short-name covering-index query as well as the FTS path.
            XCTAssertEqual(try db.search("ne", options: options, limit: 5).map(\.name), Array(expected.prefix(5)))
            var checks = 0
            XCTAssertTrue(try db.search("needle", options: options, isCancelled: { checks += 1; return checks > 80 }).isEmpty)
            XCTAssertEqual(try db.search("needle", options: options, limit: 5).map(\.name), Array(expected.prefix(5)))
            XCTAssertEqual(try db.stats().entries, excludedCount + 250)
        }
    }


    func testPrelimitPolicyPreservesExplicitlyRestoredDirectories() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let db = try FileSearchIndex(url: fixture.appendingPathComponent("index.sqlite"))
        let root = "/offline-fixture"
        let restored = root + "/DerivedData"
        let path = restored + "/needle-restored.txt"
        var options = FileSearchOptions(roots: [root])
        options.ignorePatterns = []
        options.useIgnoreFiles = false
        try db.put(.init(path: path, name: "needle-restored.txt", volume: "/", modified: 1,
                         directory: false, symlink: false), root: root, epoch: "saved")
        var excluded = FileSearchLocation(options: options, automaticExclusions: [])
        var allowed = FileSearchLocation(options: options, automaticExclusions: [], restored: [restored])
        XCTAssertTrue(try db.search("needle", options: options,
            pathAllowed: { excluded.includesSavedResult(at: $0, directory: $1) }).isEmpty)
        XCTAssertEqual(try db.search("needle", options: options,
            pathAllowed: { allowed.includesSavedResult(at: $0, directory: $1) }).map(\.id), [path])
        XCTAssertTrue(try db.search("needle", options: options,
            pathAllowed: { excluded.includesSavedResult(at: $0, directory: $1) }).isEmpty)
    }


    func testSavedDirectoryBitSurvivesDirectoryOnlyAllowRulesAndOfflineMetadata() throws {
        let parent = try XCTUnwrap(FileSearchLocation.canonicalPath(FileManager.default.temporaryDirectory.path))
        let fixture = URL(fileURLWithPath: parent).appendingPathComponent(UUID().uuidString)
        let scope = fixture.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try Data("*\n!kept*/\n".utf8).write(to: scope.appendingPathComponent(".gitignore"))
        let folder = scope.appendingPathComponent("kept-offline")
        let file = scope.appendingPathComponent("kept-file")
        let db = try FileSearchIndex(url: fixture.appendingPathComponent("index.sqlite"))
        for (url, directory) in [(folder, true), (file, false)] {
            try db.put(.init(path: url.path, name: url.lastPathComponent, volume: "/", modified: 1,
                             directory: directory, symlink: false), root: scope.path, epoch: "saved")
        }
        var options = FileSearchOptions(roots: [scope.path]); options.ignorePatterns = []
        var locations = FileSearchLocation(options: options, automaticExclusions: [])
        XCTAssertTrue(locations.includesSavedResult(at: folder.path, directory: true))
        XCTAssertFalse(locations.includesSavedResult(at: folder.path, directory: false))
        let rows = try db.searchRanked("kept", options: options,
            pathAllowed: { locations.includesSavedResult(at: $0, directory: $1) }).map(\.file)
        XCTAssertEqual(rows.map(\.id), [folder.path])
        let saved = try XCTUnwrap(rows.first)
        XCTAssertTrue(saved.isDirectory, "Use the saved directory column before the publication recheck")
        XCTAssertTrue(locations.includesSavedResult(at: saved.id, directory: saved.isDirectory))
        XCTAssertTrue(saved.readingResourceMetadata().isDirectory, "Missing files must retain the saved directory bit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try db.stats().entries, 2)
    }

}
