import XCTest
@testable import KeylaneCore

final class RaycastMigrationTransactionTests: XCTestCase {
    private enum Interrupted: Error { case injected }
    private var root: URL!
    private var recovery: URL { root.appendingPathComponent("ConfigurationRecovery") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RaycastTransactionTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func finish(_ prefs: inout [String:Any]) throws -> Bool {
        var state = prefs
        let finished = try RaycastMigrationTransaction.finish(directory: recovery, root: root, read: { state }, persist: { state = $0; return true })
        prefs = state; return finished
    }
    func testSnapshotSQLiteKeepsFTSAndDetectsContentChanges() throws {
        let store = try Store(url: root.appendingPathComponent("data.sqlite"))
        try store.save(Record(id:"one",kind:"snippet",title:"Example",body:"Body"))
        let first = try RaycastMigrationTransaction.snapshot(.snippets,root:root)
        let second = try RaycastMigrationTransaction.snapshot(.snippets,root:root)
        XCTAssertEqual(try RaycastMigrationTransaction.fingerprint(first,id:.snippets), try RaycastMigrationTransaction.fingerprint(second,id:.snippets))
        try store.save(Record(id:"one",kind:"snippet",title:"Changed",body:"Body"))
        XCTAssertNotEqual(try RaycastMigrationTransaction.fingerprint(first,id:.snippets), try RaycastMigrationTransaction.fingerprint(try RaycastMigrationTransaction.snapshot(.snippets,root:root),id:.snippets))
    }
    func testReplayAndUndoRestoreMissingStoreAndPreferences() throws {
        var prefs:[String:Any] = ["other":"keep"]
        let resource = RaycastMigrationTransaction.Resource(id:.focus,before:nil,after:Data("new".utf8))
        try RaycastMigrationTransaction.stage(changes:["test":"new"],current:prefs,resources:[resource],directory:recovery)
        // A failure after writing stores retains the intent; replay is idempotent.
        XCTAssertThrowsError(try RaycastMigrationTransaction.finish(directory:recovery,root:root,read:{prefs},persist:{_ in false}))
        XCTAssertTrue(RaycastMigrationTransaction.hasPending(in:recovery))
        XCTAssertTrue(RaycastMigrationTransaction.hasStarted(in:recovery))
        XCTAssertThrowsError(try RaycastMigrationTransaction.cancel(directory:recovery,root:root,current:prefs))
        XCTAssertEqual(try RaycastMigrationTransaction.snapshot(.focus,root:root),Data("new".utf8))
        XCTAssertTrue(try finish(&prefs)); XCTAssertEqual(prefs["test"] as? String,"new")
        XCTAssertEqual(prefs["other"] as? String,"keep")
        try RaycastMigrationTransaction.stageUndo(directory:recovery,root:root,current:prefs)
        XCTAssertTrue(try finish(&prefs)); XCTAssertNil(prefs["test"])
        XCTAssertNil(try RaycastMigrationTransaction.snapshot(.focus,root:root))
    }
    func testExternalEditStopsBeforeFirstWriteAndCancelKeepsRecovery() throws {
        let resource = RaycastMigrationTransaction.Resource(id:.focus,before:nil,after:Data("new".utf8))
        var prefs:[String:Any] = [:]
        try RaycastMigrationTransaction.stage(changes:["test":"new"],current:prefs,resources:[resource],directory:recovery)
        let destination = root.appendingPathComponent("Focus/state.json")
        try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("external".utf8).write(to:destination)
        XCTAssertThrowsError(try finish(&prefs)); XCTAssertTrue(prefs.isEmpty)
        XCTAssertFalse(RaycastMigrationTransaction.hasStarted(in:recovery))
        try RaycastMigrationTransaction.cancel(directory:recovery,root:root,current:prefs)
        XCTAssertEqual(try Data(contentsOf:destination),Data("external".utf8))
        XCTAssertFalse(RaycastMigrationTransaction.hasPending(in:recovery))
    }
    func testCancelBeforeApplyAndMutuallyExclusiveJournals() throws {
        try RaycastMigrationTransaction.stage(changes:["a":1],current:[:],resources:[],directory:recovery)
        XCTAssertThrowsError(try ConfigurationTransaction.stage(changes:["b":2],current:[:],directory:recovery))
        try RaycastMigrationTransaction.cancel(directory:recovery,root:root,current:[:])
        XCTAssertFalse(RaycastMigrationTransaction.hasPending(in:recovery))
        try ConfigurationTransaction.stage(changes:["b":2],current:[:],directory:recovery)
        XCTAssertThrowsError(try RaycastMigrationTransaction.stage(changes:["a":1],current:[:],resources:[],directory:recovery))
    }
    func testFocusShutdownCheckpointsArePreservedAcrossImportAndUndo() throws {
        let url = root.appendingPathComponent("Focus/state.json")
        let store = FocusStore(url:url)
        let original = FocusArchive()
        try store.save(original)
        let before = try RaycastMigrationTransaction.snapshot(.focus,root:root)
        var imported = original; imported.categories = [.init(name:"Imported")]
        let resource = RaycastMigrationTransaction.Resource(id:.focus,before:before,after:try JSONEncoder().encode(imported))
        try RaycastMigrationTransaction.stage(changes:[:],current:[:],resources:[resource],directory:recovery)
        var shutdown = original; shutdown.checkpoint = Date(timeIntervalSince1970:100)
        try store.save(shutdown)
        var prefs:[String:Any] = [:]
        XCTAssertTrue(try finish(&prefs))
        var applied = try store.load()
        XCTAssertEqual(applied.categories.map(\.name),["Imported"])
        XCTAssertEqual(applied.checkpoint,shutdown.checkpoint)
        applied.checkpoint = Date(timeIntervalSince1970:200); try store.save(applied)
        try RaycastMigrationTransaction.stageUndo(directory:recovery,root:root,current:prefs)
        XCTAssertTrue(try finish(&prefs))
        let undone = try store.load()
        XCTAssertTrue(undone.categories.isEmpty)
        XCTAssertEqual(undone.checkpoint,applied.checkpoint)
    }
    func testDanglingSymlinkAndLinkedParentAreRejected() throws {
        let outside = root.appendingPathComponent("outside.sqlite")
        let destination = root.appendingPathComponent("data.sqlite")
        try FileManager.default.createSymbolicLink(at:destination,withDestinationURL:outside)
        XCTAssertThrowsError(try RaycastMigrationTransaction.snapshot(.snippets,root:root))
        try FileManager.default.removeItem(at:destination)
        let parent = root.appendingPathComponent("Clipboard")
        try FileManager.default.createSymbolicLink(at:parent,withDestinationURL:root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try RaycastMigrationTransaction.snapshot(.clipboard,root:root))
        XCTAssertFalse(FileManager.default.fileExists(atPath:outside.path))
    }
    func testSQLiteApplyAndUndoPreserveExistingRecords() throws {
        let url = root.appendingPathComponent("data.sqlite")
        var store: Store? = try Store(url:url)
        try store!.save(Record(id:"one",kind:"snippet",title:"Before",body:"Body"))
        let before = try RaycastMigrationTransaction.snapshot(.snippets,root:root)!
        try store!.save(Record(id:"two",kind:"snippet",title:"After",body:"Body"))
        let after = try RaycastMigrationTransaction.snapshot(.snippets,root:root)!
        store = nil
        // Restore a consistent baseline through the SQLite API, avoiding journal manipulation.
        let other = root.appendingPathComponent("prepared",isDirectory:true)
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        try before.write(to:other.appendingPathComponent("data.sqlite"))
        let owner = try Store(url: other.appendingPathComponent("data.sqlite"))
        let inode = try FileManager.default.attributesOfItem(atPath: other.appendingPathComponent("data.sqlite").path)[.systemFileNumber] as? NSNumber
        let transaction = other.appendingPathComponent("recovery")
        try RaycastMigrationTransaction.stage(changes:[:],current:[:],resources:[.init(id:.snippets,before:before,after:after)],directory:transaction)
        _ = try RaycastMigrationTransaction.finish(directory:transaction,root:other,read:{[:]},persist:{_ in true})
        XCTAssertEqual(try owner.records(kind:"snippet").count,2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: other.appendingPathComponent("data.sqlite").path)[.systemFileNumber] as? NSNumber, inode)
        try RaycastMigrationTransaction.stageUndo(directory:transaction,root:other,current:[:])
        _ = try RaycastMigrationTransaction.finish(directory:transaction,root:other,read:{[:]},persist:{_ in true})
        XCTAssertEqual(try owner.records(kind:"snippet").map(\.id),["one"])
    }

    func testNewSQLiteInterruptionLeavesOnlyMissingOrCompleteTargetAndCanReplay() throws {
        let source = root.appendingPathComponent("source")
        do {
            let store = try Store(url: source.appendingPathComponent("data.sqlite"))
            try store.save(Record(id:"one",kind:"snippet",title:"Synthetic",body:String(repeating:"text ",count:100_000)))
        }
        let payload = try XCTUnwrap(RaycastMigrationTransaction.snapshot(.snippets,root:source))
        for point in RaycastMigrationTransaction.InstallationEvent.allCases {
            let targetRoot = root.appendingPathComponent(point.rawValue)
            let directory = targetRoot.appendingPathComponent("recovery")
            let destination = targetRoot.appendingPathComponent("data.sqlite")
            var prefs: [String:Any] = [:]
            try RaycastMigrationTransaction.stage(changes:["imported":true], current:prefs,
                resources:[.init(id:.snippets,before:nil,after:payload)],directory:directory)
            XCTAssertThrowsError(try RaycastMigrationTransaction.finish(directory:directory,root:targetRoot,
                read:{prefs},persist:{prefs=$0;return true},installationObserver:{ event, _ in
                    if event == point { throw Interrupted.injected }
                }))
            XCTAssertTrue(RaycastMigrationTransaction.hasStarted(in:directory))
            XCTAssertTrue(prefs.isEmpty)
            if point == .published {
                XCTAssertEqual(try RaycastMigrationTransaction.fingerprint(RaycastMigrationTransaction.snapshot(.snippets,root:targetRoot),id:.snippets), try RaycastMigrationTransaction.fingerprint(payload,id:.snippets))
            } else { XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path)) }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:targetRoot.path).contains { $0.hasPrefix(".keylane-migration-") })
            XCTAssertTrue(try RaycastMigrationTransaction.finish(directory:directory,root:targetRoot,read:{prefs},persist:{prefs=$0;return true}))
            XCTAssertEqual(prefs["imported"] as? Bool,true)
            try RaycastMigrationTransaction.stageUndo(directory:directory,root:targetRoot,current:prefs)
            _ = try RaycastMigrationTransaction.finish(directory:directory,root:targetRoot,read:{prefs},persist:{prefs=$0;return true})
            XCTAssertFalse(FileManager.default.fileExists(atPath:destination.path))
        }
    }

    func testPublishingNewSQLiteDoesNotReplaceUnexpectedDestination() throws {
        let source = root.appendingPathComponent("source")
        do { let store = try Store(url:source.appendingPathComponent("data.sqlite")); try store.save(Record(id:"one",kind:"snippet",title:"Synthetic",body:"Text")) }
        let payload = try XCTUnwrap(RaycastMigrationTransaction.snapshot(.snippets,root:source))
        let destination = root.appendingPathComponent("data.sqlite")
        try RaycastMigrationTransaction.stage(changes:[:],current:[:],resources:[.init(id:.snippets,before:nil,after:payload)],directory:recovery)
        XCTAssertThrowsError(try RaycastMigrationTransaction.finish(directory:recovery,root:root,read:{[:]},persist:{_ in true},installationObserver:{ event, _ in
            if event == .verified { try Data("external".utf8).write(to:destination) }
        }))
        XCTAssertEqual(try Data(contentsOf:destination),Data("external".utf8))
        XCTAssertTrue(RaycastMigrationTransaction.hasPending(in:recovery))
    }
}
