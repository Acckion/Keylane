import AppKit
import KeylaneCore
import SQLite3

setbuf(stdout, nil)

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

let manager = FileManager.default
let testRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!, isDirectory: true)
    .resolvingSymlinksInPath()
let scope = testRoot.appendingPathComponent("scope", isDirectory: true)
let store = testRoot.appendingPathComponent("index", isDirectory: true)
try manager.createDirectory(at: scope, withIntermediateDirectories: true)
try Data("synthetic initial baseline".utf8).write(to: scope.appendingPathComponent("baselineseed.txt"))
let suite = "org.keylane.file-search-live-diagnostic." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path])
options.ignorePatterns = []
options.contentSearch = false
options.useIgnoreFiles = true // Isolates SQLite results; no Spotlight candidate fallback.
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let controller = FileSearchController(directory: store, preferences: prefs,
                                      watchChanges: true, startImmediately: false)
defer { controller.stopRuntime() }

let epoch = ProcessInfo.processInfo.systemUptime
func now() -> Double { ProcessInfo.processInfo.systemUptime - epoch }
let deadlineText = ProcessInfo.processInfo.environment["KEYLANE_FILE_MARKER_TIMEOUT"]
let limit = min(240.0, max(5.0, deadlineText.flatMap(Double.init) ?? 35.0))
let holdText = ProcessInfo.processInfo.environment["KEYLANE_FILE_HOLD_GATED_SECONDS"]
let holdSeconds = min(240.0, max(0.0, holdText.flatMap(Double.init) ?? 0.0))
func wait(_ label: String, for seconds: Double = limit, until condition: () throws -> Bool) throws {
    let deadline = now() + seconds
    repeat {
        if try condition() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    } while now() < deadline
    throw FixtureFailure(description: "TIMEOUT \(label) (\(seconds)s; indexing=\(controller.indexing) searching=\(controller.isSearching) status=\(controller.indexStatus))")
}

typealias Marker = (label: String, needle: String, url: URL)
func makeMarker(_ label: String) -> Marker {
    let needle = "phase" + label + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    return (label, needle, scope.appendingPathComponent(needle + ".txt"))
}
let pre = makeMarker("before"), during = makeMarker("during"), post = makeMarker("after")
let markers = [pre, during, post]
var raw: [String: Double] = [:], eligible: [String: Double] = [:]
var metadata: [String: Double] = [:], published: [String: Double] = [:], written: [String: Double] = [:]
var results: [SpotlightFile] = []
func note(_ stage: String, marker: Marker) -> Double {
    let t = now()
    let lag = written[marker.label].map { String(format: "%.3fs", t - $0) } ?? "pre-write"
    print("\(marker.label) \(stage) t=\(String(format: "%.3f", t)) delta=\(lag)")
    return t
}
controller.testTraceRawIndexPath = { path in
    if let m = markers.first(where: { $0.url.path == path }), raw[m.label] == nil {
        raw[m.label] = note("FSEvents callback", marker: m)
    }
}
controller.testTraceEligibleIndexPath = { path in
    if let m = markers.first(where: { $0.url.path == path }), eligible[m.label] == nil {
        eligible[m.label] = note("classified/dirty", marker: m)
    }
}
controller.updated = { rows, _ in
    results = rows
    if let m = markers.first(where: { $0.needle == controller.lastPublishedQuery }),
       rows.map(\.id) == [m.url.path], published[m.label] == nil {
        published[m.label] = note("query published exact result", marker: m)
    }
}

controller.startRuntime()
controller.search("baselineseed", includeContents: false)
try wait("initial local-only baseline") {
    !controller.indexing && !controller.isSearching &&
        controller.lastPublishedQuery == "baselineseed" && results.count == 1
}

guard controller.testHasNativeFileWatcher else {
    throw FixtureFailure(description: "FSEvents native watcher did not start in this runner; stage assertions were not exercised")
}

var db: OpaquePointer?
let dbURL = store.appendingPathComponent("index.sqlite")
let opened = sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
defer { sqlite3_close(db) }
guard opened == SQLITE_OK else { throw FixtureFailure(description: "Cannot observe isolated database read-only") }
sqlite3_busy_timeout(db, 100)
func hasMetadata(_ m: Marker) throws -> Bool {
    var s: OpaquePointer?
    let sql = "SELECT 1 FROM files WHERE path=? AND root=? AND directory=0 AND symlink=0"
    guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else {
        throw FixtureFailure(description: "Cannot prepare readonly metadata observation")
    }
    defer { sqlite3_finalize(s) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard sqlite3_bind_text(s, 1, m.url.path, -1, transient) == SQLITE_OK,
          sqlite3_bind_text(s, 2, scope.path, -1, transient) == SQLITE_OK else {
        throw FixtureFailure(description: "Cannot bind readonly metadata observation")
    }
    let status = sqlite3_step(s)
    if status == SQLITE_ROW {
        if metadata[m.label] == nil { metadata[m.label] = note("SQLite metadata committed", marker: m) }
        return true
    }
    if status == SQLITE_DONE || status == SQLITE_BUSY || status == SQLITE_LOCKED { return false }
    throw FixtureFailure(description: "Readonly metadata observation failed (\(status))")
}
func prime(_ m: Marker) throws {
    controller.search(m.needle, includeContents: false)
    try wait("\(m.label): unique pre-write query published empty") {
        !controller.isSearching && controller.lastPublishedQuery == m.needle && results.isEmpty
    }
    guard try !hasMetadata(m) else { throw FixtureFailure(description: "Marker existed before fixture write") }
}
func write(_ m: Marker) throws {
    written[m.label] = note("write synthetic marker", marker: m)
    try Data("synthetic marker payload".utf8).write(to: m.url)
}
func event(_ m: Marker) throws {
    try wait("\(m.label): product FSEvents callback") { _ = try hasMetadata(m); return raw[m.label] != nil }
    try wait("\(m.label): product event classification") { _ = try hasMetadata(m); return eligible[m.label] != nil }
}
func observe(_ m: Marker) throws {
    try wait("\(m.label): event-driven metadata commit") { try hasMetadata(m) }
    try wait("\(m.label): automatic updated callback, without retyping") { published[m.label] != nil }
}

try prime(pre)
try write(pre)
try event(pre)
try observe(pre)
try wait("stable before gated baseline") { !controller.indexing }

let gate = DispatchSemaphore(value: 0)
let gateLock = NSLock()
var reachedBarrier = false
var releasedBarrier = false
func barrierReached() -> Bool { gateLock.lock(); defer { gateLock.unlock() }; return reachedBarrier }
func releaseBarrier() {
    gateLock.lock(); defer { gateLock.unlock() }
    if !releasedBarrier { releasedBarrier = true; gate.signal() }
}
defer { releaseBarrier() }
controller.testCheckpointBarrier = { _ in
    gateLock.lock()
    let first = !reachedBarrier
    reachedBarrier = true
    gateLock.unlock()
    if first { _ = gate.wait(timeout: .now() + 2 * limit + holdSeconds + 10) }
}
try prime(during)
controller.startIndex()
try wait("full scan finished enumeration but has not returned from writer") { barrierReached() && controller.indexing }
try write(during)
try event(during)
if holdSeconds > 0, let start = written[during.label] {
    while now() - start < holdSeconds {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        if try hasMetadata(during) { break }
    }
}
let hasDuring = try hasMetadata(during)
print("during baseline held: classified=true metadata=\(hasDuring) published=\(published[during.label] != nil)")
guard controller.indexing, !hasDuring, published[during.label] == nil else {
    throw FixtureFailure(description: "Comparison invariant failed; baseline did not hold metadata or live patch already exists")
}
releaseBarrier()
controller.testCheckpointBarrier = nil
try observe(during)
try wait("gated baseline and incremental event both finished") { !controller.indexing }

try prime(post)
try write(post)
try event(post)
try observe(post)
try wait("final marker wave finished") { !controller.indexing }
print("PASS real FSEvents: steady before/after; metadata and publication deferred while #246's baseline is gated, then automatically visible")
