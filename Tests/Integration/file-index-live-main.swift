import AppKit
import CoreServices
import KeylaneCore
setbuf(stdout, nil)
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!)
let scope = base.appendingPathComponent("scope")
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
let privateScope = base.appendingPathComponent("ungranted")
try FileManager.default.createDirectory(at: privateScope, withIntermediateDirectories: false)
let ungranted = privateScope.appendingPathComponent("ungranted-fixture.txt")
let original = scope.appendingPathComponent("stale-snapshot.txt")
try Data("old snapshot".utf8).write(to: original)
let suite = "org.keylane.live-index." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path]); options.ignorePatterns = []; options.contentSearch = true
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let store = base.appendingPathComponent("index")
let controller = FileSearchController(directory: store, preferences: prefs, startImmediately: false)
let gate = DispatchSemaphore(value: 0), lock = NSLock()
let quiet = ProcessInfo.processInfo.environment["KEYLANE_VERIFY_LIVE_QUIET_ONLY"] == "1"
if quiet { controller.testQuietIndexEventID = 42 }
func injectFixtureEvents(_ items: [(URL, Int)]) {
    if quiet { controller.testIndexEvents(paths: items.map { $0.0.path }, flags: items.map { FSEventStreamEventFlags($0.1) }) }
}
var blocked = false
var rows: [SpotlightFile] = []
controller.updated = { rows = $0; _ = $1 }
func wait(_ label: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(35)
    while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition(), label + " status=" + controller.indexStatus)
}
func isBlocked() -> Bool { lock.lock(); defer { lock.unlock() }; return blocked }
controller.startRuntime()
controller.search("stale-snapshot")
wait("Warm baseline publishes before the held refresh") {
    !controller.indexing && !controller.isSearching && rows.map(\.id) == [original.path] && controller.testFullIndexScans == 1
}
precondition(quiet || controller.testHasNativeFileWatcher, "Native FSEvents unavailable in this runner; live stages were not exercised")
controller.testBeforeCommitMetadata = { path in
    if path == scope.path {
        lock.lock(); let first = !blocked; blocked = true; lock.unlock()
        if first { _ = gate.wait(timeout: .now() + 120) }
    }
}
controller.startIndex()
wait("Baseline waiting outside writer transaction") { isBlocked() }
let db = try FileSearchIndex(url: store.appendingPathComponent("index.sqlite"))
try db.transaction { _ = try db.stats() }
print("PASS metadata enumeration holds no database transaction while blocked")
let fresh = scope.appendingPathComponent("live-created.txt")
try Data("freshbodyunique fixture".utf8).write(to: fresh)
try Data("updatedbodyunique fixture".utf8).write(to: original)
try Data("ungrantedbodyunique".utf8).write(to: ungranted)
injectFixtureEvents([(ungranted,kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
                     (fresh,kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile),
                     (original,kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)])
controller.search("live-created")
wait("Created filename visible during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [fresh.path] }
controller.search("freshbodyunique")
wait("Created body available during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [fresh.path] }
controller.search("updatedbodyunique")
wait("Modified file body available during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [original.path] }
var auditOptions = options
auditOptions.roots.append(privateScope.path)
let unauthorizedName = try db.search("ungranted-fixture", options: auditOptions)
let unauthorizedBody = try db.search("ungrantedbodyunique", options: auditOptions)
precondition(unauthorizedName.isEmpty && unauthorizedBody.isEmpty, "A batched event must not certify an ungranted path")
print("PASS \(quiet ? "injected production event pipeline" : "real FSEvents") publishes authorized live changes while baseline metadata is blocked")
let nested = scope.appendingPathComponent("live-folder/nested")
try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
let nestedFile = nested.appendingPathComponent("nested-file.txt")
try Data("nestedbodyunique fixture".utf8).write(to: nestedFile)
injectFixtureEvents([(nested.deletingLastPathComponent(),kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)])
controller.search("nestedbodyunique")
wait("New nested folder is searchable during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [nestedFile.path] }
print("PASS newly created nested folders are patched during a blocked baseline")
let renamed = scope.appendingPathComponent("live-renamed.txt")
try FileManager.default.moveItem(at: fresh, to: renamed)
try FileManager.default.removeItem(at: original)
controller.refreshAfterFileAction(original, removed: true)
injectFixtureEvents([(fresh,kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile),
                     (renamed,kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile),
                     (original,kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)])
controller.search("live-renamed")
wait("Renamed filename visible during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [renamed.path] }
wait("Removed names disappear before baseline resumes") {
    (try? db.search("stale-snapshot", options: options).isEmpty) == true && (try? db.search("live-created", options: options).isEmpty) == true
}
gate.signal()
wait("Baseline and retained dirty paths finish") { !controller.indexing && !controller.isSearching }
controller.search("freshbodyunique")
wait("Baseline cleanup preserves event epoch") { !controller.indexing && !controller.isSearching && rows.map(\.id) == [renamed.path] }
precondition(try! db.search("stale-snapshot", options: options).isEmpty)
precondition(try! db.search("live-created", options: options).isEmpty)
print("PASS rename/delete stay applied after baseline resumes; stale records cannot overwrite live updates")
controller.stopRuntime()
// Outside-scope volume changes must not rescan all configured roots. Global
// dropped-event signals still need conservative recovery regardless of their path.
let volumeScope = base.appendingPathComponent("volume-scope")
try FileManager.default.createDirectory(at: volumeScope, withIntermediateDirectories: true)
try Data().write(to: volumeScope.appendingPathComponent("sentinel.txt"))
var volumeOptions = options; volumeOptions.roots = [volumeScope.path]; volumeOptions.contentSearch = false
let volumePrefs = UserDefaults(suiteName: suite + ".volume")!
defer { volumePrefs.removePersistentDomain(forName: suite + ".volume") }
volumePrefs.set(try JSONEncoder().encode(volumeOptions), forKey: "fileSearchOptions")
volumePrefs.set(volumeOptions.roots, forKey: "fileSearchSelectedScopes")
let volumes = FileSearchController(directory: base.appendingPathComponent("volume-index"), preferences: volumePrefs, startImmediately: false)
var visits = 0
volumes.testBeforeScanDirectory = { _ in lock.lock(); visits += 1; lock.unlock() }
func visitCount() -> Int { lock.lock(); defer { lock.unlock() }; return visits }
func waitVolume(_ label: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(35)
    while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition(), label)
}
if quiet { volumes.testQuietIndexEventID = 42 }
volumes.startRuntime()
volumes.search("sentinel")
waitVolume("Volume fixture initialized") { volumes.stats.entries == 1 && volumes.testEventPipelineIdle }
let baselineVisits = visitCount()
volumes.testIndexEvents(paths: [base.appendingPathComponent("outside-volume").path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMount)])
waitVolume("Outside mount classified") { volumes.testEventPipelineIdle }
precondition(visitCount() == baselineVisits, "Unrelated mount rebuilt the index")
volumes.testIndexEvents(paths: [volumeScope.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)])
waitVolume("Inside root change rebuilds") { visitCount() > baselineVisits && volumes.testEventPipelineIdle }
let afterScoped = visitCount()
volumes.testIndexEvents(paths: [base.appendingPathComponent("outside-volume").path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)])
waitVolume("Global event loss rebuilds") { visitCount() > afterScoped && volumes.testEventPipelineIdle }
volumes.stopRuntime()
print("PASS unrelated volume changes avoid baseline rebuild; affected root changes and global event loss still recover")
