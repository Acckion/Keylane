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
func require(_ value: Bool, _ message: String) { precondition(value, message) }
func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func wait(_ label: String, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(40)
    while try !condition(), Date() < deadline { pump(0.04) }
    require(try condition(), "\(label): \(controller.indexStatus)")
}
func contains(_ name: String) throws -> Bool { try db.search(name, options: options).contains { $0.name == name } }
try wait("Initial complete baseline") { try db.recoveryPoint() != nil && !controller.indexing }
print("MEASURE initial 2000-file baseline CPU seconds=\(cpuSeconds() - coldCPU), scan seconds=\(controller.stats.seconds)")
pump(7)
controller.stopRuntime(); pump(0.3)
let sentinel = quiet.appendingPathComponent("scan-sentinel.txt")
func insertSentinel() throws {
    try db.put(.init(path: sentinel.path, name: sentinel.lastPathComponent, volume: "/", modified: 1,
                     directory: false, symlink: false), root: quiet.path, epoch: "sentinel")
}
try insertSentinel()
for round in 1...3 {
    let startCPU = cpuSeconds()
    controller = FileSearchController(directory: store, preferences: prefs)
    try wait("Warm idle restoration") { controller.indexStatus == "索引已恢复" }
    require(try contains(sentinel.lastPathComponent), "Warm idle startup crawled scope")
    print("MEASURE warm round=\(round) CPU seconds=\(cpuSeconds() - startCPU)")
    controller.stopRuntime(); pump(0.3)
}
require(try contains(sentinel.lastPathComponent), "Sentinel insertion failed")
let warmStart = Date()
controller = FileSearchController(directory: store, preferences: prefs)
// A query arriving before the database opens must not force a full crawl.
controller.search("fixture")
try wait("Warm restoration") { controller.indexStatus == "索引已恢复" }
pump(3)
require(try contains(sentinel.lastPathComponent), "Warm startup performed a full scan")
print("PASS warm startup reused baseline, early query did not crawl: \(Date().timeIntervalSince(warmStart))s")
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
controller = FileSearchController(directory: store, preferences: prefs)
try wait("Offline add/delete/rename replay") {
    try !controller.indexing && contains(added.lastPathComponent) && contains(renamed.lastPathComponent)
        && !contains(removed.lastPathComponent) && !contains("fixture-1.txt")
}
require(try contains(sentinel.lastPathComponent), "Offline replay crawled unrelated root")
try wait("Historical build directory replay") { try db.search("history-fixture", options: options).count == 140 && !controller.indexing }
require(!controller.automaticExclusions.contains { $0.path == build.path }, "Historical events were treated as a live churn burst")
print("PASS historical burst remains searchable")
print("PASS real FSEvents restart replay: add, delete, rename, unrelated root retained")
controller.stopRuntime(); pump(0.3)
// A missing checkpoint models interruption after invalidation and before commit.
try db.invalidateRecoveryPoint()
controller = FileSearchController(directory: store, preferences: prefs)
try wait("Interrupted baseline fallback") { try !controller.indexing && db.recoveryPoint() != nil && !contains(sentinel.lastPathComponent) }
print("PASS interrupted scan requires a full baseline")
controller.stopRuntime(); pump(0.3)
try insertSentinel()
options.ignorePatterns.append("offline-added.txt")
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
controller = FileSearchController(directory: store, preferences: prefs)
try wait("Changed rules fallback") { try !controller.indexing && db.recoveryPoint() != nil && !contains(sentinel.lastPathComponent) }
require(try !contains(added.lastPathComponent), "Changed exclusions retained stale row")
print("PASS changed configuration rebuilds baseline and removes excluded rows")
controller.stopRuntime(); pump(0.3)
try insertSentinel()
// Losing authorization changes the fingerprint even when saved options do not.
let previousAuthorization = try db.recoveryPoint()
prefs.set([scope.path], forKey: "fileSearchSelectedScopes")
controller = FileSearchController(directory: store, preferences: prefs)
try wait("Authorization change baseline") { try !controller.indexing && db.recoveryPoint() != nil && db.recoveryPoint() != previousAuthorization }
controller.stopRuntime(); pump(0.3)
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
controller = FileSearchController(directory: store, preferences: prefs)
try wait("Authorization reenable baseline") { try !controller.indexing && db.recoveryPoint() != nil && !contains(sentinel.lastPathComponent) }
print("PASS authorization changes cannot reuse a stale baseline")
// A temporarily unreadable subtree must not force every other root to crawl.
let locked = scope.appendingPathComponent("locked")
try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
let lockedFile = locked.appendingPathComponent("locked-fixture.txt")
try Data().write(to: lockedFile)
try wait("Initial readable subtree") { try contains(lockedFile.lastPathComponent) && !controller.indexing }
controller.stopRuntime(); pump(0.3)
try insertSentinel()
try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
controller = FileSearchController(directory: store, preferences: prefs)
try wait("Unreadable subtree queued for repair") { try !controller.indexing && db.recoveryPoint()?.retryPaths.contains(locked.path) == true }
require(try contains(lockedFile.lastPathComponent), "Unreadable subtree lost its saved rows")
require(try contains(sentinel.lastPathComponent), "Unreadable subtree caused an unrelated root scan")
controller.stopRuntime(); pump(0.3)
controller = FileSearchController(directory: store, preferences: prefs)
pump(6)
require(try contains(sentinel.lastPathComponent), "Pending repair forced a global startup crawl")
var repairWakeScans = 0
controller.testScanCompleted = { _, _ in repairWakeScans += 1 }
controller.testIndexEvents(paths: [scope.path], flags: [FSEventStreamEventFlags(
    kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified)])
pump(3)
require(repairWakeScans == 0, "Ordinary root modification retried an unrelated unreadable subtree")
require(try db.recoveryPoint()?.retryPaths.contains(locked.path) == true, "Filtered notification lost pending repair")
print("PASS ordinary ancestor changes do not wake unresolved repairs")

try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
try FileManager.default.removeItem(at: lockedFile)
try Data().write(to: locked.appendingPathComponent("unlocked-fixture.txt"))
try wait("Permission restored subtree repair") { try !controller.indexing && db.recoveryPoint()?.retryPaths.isEmpty == true && !contains(lockedFile.lastPathComponent) && contains("unlocked-fixture.txt") }
print("PASS unreadable subtree retains rows, retries locally, and recovers after permissions return")
// Inject native recovery flags without fabricating a successful native event replay.
for flag in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
             kFSEventStreamEventFlagEventIdsWrapped, kFSEventStreamEventFlagRootChanged] {
    try insertSentinel()
    controller.testIndexEvents(paths: [scope.path], flags: [FSEventStreamEventFlags(flag)])
    try wait("Lost/wrapped/root-changed event fallback") { try !controller.indexing && !contains(sentinel.lastPathComponent) && db.recoveryPoint() != nil }
}
print("PASS injected loss/wrap/root-change flags require a fresh baseline")
controller.stopRuntime(); pump(0.3)
let saved = try db.recoveryPoint()
controller.startRuntime(); controller.stopRuntime(); pump(3)
require(try db.recoveryPoint() == saved, "Stopped runtime published late recovery")
print("PASS immediate stop cancels pending restoration")
