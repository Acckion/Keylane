import AppKit
import CoreServices
import KeylaneCore
setbuf(stdout, nil)
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!)
let scope = base.appendingPathComponent("scope")
try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
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
var blocked = false
controller.testBeforeCommitMetadata = { path in
    if path == scope.path {
        lock.lock(); let first = !blocked; blocked = true; lock.unlock()
        if first { gate.wait() }
    }
}
var rows: [SpotlightFile] = []
controller.updated = { rows = $0; _ = $1 }
func wait(_ label: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(35)
    while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition(), label + " status=" + controller.indexStatus)
}
func isBlocked() -> Bool { lock.lock(); defer { lock.unlock() }; return blocked }
controller.startRuntime()
wait("Baseline waiting outside writer transaction") { isBlocked() }
let db = try FileSearchIndex(url: store.appendingPathComponent("index.sqlite"))
try db.transaction { try db.put(.init(path: scope.appendingPathComponent("writer-sentinel").path, name: "writer-sentinel", volume: "/", modified: 1, directory: false, symlink: false), root: scope.path, epoch: "n:old") }
print("PASS metadata enumeration holds no database transaction while blocked")
let fresh = scope.appendingPathComponent("live-created.txt")
try Data("freshbodyunique fixture".utf8).write(to: fresh)
try Data("updatedbodyunique fixture".utf8).write(to: original)
controller.search("live-created")
wait("Created filename visible during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [fresh.path] }
controller.search("freshbodyunique")
wait("Created body available during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [fresh.path] }
controller.search("updatedbodyunique")
wait("Modified file body available during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [original.path] }
print("PASS real FSEvents publish new/modified filenames and body while baseline metadata is blocked")
let nested = scope.appendingPathComponent("live-folder/nested")
try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
let nestedFile = nested.appendingPathComponent("nested-file.txt")
try Data("nestedbodyunique fixture".utf8).write(to: nestedFile)
controller.search("nestedbodyunique")
wait("New nested folder is searchable during baseline") { controller.indexing && !controller.isSearching && rows.map(\.id) == [nestedFile.path] }
print("PASS newly created nested folders are patched during a blocked baseline")
let renamed = scope.appendingPathComponent("live-renamed.txt")
try FileManager.default.moveItem(at: fresh, to: renamed)
try FileManager.default.removeItem(at: original)
controller.refreshAfterFileAction(original, removed: true)
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
volumes.startRuntime()
waitVolume("Volume fixture initialized") { volumes.stats.entries == 1 && volumes.testEventsIdle }
let baselineVisits = visitCount()
volumes.testIndexEvents(paths: [base.appendingPathComponent("outside-volume").path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMount)])
waitVolume("Outside mount classified") { volumes.testEventsIdle }
precondition(visitCount() == baselineVisits, "Unrelated mount rebuilt the index")
volumes.testIndexEvents(paths: [volumeScope.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)])
waitVolume("Inside root change rebuilds") { visitCount() > baselineVisits && volumes.testEventsIdle }
let afterScoped = visitCount()
volumes.testIndexEvents(paths: [base.appendingPathComponent("outside-volume").path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)])
waitVolume("Global event loss rebuilds") { visitCount() > afterScoped && volumes.testEventsIdle }
volumes.stopRuntime()
print("PASS unrelated volume changes avoid baseline rebuild; affected root changes and global event loss still recover")
