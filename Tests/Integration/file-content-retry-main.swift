import AppKit
import CoreServices
import SQLite3
import KeylaneCore
setbuf(stdout, nil)
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!)
let scope = base.appendingPathComponent("scope")
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
let file = scope.appendingPathComponent("document.txt")
try Data("reusablebody fixture".utf8).write(to: file)
let suite = "org.keylane.content-retry." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path]); options.contentSearch = true; options.ignorePatterns = []
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
// Prepare the isolated observer store before the controller opens its own connections.
let db = try FileSearchIndex(url: base.appendingPathComponent("index/index.sqlite"))
let lock = NSLock(), gate = DispatchSemaphore(value: 0)
var permitted = false, holdNext = false, held = false, calls = 0
let quiet = ProcessInfo.processInfo.environment["KEYLANE_VERIFY_LIVE_QUIET_ONLY"] == "1"
let controller = FileSearchController(directory: base.appendingPathComponent("index"), preferences: prefs, startImmediately: false, contentExtractor: { job, cancelled in
    lock.lock(); calls += 1; let allowed = permitted, hold = holdNext; holdNext = false; if hold { held = true }; lock.unlock()
    guard allowed else { throw FileContentReader.Failure.permission }
    if hold { gate.wait() }
    return try FileContentReader.read(job, cancelled: cancelled)
})
func wait(_ label: String, _ condition: () throws -> Bool) throws {
    let end = Date().addingTimeInterval(30)
    while try !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(try! condition(), label + ": " + controller.indexStatus)
}
if quiet { controller.testQuietIndexEventID = 42 }
controller.startRuntime()
controller.search("document")
try wait("permission blocks") { try db.hasEventDeferredContent() && !controller.indexing }
precondition(quiet || controller.testHasNativeFileWatcher, "Native FSEvents unavailable in this runner; notification and reuse stages were not exercised")
lock.lock(); let blockedCalls = calls; lock.unlock()
RunLoop.current.run(until: Date().addingTimeInterval(2))
lock.lock(); let stable = calls == blockedCalls; lock.unlock()
precondition(stable && (try! db.nextContentRetry()) == nil, "Permission failures must not continuously retry")
print("PASS permission failure persists without periodic extraction or retry deadline")
lock.lock(); permitted = true; lock.unlock()
controller.testIndexEvents(paths: [file.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemInodeMetaMod)])
try wait("permission notification wakes extraction") { try !db.search("reusablebody", options: options).isEmpty }
print("PASS permission metadata notification immediately wakes and validates body")
var raw: OpaquePointer?
precondition(sqlite3_open(base.appendingPathComponent("index/index.sqlite").path, &raw) == SQLITE_OK)
defer { sqlite3_close(raw) }
precondition(sqlite3_exec(raw, "CREATE TABLE body_changes(n); CREATE TRIGGER count_body_changes AFTER UPDATE OF body ON files WHEN old.body IS NOT new.body BEGIN INSERT INTO body_changes VALUES(1); END", nil, nil, nil) == SQLITE_OK)
lock.lock(); holdNext = true; lock.unlock()
try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(1)], ofItemAtPath: file.path)
if quiet { controller.testIndexEvents(paths: [file.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)]) }
try wait("real file event revalidates") { lock.lock(); defer { lock.unlock() }; return held }
precondition(try! db.search("reusablebody", options: options).isEmpty, "Unvalidated retained body leaked into search")
precondition(try! !db.search("document", options: options).isEmpty, "Filename must remain searchable")
gate.signal()
try wait("same body reused") { try !db.search("reusablebody", options: options).isEmpty && db.nextContentJob() == nil }
var q: OpaquePointer?
precondition(sqlite3_prepare_v2(raw, "SELECT count(*) FROM body_changes", -1, &q, nil) == SQLITE_OK)
precondition(sqlite3_step(q) == SQLITE_ROW && sqlite3_column_int(q,0) == 0, "Equal body must never be cleared then rewritten")
sqlite3_finalize(q)
print("PASS \(quiet ? "injected" : "real") modification event hides stale matches and reuses equal body without body changes")
controller.stopRuntime()
