import AppKit
import CoreServices
import KeylaneCore

setbuf(stdout, nil)

// All paths and preferences are isolated fixtures; no user index is read.
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!).appendingPathComponent("restart")
let scope = base.appendingPathComponent("scope")
let quiet = base.appendingPathComponent("quiet")
let store = base.appendingPathComponent("index")
for url in [scope, quiet] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
let nested = scope.appendingPathComponent("nested")
try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
for i in 0..<2000 { try Data("fixture".utf8).write(to: nested.appendingPathComponent("fixture-\(i).txt")) }
// Discovery of a known generated directory must not invalidate the next startup.
try FileManager.default.createDirectory(at: scope.appendingPathComponent("node_modules"), withIntermediateDirectories: false)
let suite = "org.keylane.restart-test." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path, quiet.path]); options.contentSearch = false; options.ignorePatterns = []
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let db = try FileSearchIndex(url: store.appendingPathComponent("index.sqlite"))
func cpuSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}
let coldCPU = cpuSeconds()
var controller = FileSearchController(directory: store, preferences: prefs)
controller.search("fixture", standalone: false)
func require(_ value: Bool, _ message: String) { precondition(value, message) }
func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func wait(_ label: String, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(40)
    while try !condition(), Date() < deadline { pump(0.04) }
    require(try condition(), "\(label): \(controller.indexStatus)")
}
func contains(_ name: String) throws -> Bool { try db.search(name, options: options).contains { $0.name == name } }
try wait("Initial complete baseline") {
    try controller.testFullIndexScans == 1 && !controller.indexing && contains("fixture-1999.txt")
}
precondition(controller.testEventEmitter() != nil, "Native FSEvents unavailable on this runner")
require(try db.recoveryPoint() == nil, "Host watcher must not publish a restart cursor")
print("MEASURE initial 2000-file baseline CPU seconds=\(cpuSeconds() - coldCPU), scan seconds=\(controller.stats.seconds)")
controller.stopRuntime(); pump(0.3)
let removed = nested.appendingPathComponent("fixture-0.txt")
let renamed = nested.appendingPathComponent("renamed-fixture.txt")
try FileManager.default.removeItem(at: removed)
try FileManager.default.moveItem(at: nested.appendingPathComponent("fixture-1.txt"), to: renamed)
let added = nested.appendingPathComponent("offline-added.txt")
try Data("offline".utf8).write(to: added)
let build = nested.appendingPathComponent("build")
try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
for i in 0..<140 { try Data().write(to: build.appendingPathComponent("history-fixture-\(i).txt")) }
pump(3)
let restartCPU = cpuSeconds()
controller = FileSearchController(directory: store, preferences: prefs)
controller.search("fixture", standalone: false)
try wait("Offline add/delete/rename reconciliation") {
    try controller.testFullIndexScans == 1 && !controller.indexing && contains(added.lastPathComponent) && contains(renamed.lastPathComponent)
        && !contains(removed.lastPathComponent) && !contains("fixture-1.txt")
}
require(controller.testFullIndexScans == 1, "Restart should reconcile once without trusting host history")
try wait("Offline build directory reconciles") { try db.search("history-fixture", options: options).count == 140 && !controller.indexing }
require(!controller.automaticExclusions.contains { $0.path == build.path }, "Historical events were treated as a live churn burst")
print("MEASURE restart reconciliation CPU seconds=\(cpuSeconds() - restartCPU), scan seconds=\(controller.stats.seconds)")
print("PASS offline add, delete and rename reconcile with one full scan and no durable host cursor")
let live = nested.appendingPathComponent("native-live-after-restart.txt")
try Data("native".utf8).write(to: live)
try wait("Native live event remains incremental") { try !controller.indexing && contains(live.lastPathComponent) }
precondition(controller.testFullIndexScans == 1)
require(try db.recoveryPoint() == nil, "Host watcher published a durable cursor after local change")
print("PASS native live update with no additional full scan")
controller.stopRuntime(); pump(0.3)
options.ignorePatterns.append("offline-added.txt")
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
controller = FileSearchController(directory: store, preferences: prefs)
controller.search("fixture", standalone: false)
try wait("Changed rules fallback") { controller.testFullIndexScans == 1 && !controller.indexing }
require(try !contains(added.lastPathComponent), "Changed exclusions retained stale row")
print("PASS changed configuration rebuilds baseline and removes excluded rows")
controller.stopRuntime(); pump(0.3)
// Losing authorization changes the fingerprint even when saved options do not.
prefs.set([scope.path], forKey: "fileSearchSelectedScopes")
controller = FileSearchController(directory: store, preferences: prefs)
controller.search("fixture", standalone: false)
try wait("Authorization change baseline") { controller.testFullIndexScans == 1 && !controller.indexing }
controller.stopRuntime(); pump(0.3)
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
controller = FileSearchController(directory: store, preferences: prefs)
controller.search("fixture", standalone: false)
try wait("Authorization reenable baseline") { controller.testFullIndexScans == 1 && !controller.indexing }
print("PASS authorization changes cannot reuse a stale baseline")
// A temporarily unreadable subtree must not force every other root to crawl.
let locked = scope.appendingPathComponent("locked")
try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
let lockedFile = locked.appendingPathComponent("locked-fixture.txt")
try Data().write(to: lockedFile)
try wait("Initial readable subtree") { try contains(lockedFile.lastPathComponent) && !controller.indexing }
controller.stopRuntime(); pump(0.3)
try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
controller = FileSearchController(directory: store, preferences: prefs)
controller.search("fixture", standalone: false)
try wait("Unreadable subtree queued for repair") { controller.testFullIndexScans == 1 && !controller.indexing && controller.inaccessible.contains(locked.path) }
require(try contains(lockedFile.lastPathComponent), "Unreadable subtree lost its saved rows")
require(controller.testFullIndexScans == 1, "Unreadable subtree caused a second full scan")
controller.stopRuntime(); pump(0.3)
controller = FileSearchController(directory: store, preferences: prefs)
controller.search("fixture", standalone: false)
try wait("Restart reconciles with unreadable subtree") { controller.testFullIndexScans == 1 && !controller.indexing }
pump(6)
require(controller.testFullIndexScans == 1, "Unreadable subtree repeatedly triggered full scans")
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
try FileManager.default.removeItem(at: lockedFile)
try Data().write(to: locked.appendingPathComponent("unlocked-fixture.txt"))
try wait("Permission restored subtree repair") { try !controller.indexing && !contains(lockedFile.lastPathComponent) && contains("unlocked-fixture.txt") }
print("PASS unreadable subtree retains rows, retries locally, and recovers after permissions return")
// A numeric wrap also needs a genuinely new counter; exercise it in the quiet fixture.
for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
             kFSEventStreamEventFlagRootChanged] {
    let count = controller.testFullIndexScans
    controller.testIndexEvents(paths: [scope.path], flags: [FSEventStreamEventFlags(flag)])
    try wait("Lost/root-changed event fallback") { !controller.indexing && controller.testFullIndexScans > count }
}
print("PASS injected loss/root-change flags require a fresh baseline")
controller.stopRuntime(); pump(0.3)
let saved = try db.recoveryPoint()
controller.startRuntime(); controller.stopRuntime(); pump(3)
require(try db.recoveryPoint() == saved, "Stopped runtime published late recovery")
print("PASS immediate stop cancels pending restoration")
