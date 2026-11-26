import AppKit
import KeylaneCore

setbuf(stdout, nil)
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!).appendingPathComponent("search")
let scope = base.appendingPathComponent("scope")
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
let file = scope.appendingPathComponent("match-first.txt")
try Data().write(to: file)
let suite = "org.keylane.search-scheduling." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path]); options.ignorePatterns = []; options.contentSearch = false
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let store = base.appendingPathComponent("index")
let controller = FileSearchController(directory: store, preferences: prefs, watchChanges: false)
var results: [SpotlightFile] = []
controller.updated = { rows, _ in results = rows }
func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func wait(_ label: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(35)
    while !condition(), Date() < deadline { pump(0.01) }
    precondition(condition(), label + ": " + controller.indexStatus)
}
controller.search("match-first")
wait("Fixture indexed") { !controller.indexing && !controller.isSearching && results.count == 1 }
let firstGate = DispatchSemaphore(value: 0), secondGate = DispatchSemaphore(value: 0)
let lock = NSLock(); var calls = 0
controller.testBeforeLocalQuery = { _ in
    lock.lock(); calls += 1; let call = calls; lock.unlock()
    if call == 1 { firstGate.wait() }
    if call == 2 { secondGate.wait() }
}
func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
let before = controller.testQueryDiagnostics
controller.search("match")
wait("First local query active") { count() == 1 }
for _ in 0..<100 { controller.testRefreshQuery(); pump(0.002) }
precondition(controller.testQueryDiagnostics.pending == 1)
firstGate.signal()
wait("Same-query result is usable while fresher query waits") {
    count() == 2 && controller.lastPublishedQuery == "match" && !controller.isSearching && results.count == 1
}
let latest = scope.appendingPathComponent("match-latest.txt")
try Data().write(to: latest)
let db = try FileSearchIndex(url: store.appendingPathComponent("index.sqlite"))
try db.put(.init(path: latest.path, name: latest.lastPathComponent, volume: "/", modified: 1, directory: false, symlink: false), root: scope.path, epoch: "n:fixture")
secondGate.signal()
wait("Latest queued refresh sees new records") { results.count == 2 && !controller.isSearching }
let after = controller.testQueryDiagnostics
precondition(after.executed - before.executed == 2, "Superseded refreshes executed on the reader")
print("PASS 100 refreshes keep one pending request; current result publishes before the latest refresh completes")
let stable = controller.testQueryDiagnostics.submitted
for _ in 0..<1000 { controller.search("match") }
pump(0.1)
precondition(controller.testQueryDiagnostics.submitted == stable, "Identical public search repeated SQL")
print("PASS 1000 duplicate search calls perform no extra SQL")
// A changed query must revoke the blocked old result, unlike a data-only refresh.
let obsoleteGate = DispatchSemaphore(value: 0)
var entered = false
controller.testBeforeLocalQuery = { query in
    if query == "match-first" { lock.lock(); entered = true; lock.unlock(); obsoleteGate.wait() }
}
controller.search("match-first")
wait("Obsolete query active") { lock.lock(); defer { lock.unlock() }; return entered }
controller.search("match-latest")
pump(0.1)
obsoleteGate.signal()
wait("New input wins") { controller.lastPublishedQuery == "match-latest" && results.map(\.name) == ["match-latest.txt"] && !controller.isSearching }
print("PASS changed input cancels obsolete work and never publishes the old query")
// Disable with a request in flight: the old task cannot restore rows or keep busy state.
entered = false
controller.search("match-first")
wait("Request active before disable") { lock.lock(); defer { lock.unlock() }; return entered }
controller.options.enabled = false
obsoleteGate.signal()
pump(0.2)
precondition(!controller.isSearching && results.isEmpty)
controller.stopRuntime()
print("PASS disabled module cancels in-flight search and clears loading state")
