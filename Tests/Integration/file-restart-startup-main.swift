import AppKit
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
