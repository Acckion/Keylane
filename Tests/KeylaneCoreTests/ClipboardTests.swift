import XCTest
import SQLite3
@testable import KeylaneCore

final class ClipboardTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneClipboardTest-" + UUID().uuidString) }
    func testPersistenceExactDeduplicationAndStablePins() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        var first = ""; var second = ""
        do {
            let store = try ClipboardStore(directory: directory)
            first = try store.capture(.text("Code ABC\n中文"),at:now)
            second = try store.capture(.text("Code abc\n中文"),at:now.addingTimeInterval(1))
            XCTAssertNotEqual(first,second)
            try store.setPinned(id:first,pinned:true); try store.setPinned(id:second,pinned:true)
            XCTAssertEqual(try store.capture(.text("Code abc\n中文"),at:now.addingTimeInterval(2)),second)
            XCTAssertEqual(try store.list().map(\.id),[first,second])
            XCTAssertEqual(try store.count(),2)
        }
        let reopened = try ClipboardStore(directory: directory)
        XCTAssertEqual(try reopened.detail(id:second)?.item.copyCount,2)
        XCTAssertEqual(try reopened.detail(id:first)?.text,"Code ABC\n中文")
        XCTAssertTrue(try XCTUnwrap(reopened.detail(id:first)).item.pinned)
        let nul = try reopened.capture(.text("before\0after"))
        XCTAssertEqual(try reopened.detail(id:nul)?.text,"before\0after")
    }
    func testRenamePreservesContentAndRecentDeletionKeepsPinnedHistory() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(directory: directory)
        let now = Date()
        let old = try store.capture(.text("older original"), at: now.addingTimeInterval(-7200))
        let recent = try store.capture(.text("recent original"), at: now)
        let pinned = try store.capture(.text("pinned original"), at: now)
        try store.setPinned(id: pinned, pinned: true)
        try store.rename(id: recent, to: "Meeting Summary")
        XCTAssertEqual(try store.list(query: "meeting").map(\.id), [recent])
        XCTAssertEqual(try store.detail(id: recent)?.text, "recent original")

        try store.removeRecent(since: now.addingTimeInterval(-3600))

        XCTAssertEqual(Set(try store.list().map(\.id)), Set([old, pinned]))
    }

    func testUnicodeSubstringSearchAndLiteralSyntax() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store = try ClipboardStore(directory:directory)
        let id = try store.capture(.text("单车训练计划 'quote' 100% _under OR NOT"))
        XCTAssertEqual(try store.list(query:"车训练").map(\.id),[id])
        XCTAssertEqual(try store.list(query:"训练").map(\.id),[id])
        XCTAssertEqual(try store.list(query:"% _").map(\.id),[id])
        XCTAssertEqual(try store.list(query:"OR NOT").map(\.id),[id])
        XCTAssertTrue(try store.list(query:"\" OR *").isEmpty)
    }
    func testOCRPreservesRenamedImageInSearch() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(directory: directory)
        let id = try store.capture(.image(Data([137, 80, 78, 71])), source: "Image Source")
        try store.rename(id: id, to: "Résumé Reference")

        try store.setOCR(id: id, text: "Recognized invoice")

        XCTAssertEqual(try store.list(query: "resume").map(\.id), [id])
        XCTAssertEqual(try store.list(query: "invoice").map(\.id), [id])
        XCTAssertEqual(try store.list(query: "source").map(\.id), [id])
        XCTAssertEqual(try store.detail(id: id)?.item.preview, "Résumé Reference")
    }

    func testAttachmentsReferencesOCRAndDeletionRace() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store = try ClipboardStore(directory:directory)
        let image = try store.capture(.image(Data([137,80,78,71])))
        let asset = try XCTUnwrap(store.detail(id:image)?.assetURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath:asset.path))
        try store.setOCR(id:image,text:"图片里的单车训练方案")
        XCTAssertEqual(try store.list(query:"车训练").map(\.id),[image])
        let files = [ClipFile(path:"/missing/资料.txt",bookmark:Data([1,2]))]
        let file = try store.capture(.files(files))
        XCTAssertEqual(try store.detail(id:file)?.files,files)
        XCTAssertNil(store.assetURL("../../notes.sqlite"))
        try store.remove(id:image)
        XCTAssertFalse(FileManager.default.fileExists(atPath:asset.path))
        try store.setOCR(id:image,text:"late callback")
        XCTAssertNil(try store.detail(id:image))
        XCTAssertTrue(try store.list(query:"late callback").isEmpty)
    }
    func testRetentionCountBudgetAndPinnedExemption() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store = try ClipboardStore(directory:directory,limits:.init(maxItems:3,retentionDays:1,maxBytes:32))
        let now = Date()
        let pinned = try store.capture(.text("pinned"),at:now)
        try store.setPinned(id:pinned,pinned:true)
        _ = try store.capture(.text("old"),at:now)
        _ = try store.capture(.text("new"),at:now.addingTimeInterval(2*86400))
        XCTAssertNotNil(try store.detail(id:pinned))
        XCTAssertEqual(try store.count(),2)
        try store.clear(includePinned:false)
        XCTAssertEqual(try store.list().map(\.id),[pinned])
        try store.clear(includePinned:true)
        XCTAssertEqual(try store.count(),0)
        XCTAssertThrowsError(try store.capture(.text(String(repeating:"x",count:1_048_577))))
    }
    func testCountAndByteBudgetActuallyEvictOnlyUnpinnedRecords() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(directory: directory, limits: .init(maxItems: 2, maxBytes: 20))
        let now = Date()
        let pinned = try store.capture(.text("pinned"), at: now)
        try store.setPinned(id: pinned, pinned: true)
        let old = try store.capture(.text("old"), at: now.addingTimeInterval(1))
        let latest = try store.capture(.text("latest"), at: now.addingTimeInterval(2))
        XCTAssertNil(try store.detail(id: old))
        XCTAssertEqual(Set(try store.list().map(\.id)), Set([pinned, latest]))
        store.limits = .init(maxItems: 20, maxBytes: 8)
        try store.prune(now: now)
        XCTAssertEqual(try store.list().map(\.id), [pinned])
        XCTAssertThrowsError(try store.capture(.text("unretainable"), at: now))
        XCTAssertNotNil(try store.detail(id: pinned))
    }
    func testFutureDatabaseIsRejectedWithoutDowngrading() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at: directory) }
        do { let store = try ClipboardStore(directory: directory); _ = try store.capture(.text("preserve")) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite").path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertThrowsError(try ClipboardStore(directory: directory))
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite").path, &db), SQLITE_OK)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 99)
        sqlite3_finalize(statement); sqlite3_close(db)
    }
    func testRichSnapshotDeduplicationAndRestart() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let plain = ClipSnapshot(items:[ClipSnapshotItem([.init(type:"public.utf8-plain-text",data:Data("same".utf8))])],plainText:"same")
        let rich = ClipSnapshot(items:[ClipSnapshotItem([.init(type:"public.utf8-plain-text",data:Data("same".utf8)),.init(type:"public.rtf",data:Data("{\\rtf1 same}".utf8))])],plainText:"same")
        var id = ""
        do {
            let store = try ClipboardStore(directory:directory)
            let legacy = try store.capture(.text("same"))
            XCTAssertEqual(try store.capture(.text("same"),snapshot:plain),legacy)
            id = try store.capture(.text("same"),snapshot:rich)
            XCTAssertNotEqual(id,legacy)
            try store.setPinned(id:id,pinned:true)
            XCTAssertEqual(try store.capture(.text("same"),snapshot:rich),id)
            XCTAssertEqual(try store.count(),2)
        }
        let reopened = try ClipboardStore(directory:directory)
        XCTAssertEqual(try reopened.detail(id:id)?.snapshot,rich)
        XCTAssertTrue(try XCTUnwrap(reopened.detail(id:id)).item.pinned)
        XCTAssertEqual(try reopened.detail(id:id)?.item.copyCount,2)
        try reopened.remove(id:id)
        XCTAssertNil(try reopened.detail(id:id))
    }
    func testEarlyVersionTwoSnapshotSchemaCanCaptureAfterUpgrade() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let snapshot = ClipSnapshot(items:[.init([.init(type:"public.utf8-plain-text",data:Data("preserve old snapshot".utf8))])],plainText:"preserve old snapshot")
        var id = ""
        do { let store = try ClipboardStore(directory:directory); id = try store.capture(.text(snapshot.plainText),snapshot:snapshot); try store.setPinned(id:id,pinned:true) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite").path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"ALTER TABLE clip_snapshots DROP COLUMN search_text; PRAGMA user_version=2",nil,nil,nil),SQLITE_OK); sqlite3_close(db)
        let upgraded = try ClipboardStore(directory:directory)
        XCTAssertEqual(try upgraded.detail(id:id)?.snapshot,snapshot)
        XCTAssertTrue(try XCTUnwrap(upgraded.detail(id:id)).item.pinned)
        let added = try upgraded.capture(.text("new capture"),snapshot:.init(items:[.init([.init(type:"public.utf8-plain-text",data:Data("new capture".utf8))])],plainText:"new capture"))
        XCTAssertEqual(try upgraded.detail(id:added)?.text,"new capture")
        XCTAssertEqual(try upgraded.migrationBackups().count,1)
        XCTAssertTrue(try XCTUnwrap(upgraded.lastMigrationBackupURL).lastPathComponent.hasPrefix("v2-"))
        do { let reopened = try ClipboardStore(directory:directory); XCTAssertEqual(try reopened.count(),2); XCTAssertNil(reopened.lastMigrationBackupURL) }
    }
    func testVersionOneMigrationBacksUpDatabaseAndOwnedImages() throws {
        let directory = directory(); defer { try? FileManager.default.removeItem(at:directory) }
        var image = ""
        do { let store = try ClipboardStore(directory:directory); image = try store.capture(.image(Data([137,80,78,71]))); _ = try store.capture(.text("preserved legacy")) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("clipboard.sqlite").path,&db),SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db,"DROP TABLE clip_snapshots; PRAGMA user_version=1",nil,nil,nil),SQLITE_OK); sqlite3_close(db)
        let migrated = try ClipboardStore(directory:directory)
        XCTAssertEqual(try migrated.count(),2)
        let backup = try XCTUnwrap(migrated.lastMigrationBackupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.appendingPathComponent("complete.txt").path))
        let assetName = try XCTUnwrap(migrated.detail(id:image)?.item.assetName)
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.appendingPathComponent("images/"+assetName).path))
        XCTAssertEqual(sqlite3_open(backup.appendingPathComponent("clipboard.sqlite").path,&db),SQLITE_OK)
        var q: OpaquePointer?; sqlite3_prepare_v2(db,"PRAGMA user_version",-1,&q,nil); XCTAssertEqual(sqlite3_step(q),SQLITE_ROW); XCTAssertEqual(sqlite3_column_int(q,0),1); sqlite3_finalize(q); sqlite3_close(db)
        let snapshot = ClipSnapshot(items:[.init([.init(type:"public.utf8-plain-text",data:Data("new".utf8))])],plainText:"new")
        let fresh = try migrated.capture(.text("new"),snapshot:snapshot)
        XCTAssertEqual(try migrated.detail(id:fresh)?.snapshot,snapshot)
        XCTAssertEqual(try migrated.migrationBackups().count,1)
        try migrated.removeMigrationBackups()
        XCTAssertTrue(try migrated.migrationBackups().isEmpty)
        XCTAssertNotNil(try migrated.detail(id:image))
    }
    func testSnapshotRejectsPrivateTypesAndMultiwordSearchFindsContent() throws {
        let bad = ClipSnapshot(items:[.init([.init(type:"private.auth.token",data:Data([1]))])])
        XCTAssertThrowsError(try bad.encoded())
        let directory = directory(); defer { try? FileManager.default.removeItem(at:directory) }
        let store = try ClipboardStore(directory:directory)
        let snapshot = ClipSnapshot(items:[.init([.init(type:"public.utf8-plain-text",data:Data("中文 训练 计划".utf8))])],plainText:"中文 训练 计划")
        let id = try store.capture(.image(Data([1,2,3])),snapshot:snapshot,source:"FixtureApp")
        try store.setOCR(id:id,text:"图片识别")
        XCTAssertEqual(try store.list(query:"训练 中文").map(\.id),[id])
        XCTAssertEqual(try store.list(query:"FixtureApp 图片").map(\.id),[id])
        try store.setOCR(id:id,text:"updated OCR")
        XCTAssertTrue(try store.list(query:"图片识别").isEmpty)
        XCTAssertEqual(try store.list(query:"updated 训练").map(\.id),[id])
    }
    func testSensitiveTransientReplayAndAppExclusions() {
        XCTAssertTrue(ClipboardPolicy.shouldSkip(types:["org.nspasteboard.ConcealedType"],source:nil,frontmost:nil,excluded:[]))
        XCTAssertTrue(ClipboardPolicy.shouldSkip(types:["org.keylane.clipboard.replay"],source:nil,frontmost:nil,excluded:[]))
        XCTAssertTrue(ClipboardPolicy.shouldSkip(types:[],source:"COM.BITWARDEN.DESKTOP",frontmost:nil,excluded:ClipboardPolicy.defaultExcluded))
        XCTAssertTrue(ClipboardPolicy.shouldSkip(types:[],source:nil,frontmost:"com.example.secret",excluded:["com.example.secret"]))
        XCTAssertFalse(ClipboardPolicy.shouldSkip(types:["public.utf8-plain-text"],source:nil,frontmost:"com.apple.TextEdit",excluded:[]))
    }
}
