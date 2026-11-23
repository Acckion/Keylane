import AppKit
import KeylaneCore

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
