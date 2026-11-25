import AppKit
import CoreServices
import KeylaneCore
import SQLite3
setbuf(stdout, nil)
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!)
let scope = base.appendingPathComponent("scope")
let store = base.appendingPathComponent("index")
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
try Data("seed".utf8).write(to: scope.appendingPathComponent("seed.txt"))
let suite = "org.keylane.burst-fixture." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path])
options.contentSearch = false; options.ignorePatterns = []
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let controller = FileSearchController(directory: store, preferences: prefs, startImmediately: false)
controller.testQuietIndexEventID = 100
// Hold only the batch clock still; a separate benchmark uses the production
// monotonic clock. The count regression must not depend on host scheduling.
controller.testLiveBatchClock = { 0 }
defer { controller.stopRuntime() }
var offered: [SpotlightFile] = []
controller.updated = { rows, _ in offered = rows }
func wait(_ label: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(20)
    while !condition(), Date() < end { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    precondition(condition(), label + ": " + controller.indexStatus)
}
controller.startRuntime()
controller.search("seed")
wait("warm baseline") { controller.testEventPipelineIdle && offered.count == 1 && controller.testFullIndexScans == 1 }
let ready = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
controller.testCheckpointBarrier = { _ in ready.signal(); _ = gate.wait(timeout: .now() + 25) }
controller.search("burst-fixture-")
controller.startIndex()
var held = false
wait("warm scan reached barrier") { if !held { held = ready.wait(timeout: .now()) == .success }; return held && controller.indexing }
let dbFile = store.appendingPathComponent("index.sqlite")
let wal = URL(fileURLWithPath: dbFile.path + "-wal")
func walBytes() -> UInt64 { ((try? FileManager.default.attributesOfItem(atPath: wal.path))?[.size] as? NSNumber)?.uint64Value ?? 0 }
var observer: OpaquePointer?
precondition(sqlite3_open_v2(dbFile.path, &observer, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
precondition(sqlite3_exec(observer, "BEGIN; SELECT count(*) FROM files", nil, nil, nil) == SQLITE_OK)
let n = 128
let items = (0..<n).map { scope.appendingPathComponent("burst-fixture-\($0).txt") }
for item in items { try Data().write(to: item) }
let beforeCount = controller.testWriterTransactions
let beforeWAL = walBytes()
let start = ProcessInfo.processInfo.systemUptime
let change = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
controller.testEventEmitter()!(items.map(\.path), Array(repeating: change, count: n), 110)
wait("live query offers the fixed burst") { controller.indexing && controller.lastPublishedQuery == "burst-fixture-" && offered.count == n }
let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
let transactions = controller.testWriterTransactions - beforeCount
let growth = walBytes() - beforeWAL
var pageSize: OpaquePointer?
precondition(sqlite3_prepare_v2(observer, "PRAGMA page_size", -1, &pageSize, nil) == SQLITE_OK)
precondition(sqlite3_step(pageSize) == SQLITE_ROW)
let frameSize = UInt64(sqlite3_column_int64(pageSize, 0)) + 24
sqlite3_finalize(pageSize)
precondition(transactions == 5, "First record plus four remaining bounded commits")
precondition(growth > 0 && growth < 512 * frameSize, "The fixed burst must avoid per-record WAL amplification")
print("BURST files=\(n) transactions=\(transactions) wal_growth_bytes=\(growth) publication_ms=\(elapsed)")
precondition(sqlite3_exec(observer, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
sqlite3_close(observer)
controller.testCheckpointBarrier = nil
gate.signal()
wait("warm scan and held event paths reconcile") { controller.testEventPipelineIdle }
let old = controller.testWatchIdentity!
let oldEmitter = controller.testEventEmitter()!
let priorScans = controller.testFullIndexScans
let existing = items[0].path
let ordinary = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
// Two local overflows in one main turn must only ask for one baseline.
for id in 120...121 {
    oldEmitter(Array(repeating: existing, count: 8193), Array(repeating: ordinary, count: 8193), UInt64(id))
}
wait("local backlog finishes one conservative baseline") { controller.testEventPipelineIdle && controller.testFullIndexScans == priorScans + 1 }
let localRetired = controller.testWatchIdentity != old
precondition(!localRetired, "Application capacity did not prove system stream loss")
print("OVERFLOW retired_watcher=\(localRetired) full_scans=\(controller.testFullIndexScans-priorScans)")
let watcher = controller.testWatchIdentity!
let beforeDrop = controller.testFullIndexScans
oldEmitter([scope.path], [FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)], 130)
wait("genuine loss finishes one conservative baseline") { controller.testEventPipelineIdle && controller.testFullIndexScans == beforeDrop + 1 }
precondition(controller.testWatchIdentity != watcher, "Genuine stream loss must retire watcher")
print("NATIVE_LOSS_FLAG retired_watcher=true full_scans=\(controller.testFullIndexScans-beforeDrop)")
controller.stopRuntime()

// Separate proven-history fixture: pause the prior scan at its checkpoint
// boundary and the prior event classifier. An ordinary overflow does not
// retire the watcher, but both stale authorities must be fenced.
let checkedStore = base.appendingPathComponent("checked-index")
let checkedDB = try FileSearchIndex(url: checkedStore.appendingPathComponent("index.sqlite"))
let checked = FileSearchController(directory: checkedStore, preferences: prefs, startImmediately: false)
defer { checked.stopRuntime() }
checked.testQuietIndexEventID = 140
checked.testDurableHistoryDomain = UUID()
checked.startRuntime()
checked.search("seed")
wait("establish proven fixture history") { (try? checkedDB.recoveryPoint()?.eventID) == 140 && checked.testEventPipelineIdle }
let sameWatcher = checked.testWatchIdentity!
let sameEmitter = checked.testEventEmitter()!
let olderWriter = DispatchSemaphore(value: 0), releaseOlderWriter = DispatchSemaphore(value: 0)
let olderEvent = DispatchSemaphore(value: 0), releaseOlderEvent = DispatchSemaphore(value: 0)
defer { releaseOlderWriter.signal(); releaseOlderEvent.signal() }
let publicationLock = NSLock()
var published: [UInt64: Bool] = [:]
checked.testCheckpointResult = { id, success in
    publicationLock.lock(); published[id] = success; publicationLock.unlock()
}
checked.testCheckpointBarrier = { id in
    if id == 150 { olderWriter.signal(); _ = releaseOlderWriter.wait(timeout: .now() + 18) }
}
checked.testQuietIndexEventID = 150
checked.startIndex()
var oldWriterPaused = false
wait("previous scan is about to publish") {
    if !oldWriterPaused { oldWriterPaused = olderWriter.wait(timeout: .now()) == .success }
    return oldWriterPaused
}
checked.testBeforeClassifyingEvents = {
    olderEvent.signal(); _ = releaseOlderEvent.wait(timeout: .now() + 18)
}
let stalePath = scope.appendingPathComponent("stale-classifier-event.txt")
sameEmitter([stalePath.path], [change], 999)
var oldEventPaused = false
wait("previous inbox classification is in flight") {
    if !oldEventPaused { oldEventPaused = olderEvent.wait(timeout: .now()) == .success }
    return oldEventPaused
}
var staleAccepted = false
checked.testTraceEligibleIndexPath = { if $0 == stalePath.path { staleAccepted = true } }
checked.testBeforeClassifyingEvents = nil
checked.testQuietIndexEventID = 160
let scanned = checked.testFullIndexScans
sameEmitter(Array(repeating: existing, count: 8193), Array(repeating: ordinary, count: 8193), 155)
let later = scope.appendingPathComponent("post-overflow-fixture.txt")
try Data("new".utf8).write(to: later)
sameEmitter([later.path], [change], 161)
releaseOlderWriter.signal(); releaseOlderEvent.signal()
wait("same healthy watcher delivers after fenced recovery") {
    (try? checkedDB.recoveryPoint()?.eventID) == 161 && checked.testEventPipelineIdle && checked.testFullIndexScans == scanned + 1
}
precondition(checked.testWatchIdentity == sameWatcher && !staleAccepted)
publicationLock.lock(); let fenced = published[150] == false && (published[160] == true || published[161] == true); publicationLock.unlock()
precondition(fenced, "The retired scan must not certify its old recovery position")
let laterRows = try checkedDB.search("post-overflow-fixture", options: options)
precondition(laterRows.map(\.id) == [later.path])
print("PASS healthy watcher serves post-backlog changes, while abandoned callback and writer cannot restore stale cursor")
