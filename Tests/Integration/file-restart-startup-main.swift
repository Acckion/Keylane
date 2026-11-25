import AppKit
import CoreServices
import KeylaneCore

// These controller-state cases use a quiet injected watcher; the separate
// file-restart-main.swift fixture covers real FSEvents.
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!)
let scope = base.appendingPathComponent("source")
let state = base.appendingPathComponent("index")
let priorOnly = scope.appendingPathComponent("prior-only.txt")
let alsoIndexed = scope.appendingPathComponent("exclude-during-start.txt")
let cachedHidden = scope.appendingPathComponent("prior-only-hidden.txt")
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
for url in [priorOnly, alsoIndexed, cachedHidden] { try Data("fixture".utf8).write(to: url) }
try Data("qualifierbodyfixture".utf8).write(to: priorOnly)

let suite = "org.keylane.startup-state-fixture." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path])
options.ignorePatterns = []
options.contentSearch = true
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let db = try FileSearchIndex(url: state.appendingPathComponent("index.sqlite"))

let fixtureHistory = UUID()
func makeController() -> FileSearchController {
    let controller = FileSearchController(directory: state, preferences: prefs, startImmediately: false)
    controller.testQuietIndexEventID = 123
    controller.testDurableHistoryDomain = fixtureHistory
    return controller
}
var controller = makeController()
func wait(_ label: String, until ready: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(8)
    while try !ready(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    let passed = try ready()
    precondition(passed, "\(label): \(controller.indexStatus)")
}
func contains(_ item: URL) throws -> Bool {
    try db.search(item.lastPathComponent, options: options).contains { $0.id == item.path }
}

controller.startRuntime()
try wait("Fixture baseline") { try db.recoveryPoint() != nil && !controller.indexing }
controller.stopRuntime()
let original = try db.recoveryPoint()!
let originalConfig = original.configuration.replacingOccurrences(of: "\"searchFromLauncher\":false", with: "\"searchFromLauncher\":true")
precondition(originalConfig != original.configuration)
try db.saveRecoveryPoint(.init(eventID: original.eventID, configuration: originalConfig,
                               retryPaths: original.retryPaths, historyDomain: fixtureHistory))

controller = makeController()
var offered: [SpotlightFile] = []
controller.updated = { rows, _ in offered = rows }
controller.testDidBeginIndexRestoration = {
    controller.testDidBeginIndexRestoration = nil
    controller.options.searchFromLauncher = true
    controller.search(priorOnly.lastPathComponent, standalone: false)
}
controller.startRuntime()
try wait("Root search displays prior row after re-enable") {
    controller.indexStatus == "正在恢复文件变化…" && !controller.isSearching && offered.contains { $0.id == priorOnly.path }
}
precondition(controller.options.searchFromLauncher && controller.testFullIndexScans == 0)
controller.stopRuntime()
print("PASS quiet startup: launcher re-enable retrieves prior indexed row with same synthetic history and no full scan")

controller = makeController()
var attempts = 0
controller.testDidBeginIndexRestoration = {
    attempts += 1
    if attempts == 1 { controller.options.excludedPaths.append(alsoIndexed.path) }
    else { controller.testDidBeginIndexRestoration = nil }
}
controller.startRuntime()
try wait("Material exclusion supersedes in-flight restore") {
    try attempts == 2 && db.recoveryPoint()?.configuration != originalConfig && !controller.indexing
        && controller.testFullIndexScans == 1 && contains(priorOnly) && !contains(alsoIndexed)
}
controller.stopRuntime()
print("PASS quiet startup: material exclusion retries restore and rejects stale checkpoint")

// A retired generation cannot publish even if its writer reached the end
// of a full scan but has not yet crossed the actual checkpoint boundary.
controller = makeController()
controller.testQuietIndexEventID = 500
controller.startRuntime()
try wait("Old quiet watcher attached") { controller.testEventEmitter() != nil }
let oldEmitter = controller.testEventEmitter()!
let writerEntered = DispatchSemaphore(value: 0)
let releaseWriter = DispatchSemaphore(value: 0)
let lock = NSLock()
var publications: [UInt64: Bool] = [:]
controller.testCheckpointBarrier = { candidate in
    if candidate == 500 {
        writerEntered.signal()
        _ = releaseWriter.wait(timeout: .now() + 10)
    }
}
controller.testCheckpointResult = { eventID, saved in
    lock.lock(); publications[eventID] = saved; lock.unlock()
}
controller.startIndex()
var held = false
try wait("Retiring writer queued at checkpoint") {
    if !held { held = writerEntered.wait(timeout: .now()) == .success }
    return held
}
controller.testQuietIndexEventID = 12
oldEmitter([scope.path], [FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)], 1)
oldEmitter([scope.path], [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)], 501)
releaseWriter.signal()
try wait("New numeric domain baseline") {
    try !controller.indexing && controller.testFullIndexScans == 2 && db.recoveryPoint()?.eventID == 12
}
lock.lock()
let rejected = publications[500] == false && publications[12] == true
lock.unlock()
precondition(rejected, "Retired writer published or replacement did not")
oldEmitter([scope.path], [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)], 502)
let fresh = scope.appendingPathComponent("new-epoch-item.txt")
try Data("post-wrap".utf8).write(to: fresh)
controller.testQuietIndexEventID = 13
controller.testEventEmitter()!([fresh.path], [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)], 13)
try wait("Replacement watcher advances without retired event") {
    try !controller.indexing && contains(fresh) && db.recoveryPoint()?.eventID == 13
}
precondition(controller.testFullIndexScans == 2, "Retired events opened another full scan")
controller.stopRuntime()

controller = makeController()
controller.testQuietIndexEventID = 13
controller.startRuntime()
try wait("Restart uses new cursor") { controller.testQuietWatchStart == 13 && controller.indexStatus == "正在恢复文件变化…" }
precondition(controller.testFullIndexScans == 0)
controller.stopRuntime()
print("PASS quiet epoch: high-to-low wrap fences delayed callback and old writer; new cursor persists, advances and is reused")

controller = makeController()
controller.testQuietIndexEventID = 13
controller.startRuntime()
try wait("Watcher before stale startup sample") { controller.testEventEmitter() != nil }
controller.testEventEmitter()!([scope.path], [FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped)], 0)
try wait("Cached pre-wrap number stays untrusted") {
    try controller.testFullIndexScans == 1 && !controller.indexing && db.recoveryPoint() == nil
        && controller.testQuietWatchStart == FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
}
controller.testQuietIndexEventID = 2
controller.startIndex()
try wait("Verified low sample can establish a recovery point") { try !controller.indexing && db.recoveryPoint()?.eventID == 2 }
controller.stopRuntime()
print("PASS quiet epoch: cached pre-wrap high sample stays live-only until a low number is available")

// Matching configuration/root identities do not authorize a numeric host ID.
let valid = try db.recoveryPoint()!
for (label, domain, cursor) in [
    ("legacy-without-history", nil as UUID?, valid.eventID),
    ("changed-history", UUID() as UUID?, valid.eventID),
    ("regressed-history-tip", fixtureHistory as UUID?, UInt64(999))
] {
    try db.saveRecoveryPoint(.init(eventID: cursor, configuration: valid.configuration,
                                   retryPaths: valid.retryPaths, historyDomain: domain))
    controller = makeController()
    controller.testQuietIndexEventID = 30
    controller.startRuntime()
    try wait(label) {
        try controller.testFullIndexScans == 1 && !controller.indexing
            && controller.testQuietWatchStart == 30 && db.recoveryPoint()?.eventID == 30
            && db.recoveryPoint()?.historyDomain == fixtureHistory
    }
    controller.stopRuntime()
}
print("PASS quiet provenance: legacy, changed UUID and cursor beyond current history force a new baseline")

try db.saveRecoveryPoint(.init(eventID: 30, configuration: valid.configuration, historyDomain: fixtureHistory))
var cachedOptions = try JSONDecoder().decode(FileSearchOptions.self, from: prefs.data(forKey: "fileSearchOptions")!)
cachedOptions.excludedPaths.append(cachedHidden.path)
prefs.set(try JSONEncoder().encode(cachedOptions), forKey: "fileSearchOptions")
let hadCachedExclusion = try contains(cachedHidden)
precondition(hadCachedExclusion)
controller = makeController()
controller.testDurableHistoryDomain = nil
offered = []
controller.updated = { rows, _ in offered = rows }
let releaseInitialScan = DispatchSemaphore(value: 0)
controller.testScanStartBarrier = { _ = releaseInitialScan.wait(timeout: .now() + 10) }
controller.startRuntime()
try wait("Startup discards unproved cursor without starting the crawler") { try db.recoveryPoint() == nil }
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
precondition(controller.testFullIndexScans == 0 && controller.testEventEmitter() == nil, "Idle launch woke the crawler")
controller.options.searchFromLauncher = true
controller.search("prior-only", standalone: false)
try wait("Cached results remain available while reconciliation is held before file reads") {
    controller.indexing && offered.contains { $0.id == priorOnly.path }
}
precondition(!offered.contains { $0.id == cachedHidden.path }, "Cached search leaked a newly excluded row")
controller.search("qualifierbodyfixture", standalone: false)
try wait("Wait for content-only search during unresolved reconciliation") {
    controller.indexing && !controller.isSearching && controller.lastPublishedQuery == "qualifierbodyfixture"
}
precondition(offered.isEmpty, "Cached text match was offered before reconciliation")
controller.testScanStartBarrier = nil
releaseInitialScan.signal()
try wait("No verified history starts a live-only baseline without publishing a cursor") {
    try controller.testFullIndexScans == 1 && !controller.indexing && db.recoveryPoint() == nil
      && controller.testQuietWatchStart == FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
}
try wait("Content matching resumes after baseline") {
    !controller.isSearching && offered.contains { $0.id == priorOnly.path && $0.matchesContent }
}
for n in 1...2 {
    let update = scope.appendingPathComponent("live-without-history-\(n).txt")
    try Data("new-live-item".utf8).write(to: update)
    controller.testEventEmitter()!([update.path], [FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)], UInt64(30+n))
    try wait("Live event uses a local update without new full scan") {
        try !controller.indexing && contains(update) && db.recoveryPoint() == nil
    }
    precondition(controller.testFullIndexScans == 1)
}
controller.stopRuntime()
print("PASS quiet live-only: idle launch performs no crawl; first query preserves safe cached names, and two live changes stay incremental")
