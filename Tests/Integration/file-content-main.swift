import AppKit
import KeylaneCore
import SQLite3

setbuf(stdout, nil)
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!).appendingPathComponent("content")
let scope = base.appendingPathComponent("scope")
let store = base.appendingPathComponent("index")
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
let file = scope.appendingPathComponent("document.txt")
try Data("initialbody".utf8).write(to: file)
let suite = "org.keylane.content-test." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path]); options.contentSearch = true; options.ignorePatterns = []
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let db = try FileSearchIndex(url: store.appendingPathComponent("index.sqlite"))
let gate = DispatchSemaphore(value: 0)
let lock = NSLock()
var calls = 0
var shouldBlock = true
var entered = false
let controller = FileSearchController(directory: store, preferences: prefs, watchChanges: false, contentExtractor: { job, cancelled in
    lock.lock(); calls += 1; let block = shouldBlock; shouldBlock = false; entered = true; lock.unlock()
    if block { gate.wait(); return "obsoletebody" }
    return try FileContentReader.read(job, cancelled: cancelled)
})
func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func wait(_ label: String, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(35)
    while try !condition(), Date() < deadline { pump(0.025) }
    let ok = try condition(); precondition(ok, label + ": " + controller.indexStatus)
}
func bodyMatches(_ text: String) throws -> Bool { try !db.search(text, options: options).isEmpty }
controller.search("document")
try wait("Metadata completes while extraction is blocked") {
    lock.lock(); let active = entered; lock.unlock()
    return try active && !controller.indexing && !db.search("document", options: options).isEmpty
}
// An independent transaction proves extraction holds no SQLite write lock.
let start = Date()
try db.transaction { try db.saveRecoveryPoint(.init(eventID: 1, configuration: "fixture")) }
precondition(Date().timeIntervalSince(start) < 2, "Extraction held a write transaction")
print("PASS searchable metadata and independent database writes while body extraction is blocked")
try Data("freshbody".utf8).write(to: file)
controller.startIndex(force: true)
try wait("New metadata commits before old extraction returns") { try !controller.indexing && db.nextContentJob() != nil }
gate.signal()
try wait("Latest body replaces old job") { try bodyMatches("freshbody") }
let stale = try bodyMatches("obsoletebody"); precondition(!stale)
print("PASS stale extraction cannot overwrite a newer metadata generation")
// Pause with another native-style call in flight. Cancellation cannot free its
// slot until it returns, so resume cannot spawn unbounded workers.
lock.lock(); shouldBlock = true; entered = false; lock.unlock()
controller.startIndex(force: true)
try wait("Second blocked body starts") { lock.lock(); defer { lock.unlock() }; return entered }
controller.setIndexPaused(true)
gate.signal(); pump(0.3)
let paused = try bodyMatches("obsoletebody"); precondition(!paused)
let pending = try db.nextContentJob(); precondition(pending != nil)
controller.stopRuntime()
// Durable requests resume in a fresh controller without waiting for new events.
let restored = FileSearchController(directory: store, preferences: prefs, watchChanges: false)
restored.setIndexPaused(false)
restored.search("freshbody")
try wait("Persisted body work resumes") { try bodyMatches("freshbody") }
print("PASS pause/stop prevents late writes, persistent work resumes after restart")
// Disable content while existing bodies remain in the cache.
restored.options.contentSearch = false
try wait("Content off removes body and pending work") { try !bodyMatches("freshbody") && db.nextContentJob() == nil }
restored.stopRuntime(); controller.stopRuntime()
print("PASS content disable clears work and body results")

// A failed commit must not create a fast retry loop or damage metadata search.
func databaseSQL(_ sql: String) {
    var connection: OpaquePointer?
    precondition(sqlite3_open(store.appendingPathComponent("index.sqlite").path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    precondition(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
}
databaseSQL("CREATE TRIGGER reject_body BEFORE UPDATE OF body ON files WHEN new.body<>'' BEGIN SELECT RAISE(ABORT,'fixture'); END")
var faultCalls = 0
let faulted = FileSearchController(directory: store, preferences: prefs, watchChanges: false, contentExtractor: { _, _ in
    lock.lock(); faultCalls += 1; lock.unlock()
    return "faultbody"
})
faulted.options.contentSearch = true
try wait("Commit failure reported") { faulted.indexStatus.hasPrefix("正文索引暂不可用") }
faulted.startIndex(force: true)
try wait("Metadata refresh during body failure") { !faulted.indexing }
pump(1)
lock.lock(); let attempts = faultCalls; lock.unlock()
precondition(attempts == 1, "Failed body commit retried without backoff")
let namesRemain = try db.search("document", options: options).count
precondition(namesRemain == 1, "Body failure broke searchable metadata")
faulted.stopRuntime(); pump(0.1)
databaseSQL("DROP TRIGGER reject_body")
let recovered = FileSearchController(directory: store, preferences: prefs, watchChanges: false)
try wait("Commit retry succeeds after restart") { try bodyMatches("freshbody") }
recovered.stopRuntime()
print("PASS injected SQLite body failure backs off, preserves metadata, and recovers after restart")

// A persisted job from a prior valid scan must not use ambient access when
// its saved bookmark cannot be proved in the current runtime.
let deniedStore = base.appendingPathComponent("denied-index")
let deniedDB = try FileSearchIndex(url: deniedStore.appendingPathComponent("index.sqlite"))
let deniedModified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!.timeIntervalSince1970
try deniedDB.stageMetadata(.init(path: file.path, name: file.lastPathComponent, volume: "/", modified: deniedModified,
                                 directory: false, symlink: false), root: scope.path, epoch: "c:prior-grant", contentSearch: true)
let priorGrantJob = try deniedDB.nextContentJobs(certifiedOnly: true).first!
prefs.set([scope.path: Data([0])], forKey: "fileSearchGrants")
var deniedReads = 0
let denied = FileSearchController(directory: deniedStore, preferences: prefs, watchChanges: false, contentExtractor: { _, _ in
    lock.lock(); deniedReads += 1; lock.unlock()
    return "shouldnotread"
})
try wait("Unproved persisted grant parks before invoking extraction") {
    try deniedDB.nextContentRetry(certifiedOnly: true) == nil
}
lock.lock(); let deniedReadCount = deniedReads; lock.unlock()
precondition(deniedReadCount == 0)
let deniedPublication = try deniedDB.completeContent(priorGrantJob, body: "old")
precondition(!deniedPublication)
denied.stopRuntime()
print("PASS unresolved bookmark cannot use ambient permission and parks its certified job")
