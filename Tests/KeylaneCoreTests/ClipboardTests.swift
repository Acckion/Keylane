import XCTest
import SQLite3
@testable import KeylaneCore

final class ClipboardTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneClipboardTest-" + UUID().uuidString) }

    func testImageFileOCRSearchPreservesPathsAndInvalidatesStaleResults() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(directory: directory)
        let file = ClipFile(path: "/fixtures/clipboard-photo.png")
        let first = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let next = first.addingTimeInterval(1)
        let id = try store.capture(.files([file]), at: first)
        let multiple = try store.capture(.files([file, .init(path: "/fixtures/other.png")]), at: first)
        XCTAssertEqual(try store.pendingOCR().map(\.id), [id])
        XCTAssertEqual(try store.pendingOCR().first?.filePath, file.path)
        XCTAssertFalse(try store.setOCR(id: multiple, text: "不应加入索引", fileCopiedAt: first))
        XCTAssertTrue(try store.setOCR(id: id, text: "图 片\n文字", fileCopiedAt: first))
        XCTAssertEqual(try store.list(query: "图片文字", category: .files).map(\.id), [id])
        XCTAssertTrue(try store.list(query: "图片文字", category: .image).isEmpty)
        XCTAssertTrue(try store.pendingOCR().isEmpty)
        try store.rename(id: id, to: "自定义名称")
        XCTAssertEqual(try store.list(query: "clipboard-photo 图片文字").map(\.id), [id])

        XCTAssertEqual(try store.capture(.files([file]), at: next), id)
        XCTAssertFalse(try store.setOCR(id: id, text: "旧图片正文", fileCopiedAt: first))
        XCTAssertTrue(try store.list(query: "图片文字").isEmpty)
        XCTAssertEqual(try store.pendingOCR().map(\.id), [id])
        XCTAssertTrue(try store.setOCR(id: id, text: "新版图片正文", fileCopiedAt: next))
        XCTAssertEqual(try store.list(query: "新版图片正文").map(\.id), [id])
    }

    func testLinkMetadataKeepsOriginalURLAndCopyDatesAfterRename() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "https://example.com/folder/page?tag=clipboard#section"
        let first = Date()
        let last = first.addingTimeInterval(30)
        let store = try ClipboardStore(directory: directory)
        let id = try store.capture(.text(original), at: first)
        XCTAssertEqual(try store.capture(.text(original), at: last), id)
        try store.rename(id: id, to: "示例网页")

        let reopened = try ClipboardStore(directory: directory)
        let item = try XCTUnwrap(reopened.list(category: .link).first)
        XCTAssertEqual(item.preview, "示例网页")
        XCTAssertEqual(item.webURL?.absoluteString, original)
        XCTAssertEqual(item.firstCopiedAt.timeIntervalSince(first), 0, accuracy: 0.000001)
        XCTAssertEqual(item.copiedAt.timeIntervalSince(last), 0, accuracy: 0.000001)
        XCTAssertEqual(item.copyCount, 2)
        XCTAssertEqual(try reopened.detail(id: id)?.item, item)
        XCTAssertEqual(try reopened.detail(id: id)?.text, original)
    }

    func testEditingPreservesMetadataAndReplacesSearchAndReplayContent() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(directory: directory)
        let snapshot = ClipSnapshot(items: [.init([
            .init(type: "public.utf8-plain-text", data: Data("old text".utf8)),
            .init(type: "public.html", data: Data("<b>old text</b>".utf8))
        ])], plainText: "old text")
        let original = try store.capture(.text("old text"), snapshot: snapshot, source: "Fixture")
        try store.rename(id: original, to: "Custom title")
        try store.setPinned(id: original, pinned: true)
        let edited = try store.replaceText(id: original, with: "#0c4cdd")
        XCTAssertNil(try store.detail(id: original))
        XCTAssertTrue(try store.list(query: "old text").isEmpty)
        XCTAssertEqual(try store.list(query: "0c4cdd", category: .color).map(\.id), [edited])
        let detail = try XCTUnwrap(store.detail(id: edited))
        XCTAssertEqual(detail.text, "#0c4cdd")
        XCTAssertNil(detail.snapshot)
        XCTAssertTrue(detail.item.pinned)
        XCTAssertEqual(detail.item.source, "Fixture")
        XCTAssertEqual(detail.item.preview, "Custom title")
        XCTAssertEqual(try store.capture(.text("#0c4cdd")), edited)
        XCTAssertEqual(try store.count(), 1)
    }

    func testEditingCannotOverwriteAnotherEntry() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(directory: directory)
        let original = try store.capture(.text("a@example.com"))
        let existing = try store.capture(.text("https://example.com"))
        XCTAssertThrowsError(try store.replaceText(id: original, with: "https://example.com")) {
            XCTAssertEqual($0 as? ClipboardError, .duplicateText)
        }
        XCTAssertEqual(try store.list(category: .email).map(\.id), [original])
        XCTAssertEqual(try store.list(category: .link).map(\.id), [existing])
    }

    func testColorFormatsAndAlpha() throws {
        let color = try XCTUnwrap(ClipboardColor(" #0c4cdd\n"))
        XCTAssertEqual(color.hexLabel, "#0C4CDD")
        XCTAssertEqual(color.formatted(as: .hexAlpha), "#0C4CDDFF")
        XCTAssertEqual(color.formatted(as: .rgba), "rgba(12, 76, 221, 1)")
        XCTAssertEqual(color.formatted(as: .rgbaPercent), "rgba(4.71%, 29.8%, 86.67%, 1)")
        XCTAssertEqual(color.formatted(as: .cssRGB), "rgb(12 76 221)")
        XCTAssertEqual(color.formatted(as: .hsl), "hsl(221.63deg 89.7% 45.69%)")

        let translucent = try XCTUnwrap(ClipboardColor("hsl(-.5turn 100% 50% / 50%)"))
        XCTAssertEqual(translucent.hexLabel, "#00FFFF80")
        XCTAssertEqual(translucent.formatted(as: .cssRGB), "rgb(0 255 255 / 0.5)")
        XCTAssertEqual(translucent.formatted(as: .hsl), "hsl(180deg 100% 50% / 0.5)")
        XCTAssertEqual(ClipboardColor("#0f88")?.hexLabel, "#00FF8888")
        XCTAssertEqual(ClipboardColor("rgba(100%, 0%, 100%, 0.25)")?.hexLabel, "#FF00FF40")
        for format in ClipboardColor.Format.allCases {
            let roundTrip = try XCTUnwrap(ClipboardColor(color.formatted(as: format)))
            XCTAssertEqual(roundTrip.hexLabel, color.hexLabel, format.rawValue)
        }
        for invalid in ["#0C4CDD title", "#-11", "# 11", "#12345", "rgb(1 2 3 /)", "rgb(300,0,0)",
                        "hsl(nan 50% 50%)", "rgba(1,2,3,1.5)", "rgb(1,,3)", "#fff\0text", "#fff\n#aaa"] {
            XCTAssertNil(ClipboardColor(invalid), invalid)
        }
    }

    func testSemanticFiltersUseOriginalContentBeforeLimit() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = " #0c4cdd "
        let snapshot = ClipSnapshot(items: [.init([
            .init(type: "public.utf8-plain-text", data: Data(original.utf8))
        ])], plainText: original)
        let store = try ClipboardStore(directory: directory)
        let now = Date()
        let color = try store.capture(.text(original), snapshot: snapshot, at: now.addingTimeInterval(-60))
        try store.rename(id: color, to: "品牌蓝")
        let link = try store.capture(.text("https://example.com/colors?q=%23fff"))
        let email = try store.capture(.text("design+test@example.com"))
        let plain = try store.capture(.text("颜色 #0c4cdd"))
        let long = try store.capture(.text("#fff" + String(repeating: "a", count: 5000)))
        let image = try store.capture(.image(Data([137, 80, 78, 71])))
        let files = try store.capture(.files([.init(path: "/tmp/#0C4CDD")]))

        let reopened = try ClipboardStore(directory: directory)
        XCTAssertEqual(try reopened.list(category: .color, limit: 1).map(\.id), [color])
        XCTAssertEqual(try reopened.list(query: "0c4cdd", category: .color).first?.preview, "品牌蓝")
        XCTAssertEqual(try reopened.list(category: .link).map(\.id), [link])
        XCTAssertEqual(try reopened.list(category: .email).map(\.id), [email])
        XCTAssertEqual(Set(try reopened.list(category: .text).map(\.id)), Set([plain, long]))
        XCTAssertEqual(try reopened.list(category: .image).map(\.id), [image])
        XCTAssertEqual(try reopened.list(category: .files).map(\.id), [files])
        XCTAssertEqual(try reopened.count(), 7)
        let detail = try XCTUnwrap(reopened.detail(id: color))
        XCTAssertEqual(detail.item.category, .color)
        XCTAssertEqual(detail.item.color?.hexLabel, "#0C4CDD")
        XCTAssertEqual(detail.text, original)
        XCTAssertEqual(detail.snapshot, snapshot)
        XCTAssertNil(reopened.lastMigrationBackupURL)
    }

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
    func testRecapturePreservesNormalizedTitleAndOCRSearch() throws {
        let directory = directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardStore(directory: directory)
        let content = ClipContent.image(Data([137, 80, 78, 71]))
        let id = try store.capture(content, source: "Original Source")
        try store.rename(id: id, to: "Résumé Reference")
        try store.setOCR(id: id, text: "Café Invoice")

        XCTAssertEqual(try store.capture(content, source: "Updated Source"), id)

        XCTAssertEqual(try store.list(query: "resume").map(\.id), [id])
        XCTAssertEqual(try store.list(query: "cafe").map(\.id), [id])
        XCTAssertEqual(try store.list(query: "updated").map(\.id), [id])
        XCTAssertTrue(try store.list(query: "original").isEmpty)
        let record = try XCTUnwrap(store.detail(id: id))
        XCTAssertEqual(record.item.preview, "Résumé Reference")
        XCTAssertEqual(record.item.copyCount, 2)
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
