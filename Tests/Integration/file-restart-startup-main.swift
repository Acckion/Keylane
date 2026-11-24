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
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
for url in [priorOnly, alsoIndexed] { try Data("fixture".utf8).write(to: url) }

let suite = "org.keylane.startup-state-fixture." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path])
options.ignorePatterns = []
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let db = try FileSearchIndex(url: state.appendingPathComponent("index.sqlite"))

func makeController() -> FileSearchController {
    let controller = FileSearchController(directory: state, preferences: prefs, startImmediately: false)
    controller.testQuietIndexEventID = 123
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
try db.saveRecoveryPoint(.init(eventID: original.eventID, configuration: originalConfig, retryPaths: original.retryPaths))

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
print("PASS quiet startup: launcher re-enable retrieves prior indexed row with legacy checkpoint and no full scan")

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
