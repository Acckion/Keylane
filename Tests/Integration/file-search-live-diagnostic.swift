import CoreServices
import Darwin
import Foundation
import KeylaneCore
import SQLite3

setbuf(stdout, nil)

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

let manager = FileManager.default
// Foundation may rewrite the physical /private/tmp spelling back to /tmp.
// The controller indexes the configured root literally. Use the same physical
// spelling for its root, the fixture marker paths, and the readonly SQL checks.
func physicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}
let configuredFixture = ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!
guard let canonicalFixture = physicalPath(configuredFixture),
      canonicalFixture.hasPrefix("/private/tmp/") else {
    throw FixtureFailure(description: "Expected a physical /private/tmp fixture root")
}
let tmpAlias = "/tmp/" + canonicalFixture.dropFirst("/private/tmp/".count)
guard physicalPath(tmpAlias) == canonicalFixture else {
    throw FixtureFailure(description: "Fixture /tmp alias did not match its physical /private/tmp path")
}
print("PASS POSIX fixture root normalizes /tmp and /private/tmp to the same directory")
let testRoot = URL(fileURLWithPath: canonicalFixture, isDirectory: true)
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
// Only accept exact marker identity (or its POSIX equivalent). Merely seeing
// a root/parent callback does not satisfy a marker stage.
func fixturePath(_ path: String) -> String? {
    guard path == canonicalFixture || path.hasPrefix(canonicalFixture + "/") ||
          path == tmpAlias || path.hasPrefix(tmpAlias + "/") else { return nil }
    return physicalPath(path)
}
var warmupPaths = Set<String>()
var productWarmup = Set<String>()
var observerSeen: [String: Double] = [:]
var productCallbacks = 0, productAncestors = 0, productAliases = 0, retiredCallbacks = 0
var observerCallbacks = 0, observerAncestors = 0
controller.testTraceRawIndexPath = { path, flag, current in
    guard let normalized = fixturePath(path) else { return }
    productCallbacks += 1
    if normalized != path { productAliases += 1 }
    if normalized == scope.path { productAncestors += 1 }
    guard current else { retiredCallbacks += 1; return }
    if warmupPaths.contains(normalized) { productWarmup.insert(normalized) }
    if let m = markers.first(where: { $0.url.path == normalized }), raw[m.label] == nil {
        raw[m.label] = note("FSEvents callback flags=\(flag)", marker: m)
    }
}
controller.testTraceEligibleIndexPath = { path in
    guard let normalized = fixturePath(path) else { return }
    if let m = markers.first(where: { $0.url.path == normalized }), eligible[m.label] == nil {
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

// An independent native watcher on the same test root distinguishes absent
// OS delivery from the product's event or scheduling path. It never injects
// anything into the controller and does not restart the product watcher.
final class DiagnosticObserver {
    let handle: (String) -> Void
    init(_ handle: @escaping (String) -> Void) { self.handle = handle }
}
let diagnostics = DiagnosticObserver { path in
    guard let normalized = fixturePath(path) else { return }
    observerCallbacks += 1
    if normalized == scope.path { observerAncestors += 1 }
    if let m = markers.first(where: { $0.url.path == normalized }), observerSeen[m.label] == nil {
        observerSeen[m.label] = note("independent FSEvents callback", marker: m)
    }
}
var observerContext = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(diagnostics).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
let observer = FSEventStreamCreate(nil, { _, context, _, paths, _, _ in
    guard let context else { return }
    let diagnostics = Unmanaged<DiagnosticObserver>.fromOpaque(context).takeUnretainedValue()
    for path in Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String] {
        diagnostics.handle(path)
    }
}, &observerContext, [scope.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
   FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
                            kFSEventStreamCreateFlagNoDefer))
var observerActive = false
if let observer {
    FSEventStreamSetDispatchQueue(observer, .main)
    observerActive = FSEventStreamStart(observer)
}
defer {
    if let observer {
        if observerActive { FSEventStreamStop(observer) }
        FSEventStreamInvalidate(observer)
        FSEventStreamRelease(observer)
    }
    withExtendedLifetime(diagnostics) {}
}

func counts() -> String {
    "productRaw=\(productCallbacks) productAncestor=\(productAncestors) productAliases=\(productAliases) retired=\(retiredCallbacks) independentStarted=\(observerActive) independentRaw=\(observerCallbacks) independentAncestor=\(observerAncestors)"
}
// Initial registration alone was not a delivery check. Warm up with bounded
// seed writes until the PRODUCT stream sees one; the independent observer is
// purely diagnostic and can never fail or satisfy a product assertion.
var nextWarmup = now(), warmupCount = 0
do {
    try wait("one synthetic warmup file reaches the product watcher") {
        if !productWarmup.isEmpty { return true }
        if now() >= nextWarmup, warmupCount < 6 {
            warmupCount += 1
            nextWarmup = now() + 1
            let url = scope.appendingPathComponent("watcher-warmup-\(warmupCount).txt")
            warmupPaths.insert(url.path)
            try Data("synthetic watcher readiness".utf8).write(to: url)
        }
        return false
    }
    try wait("drain product event pipeline before tracked marker") { controller.testEventPipelineIdle }
} catch {
    throw FixtureFailure(description: "\(error); " + counts())
}
print("PASS product watcher delivered a real warmup marker; " + counts())

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
    do {
        try wait("\(m.label): product FSEvents callback") { _ = try hasMetadata(m); return raw[m.label] != nil }
        try wait("\(m.label): product event classification") { _ = try hasMetadata(m); return eligible[m.label] != nil }
    } catch {
        throw FixtureFailure(description: "\(error); " + counts() +
            " independent=\(observerSeen[m.label] != nil) product=\(raw[m.label] != nil) eligible=\(eligible[m.label] != nil)")
    }
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
try wait("full scan finished enumeration and is held outside the writer") { barrierReached() && controller.indexing }
try write(during)
try event(during)
try observe(during)
gateLock.lock()
let stillHeld = !releasedBarrier
gateLock.unlock()
guard controller.indexing, stillHeld else {
    throw FixtureFailure(description: "Live metadata and visible results must arrive before the warm baseline resumes")
}
print("during warm baseline: classified=true metadata=true published=true gate=held")
if holdSeconds > 0, let start = written[during.label] {
    while now() - start < holdSeconds { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}
releaseBarrier()
controller.testCheckpointBarrier = nil
try observe(during)
try wait("gated baseline and incremental event both finished") { controller.testEventPipelineIdle }
let retainedDuring = try hasMetadata(during)
guard retainedDuring, published[during.label] != nil else {
    throw FixtureFailure(description: "Live metadata did not survive baseline cleanup")
}

try prime(post)
try write(post)
try event(post)
try observe(post)
try wait("final marker wave finished") { !controller.indexing }
print("PASS real FSEvents: steady before/after; metadata and automatic publication arrive during the held warm baseline and survive cleanup")
