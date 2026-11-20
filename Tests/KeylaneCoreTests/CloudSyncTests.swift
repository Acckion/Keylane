import XCTest
import SQLite3
@testable import KeylaneCore

final class CloudSyncTests: XCTestCase {
    final class Module: SyncParticipant {
        let category: SyncCategory
        var values: [String: Data] = [:]
        var deleted = Set<String>()
        var infer = true
        var fail = false
        var editAtAdmission: Data?
        init(_ category: SyncCategory = .snippets) { self.category = category }
        func snapshot() throws -> SyncLocalSnapshot { .init(values: values, deletions: deleted, inferDeletions: infer) }
        func apply(id: String, data: Data?) throws { if fail { throw SyncError.unavailable }; values[id] = data }
        func applyIfUnchanged(id: String, data: Data?, fingerprint expected: String?) throws -> String? {
            if let editAtAdmission { values[id] = editAtAdmission; self.editAtAdmission = nil; throw SyncError.cancelled }
            guard try fingerprint(id: id) == expected else { throw SyncError.cancelled }
            try apply(id: id, data: data); return try fingerprint(id: id)
        }
    }
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keylane-sync-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func run(_ module: Module, _ local: URL, _ transport: SyncDriveTransport) throws {
        _ = try SyncEngine.run(local: local, transport: transport, participants: [module], name: "Test Mac")
    }
    func testTwoDevicesMergeAdditionsEditsAndExplicitDeletesWithoutEcho() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(), b = Module(), la = base.appendingPathComponent("A"), lb = base.appendingPathComponent("B")
        a.values["a"] = Data("first".utf8); b.values["b"] = Data("second".utf8)
        try run(a, la, transport); try run(b, lb, transport); try run(a, la, transport)
        XCTAssertEqual(a.values, b.values)
        b.values["a"] = Data("edited".utf8); try run(b, lb, transport); try run(a, la, transport)
        XCTAssertEqual(a.values["a"], Data("edited".utf8))
        a.values["b"] = nil; try run(a, la, transport); try run(b, lb, transport)
        XCTAssertNil(b.values["b"])
        let before = try Data(contentsOf: la.appendingPathComponent("journal.json"))
        try run(a, la, transport)
        XCTAssertEqual(before, try Data(contentsOf: la.appendingPathComponent("journal.json")))
    }
    func testNewDeviceRestoresCloudEntityAndKeepsItsLocalConflictBackup() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(), b = Module(), la = base.appendingPathComponent("A"), lb = base.appendingPathComponent("B")
        a.values["appearance"] = Data("cloud-choice".utf8)
        b.values["appearance"] = Data("fresh-device-default".utf8)
        a.values["navigation"] = a.values["appearance"]
        b.values["navigation"] = b.values["appearance"]
        try run(a, la, transport); try run(b, lb, transport)
        XCTAssertEqual(b.values, a.values)
        let backups = try FileManager.default.contentsOfDirectory(at: lb.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)
        let identities = try backups.map { url -> String in
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            return try XCTUnwrap(document["id"] as? String)
        }
        XCTAssertEqual(Set(identities), ["appearance", "navigation"])
    }
    func testClipboardExpiryIsLocalButManualDeletionPropagates() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(.clipboard), b = Module(.clipboard), la = base.appendingPathComponent("A"), lb = base.appendingPathComponent("B")
        a.infer = false; b.infer = false; a.values["clip"] = Data("history".utf8)
        try run(a, la, transport); try run(b, lb, transport)
        a.values["clip"] = nil; try run(a, la, transport); try run(b, lb, transport)
        XCTAssertNotNil(b.values["clip"]); XCTAssertNil(a.values["clip"])
        b.values["clip"] = nil; b.deleted.insert("clip")
        try run(b, lb, transport); try run(a, la, transport)
        XCTAssertNil(a.values["clip"])
        XCTAssertTrue(try transport.manifests().flatMap(\.entries).contains { $0.id == "clip" && $0.digest == nil })
    }
    func testFailedApplyRetainsDurableIntentAndRetries() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(), b = Module(), la = base.appendingPathComponent("A"), lb = base.appendingPathComponent("B")
        a.values["a"] = Data("retained".utf8); try run(a, la, transport)
        b.fail = true; XCTAssertThrowsError(try run(b, lb, transport))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: lb.appendingPathComponent("Intents").path)).contains { $0.hasPrefix("snippets-") })
        b.fail = false; try run(b, lb, transport)
        XCTAssertEqual(b.values, a.values)
        XCTAssertFalse((try FileManager.default.contentsOfDirectory(atPath: lb.appendingPathComponent("Intents").path)).contains { $0.hasPrefix("snippets-") })
    }
    func testUserEditWhileFailedIntentWaitsIsNotDiscarded() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(), b = Module(), la = base.appendingPathComponent("A"), lb = base.appendingPathComponent("B")
        a.values["a"] = Data("cloud".utf8); try run(a, la, transport)
        b.fail = true; XCTAssertThrowsError(try run(b, lb, transport))
        b.values["a"] = Data("new-local-edit".utf8); b.fail = false
        try run(b, lb, transport); try run(a, la, transport)
        XCTAssertEqual(a.values["a"], Data("new-local-edit".utf8))
        XCTAssertEqual(a.values, b.values)
    }
    func testLocalEditAtTheWriteBoundaryIsNotOverwrittenOrReplayedOnRetry() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(), b = Module(), la = base.appendingPathComponent("A"), lb = base.appendingPathComponent("B")
        a.values["a"] = Data("cloud".utf8); b.values["a"] = Data("old-local".utf8)
        try run(a, la, transport)
        b.editAtAdmission = Data("just-saved-local".utf8)
        XCTAssertThrowsError(try run(b, lb, transport))
        XCTAssertEqual(b.values["a"], Data("just-saved-local".utf8))
        try run(b, lb, transport); try run(a, la, transport)
        XCTAssertEqual(a.values["a"], Data("just-saved-local".utf8))
    }
    func testCrashAfterApplyAcknowledgesImportInsteadOfReuploadingIt() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(), b = Module(), la = base.appendingPathComponent("A"), lb = base.appendingPathComponent("B")
        a.values["a"] = Data("durable".utf8); try run(a, la, transport)
        b.fail = true; XCTAssertThrowsError(try run(b, lb, transport))
        b.fail = false; b.values = a.values // Simulate the module commit preceding a process crash.
        try run(b, lb, transport)
        let entries = try transport.manifests().flatMap(\.entries).filter { $0.id == "a" }
        XCTAssertEqual(Set(entries.map { $0.stamp.counter }).count, 1)
    }
    func testDisabledParticipantDoesNotGetReadOrApplied() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(.clipboard); a.values["private"] = Data("kept".utf8)
        try run(a, base.appendingPathComponent("A"), transport)
        let result = try SyncEngine.run(local: base.appendingPathComponent("B"), transport: transport, participants: [], name: "B")
        XCTAssertTrue(result.1.isEmpty); XCTAssertTrue(result.2.isEmpty)
    }
    func testPausingCategoryKeepsCloudContentAvailableForANewDevice() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(.clipboard), b = Module(.clipboard), local = base.appendingPathComponent("A")
        a.values["clip"] = Data("published-history".utf8); try run(a, local, transport)
        _ = try SyncEngine.run(local: local, transport: transport, participants: [], name: "A")
        try run(b, base.appendingPathComponent("B"), transport)
        XCTAssertEqual(b.values["clip"], Data("published-history".utf8))
    }
    func testPausedCategoryDoesNotPublishAnInterruptedPassUnsentEdit() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(.clipboard), b = Module(.clipboard), local = base.appendingPathComponent("A")
        a.values["clip"] = Data("published".utf8); try run(a, local, transport)
        let checkpoint = local.appendingPathComponent("journal.json")
        var journal = try JSONDecoder().decode(SyncJournal.self, from: Data(contentsOf: checkpoint))
        try journal.observe(category: .clipboard, values: ["clip": Data("not-published".utf8)])
        try SyncHash.encode(journal).write(to: checkpoint, options: .atomic)
        _ = try SyncEngine.run(local: local, transport: transport, participants: [], name: "A")
        try run(b, base.appendingPathComponent("B"), transport)
        XCTAssertEqual(b.values["clip"], Data("published".utf8))
    }
    func testCancellationDoesNotPublishOrChangeModule() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud")), module = Module()
        module.values["a"] = Data("unchanged".utf8)
        XCTAssertThrowsError(try SyncEngine.run(local: base.appendingPathComponent("A"), transport: transport, participants: [module], name: "A", allowed: { false }))
        XCTAssertTrue(try transport.manifests().isEmpty)
    }
    func testIdleSyncDoesNotRewriteItsManifestAndRetriggerTheWatcher() throws {
        let base = try temp(), cloud = base.appendingPathComponent("cloud"), transport = try SyncDriveTransport(directory: cloud)
        let module = Module(), local = base.appendingPathComponent("local")
        module.values["a"] = Data("stable".utf8); try run(module, local, transport)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: cloud.appendingPathComponent("devices"), includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: file)
        for _ in 0..<3 { try run(module, local, transport) }
        XCTAssertEqual(data, try Data(contentsOf: file))
    }
    func testTamperedObjectAndSymlinkAreRejected() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base)
        let hash = try transport.store(Data("original".utf8))
        try Data("modified".utf8).write(to: base.appendingPathComponent("objects/" + hash))
        XCTAssertThrowsError(try transport.load(hash))
        let external = try temp().appendingPathComponent("outside")
        try Data("outside".utf8).write(to: external)
        let bad = String(repeating: "a", count: 64)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("objects/" + bad), withDestinationURL: external)
        XCTAssertThrowsError(try transport.load(bad))
        XCTAssertThrowsError(try transport.load("../../outside"))
    }
    func testMetadataDiscoveryCannotReadOutsideTheSelectedDevicesDirectory() throws {
        let root = try temp(), outside = try temp().appendingPathComponent(UUID().uuidString + ".json")
        try Data("not a manifest".utf8).write(to: outside)
        let transport = try SyncDriveTransport(directory: root, discoveredManifests: [outside])
        XCTAssertTrue(try transport.manifests().isEmpty)
    }
    func testDanglingCloudObjectLinkCannotCreateAnExternalFile() throws {
        let root = try temp(), external = try temp().appendingPathComponent("must-not-create")
        let transport = try SyncDriveTransport(directory: root), data = Data("owned synthetic payload".utf8)
        let hash = SyncHash.digest(data)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("objects/" + hash), withDestinationURL: external)
        XCTAssertThrowsError(try transport.store(data))
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
    }
    func testOfflineConflictsHaveDeterministicWinnerAndRecoveryCopy() throws {
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud"))
        let a = Module(), b = Module(), la = base.appendingPathComponent("A"), lb = base.appendingPathComponent("B")
        a.values["id"] = Data("original".utf8); try run(a, la, transport); try run(b, lb, transport)
        a.values["id"] = Data("edit-A".utf8); b.values["id"] = Data("edit-B".utf8)
        try run(a, la, transport); try run(b, lb, transport); try run(a, la, transport); try run(b, lb, transport)
        XCTAssertEqual(a.values, b.values)
        let recovery = [la, lb].flatMap { (try? FileManager.default.contentsOfDirectory(at: $0.appendingPathComponent("Recovery"), includingPropertiesForKeys: nil)) ?? [] }
        XCTAssertFalse(recovery.isEmpty)
    }
    func testRichClipboardImageAndFileReferencesRoundTripWithoutBookmarks() throws {
        let base = try temp(), a = try ClipboardStore(directory: base.appendingPathComponent("A")), b = try ClipboardStore(directory: base.appendingPathComponent("B"))
        let snapshot = ClipSnapshot(items: [.init([.init(type: "public.utf8-plain-text", data: Data("hello".utf8)), .init(type: "public.html", data: Data("<b>hello</b>".utf8))])], plainText: "hello")
        let id = try a.capture(.text("hello"), snapshot: snapshot)
        let image = try a.capture(.image(Data([1,2,3,4]), format: .png))
        let file = try a.capture(.files([ClipFile(path: "/tmp/example", bookmark: Data([99]))]))
        let values = try a.syncSnapshot().values
        for (key, data) in values { try b.applySync(id: key, data: data) }
        XCTAssertEqual(try b.detail(id: id)?.snapshot, snapshot)
        XCTAssertEqual(try b.detail(id: image)?.assetURL.map { try Data(contentsOf: $0) }, Data([1,2,3,4]))
        XCTAssertNil(try b.detail(id: file)?.files.first?.bookmark)
        XCTAssertEqual(try b.detail(id: file)?.files.first?.path, "/tmp/example")
        try a.remove(id: id); XCTAssertTrue(try a.syncDeletions().contains(id))
        try a.prune(now: Date().addingTimeInterval(86400 * 60))
        XCTAssertFalse(try a.syncDeletions().contains(image))
    }
    func testHistorySyncIncludesMoreThanTheVisibleListLimit() throws {
        let base = try temp(), store = try ClipboardStore(directory: base, limits: .init(maxItems: 700))
        for index in 0..<520 { _ = try store.capture(.text("clip-\(index)")) }
        XCTAssertEqual(try store.list(limit: 5000).count, 500)
        XCTAssertEqual(try store.syncSnapshot().payloads.count, 520)
    }
    func testUnchangedLazyPayloadIsNotReadAgainDuringIdleSync() throws {
        final class Lazy: SyncParticipant {
            let category = SyncCategory.clipboard
            var reads = 0
            func snapshot() throws -> SyncLocalSnapshot {
                .init(payloads: ["image": SyncPayload(fingerprint: "stable-image-metadata") { [self] in
                    reads += 1; return Data(repeating: 7, count: 2 * 1024 * 1024)
                }], inferDeletions: false)
            }
            func apply(id: String, data: Data?) throws { XCTFail("No remote edits expected") }
        }
        let base = try temp(), transport = try SyncDriveTransport(directory: base.appendingPathComponent("cloud")), module = Lazy()
        let local = base.appendingPathComponent("local")
        _ = try SyncEngine.run(local: local, transport: transport, participants: [module], name: "A")
        XCTAssertEqual(module.reads, 1)
        for _ in 0..<3 { _ = try SyncEngine.run(local: local, transport: transport, participants: [module], name: "A") }
        XCTAssertEqual(module.reads, 1)
    }
    func testOldPinnedClipboardSurvivesImportRetention() throws {
        let base = try temp(), a = try ClipboardStore(directory: base.appendingPathComponent("A"), limits: .init(retentionDays: 0))
        let b = try ClipboardStore(directory: base.appendingPathComponent("B"), limits: .init(retentionDays: 1))
        let id = try a.capture(.text("pinned-old"), at: Date().addingTimeInterval(-86400 * 60))
        try a.setPinned(id: id, pinned: true)
        try b.applySync(id: id, data: XCTUnwrap(a.syncValue(id: id)))
        XCTAssertTrue(try XCTUnwrap(b.detail(id: id)).item.pinned)
    }
    func testImportCannotBypassThePinnedHistoryLimit() throws {
        let base = try temp(), a = try ClipboardStore(directory: base.appendingPathComponent("A")), b = try ClipboardStore(directory: base.appendingPathComponent("B"))
        for index in 0..<100 { let id = try b.capture(.text("pinned-\(index)")); try b.setPinned(id: id, pinned: true) }
        let id = try a.capture(.text("remote-pin")); try a.setPinned(id: id, pinned: true)
        XCTAssertThrowsError(try b.applySync(id: id, data: XCTUnwrap(a.syncValue(id: id))))
        XCTAssertEqual(try b.list(pinnedOnly: true).count, 100)
        XCTAssertNil(try b.detail(id: id))
    }
    func testRenamedHistoryAndEditedTextKeepTheirSyncSemantics() throws {
        let base = try temp(), a = try ClipboardStore(directory: base.appendingPathComponent("A")), b = try ClipboardStore(directory: base.appendingPathComponent("B"))
        let old = try a.capture(.text("old text"))
        let updated = try a.replaceText(id: old, with: "new text")
        XCTAssertTrue(try a.syncDeletions().contains(old))
        try a.rename(id: updated, to: "Custom title")
        try b.applySync(id: updated, data: XCTUnwrap(a.syncValue(id: updated)))
        XCTAssertEqual(try b.detail(id: updated)?.item.preview, "Custom title")
        XCTAssertEqual(try b.list(query: "Custom").first?.id, updated)
        XCTAssertEqual(try b.detail(id: updated)?.text, "new text")
    }
    func testFailedClipboardDeletionCannotCreateASyncTombstone() throws {
        let root = try temp(), store = try ClipboardStore(directory: root)
        let id = try store.capture(.text("must survive failed deletion"))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("clipboard.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER deny_sync_test_delete BEFORE DELETE ON clips BEGIN SELECT RAISE(ABORT,'synthetic'); END", nil, nil, nil), SQLITE_OK)
        XCTAssertThrowsError(try store.remove(id: id))
        XCTAssertThrowsError(try store.clear(includePinned: true))
        XCTAssertFalse(try store.syncDeletions().contains(id))
        XCTAssertNotNil(try store.detail(id: id))
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER deny_sync_test_delete", nil, nil, nil), SQLITE_OK)
        try store.prune(now: Date().addingTimeInterval(86400 * 60))
        XCTAssertFalse(try store.syncDeletions().contains(id))
    }
    func testInvalidClipboardIdentityDoesNotAlterExistingHistory() throws {
        let base = try temp(), store = try ClipboardStore(directory: base)
        let id = try store.capture(.text("original")); let data = try XCTUnwrap(store.syncSnapshot().values[id])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); json["text"] = "modified"
        XCTAssertThrowsError(try store.applySync(id: id, data: JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(try store.detail(id: id)?.text, "original")
        XCTAssertEqual(try store.list().count, 1)
    }
}
