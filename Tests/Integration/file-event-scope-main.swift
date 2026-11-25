import AppKit
import CoreServices
import KeylaneCore
setbuf(stdout, nil)
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!)
let a = base.appendingPathComponent("scope-a"), b = base.appendingPathComponent("scope-b")
let folder = a.appendingPathComponent("folder"), nested = folder.appendingPathComponent("nested")
try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
for i in 0..<100 { try Data("fixture \(i)".utf8).write(to: nested.appendingPathComponent("item-\(i).txt")) }
let child = folder.appendingPathComponent("child.txt")
try Data("child fixture".utf8).write(to: child)
try Data("other root".utf8).write(to: b.appendingPathComponent("other.txt"))
let suite = "org.keylane.event-scope." + UUID().uuidString
let prefs = UserDefaults(suiteName: suite)!
defer { prefs.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [a.path, b.path]); options.ignorePatterns = []; options.contentSearch = false
prefs.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
prefs.set(options.roots, forKey: "fileSearchSelectedScopes")
let legacyStats = Data([42])
prefs.set(legacyStats, forKey: "fileSearchLastStats")
// One suggestion is still ungranted when the feature is enabled.
let ungranted = base.appendingPathComponent("ungranted-cloud")
try FileManager.default.createDirectory(at: ungranted, withIntermediateDirectories: false)
try Data("must stay outside index".utf8).write(to: ungranted.appendingPathComponent("not-authorized.txt"))
var suggested = options
suggested.roots.append(ungranted.path)
prefs.set(try JSONEncoder().encode(suggested), forKey: "fileSearchOptions")
let controller = FileSearchController(directory: base.appendingPathComponent("index"), preferences: prefs, startImmediately: false)
// This fixture injects flags explicitly; actual delivery is covered
// separately by file-search-live-diagnostic and file-index-live-main.
controller.testQuietIndexEventID = 42
var scans: [(Bool, Int)] = []
controller.testScanCompleted = { scans.append(($0, $1)) }
func wait(_ label: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(30)
    while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition(), label + ": " + controller.indexStatus)
}
controller.applyPermissionEnabled(true)
precondition(controller.options.roots.contains(ungranted.path), "Enabling one grant discarded a suggested root")
controller.startRuntime()
controller.search("item-")
wait("baseline") { !scans.isEmpty && controller.testEventsIdle }
let before = controller.stats.entries
precondition(before == 104, "An ungranted suggested root must not be scanned")
let dirFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemModified)
let fileFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
scans.removeAll()
controller.testIndexEvents(paths: [a.path], flags: [dirFlag])
wait("root metadata event filtered") { controller.testEventsIdle }
precondition(scans.isEmpty, "Root metadata must not expand into a root traversal")
print("PASS ordinary root metadata creates no scan")
controller.testIndexEvents(paths: [folder.path], flags: [dirFlag])
wait("directory metadata") { !scans.isEmpty && controller.testEventsIdle }
precondition(scans.allSatisfy { !$0.0 && $0.1 == 1 }, "Directory metadata must touch only its own record")
precondition(controller.stats.entries == before, "Descendants must survive shallow reconciliation")
print("PASS ordinary directory metadata processes one record and retains all descendants")
let inodeFlag = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemInodeMetaMod)
scans.removeAll()
controller.testIndexEvents(paths: [a.path], flags: [inodeFlag])
wait("readable root inode notification filtered") { controller.testEventsIdle }
precondition(scans.isEmpty, "A readable root's inode notification must not crawl the root")
controller.testIndexEvents(paths: [folder.path], flags: [inodeFlag])
wait("directory inode notification") { !scans.isEmpty && controller.testEventsIdle }
precondition(scans.count == 1 && !scans[0].0 && scans[0].1 == 1, "Directory inode notification must only update the directory row")
precondition(controller.stats.entries == before, "Inode-only reconciliation must preserve descendants")
print("PASS directory inode notifications read one entry and never expand a readable root")
scans.removeAll()
controller.testIndexEvents(paths: [folder.path, child.path, child.path], flags: [dirFlag, fileFlag, fileFlag])
wait("parent and child") { !scans.isEmpty && controller.testEventsIdle }
precondition(scans.count == 1 && scans[0].1 == 2 && !scans[0].0, "Shallow parent must not swallow child; duplicate child must coalesce")
precondition(controller.testLastScanRuleReads == 2, "Sibling targets must reuse ancestor rule snapshots")
print("PASS shallow parent retains explicit child update and duplicate events coalesce")
scans.removeAll()
controller.testIndexEvents(paths: [folder.appendingPathComponent(".rayignore").path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemIsFile)])
wait("ignore-rule removal") { !scans.isEmpty && controller.testEventsIdle }
precondition(scans.allSatisfy { !$0.0 && $0.1 == 103 }, "Rule changes must rescan their directory, not all roots")
print("PASS ignore-rule removal recursively reconciles only its directory")
scans.removeAll()
controller.testIndexEvents(paths: [folder.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagItemIsDir)])
wait("subtree recovery") { !scans.isEmpty && controller.testEventsIdle }
precondition(scans.allSatisfy { !$0.0 && $0.1 == 103 }, "MustScan must reconcile its subtree, not all roots")
precondition(controller.stats.entries == before)
print("PASS scoped MustScan reconciles only the affected subtree")
scans.removeAll()
controller.testIndexEvents(paths: [folder.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsDir)])
wait("directory rename notification") { !scans.isEmpty && controller.testEventsIdle }
precondition(scans.count == 1 && !scans[0].0 && scans[0].1 == 103, "Directory rename must still reconcile its descendants")
print("PASS directory rename keeps recursive reconciliation")
scans.removeAll()
controller.testIndexEvents(paths: [folder.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)])
wait("global recovery") { !scans.isEmpty && controller.testEventsIdle }
precondition(scans.contains { $0.0 }, "Actual event loss must still rebuild the baseline")
print("PASS actual dropped events retain complete baseline recovery")
// Drive the production scheduler against a fixture in place of ~/Library.
controller.testRoutineLibraryPath = a.path
let biome = a.appendingPathComponent("Biome")
try FileManager.default.createDirectory(at: biome, withIntermediateDirectories: false)
let daemonFile = biome.appendingPathComponent("telemetry.db-shm")
try Data("diagnostic fixture".utf8).write(to: daemonFile)
scans.removeAll()
controller.testIndexEvents(paths: [daemonFile.path], flags: [fileFlag])
wait("maintenance deferred") { controller.testRefreshIsDeferred }
let beforeUrgent = Date()
RunLoop.current.run(until: beforeUrgent.addingTimeInterval(2.2))
precondition(scans.isEmpty && controller.testRefreshIsDeferred, "Routine service traffic must not scan at the ordinary deadline")
controller.testIndexEvents(paths: [child.path], flags: [fileFlag])
wait("ordinary event pulls deferred items forward") { !scans.isEmpty && controller.testEventsIdle }
precondition(Date().timeIntervalSince(beforeUrgent) < 12, "Ordinary event waited for the maintenance deadline")
precondition(scans.contains { !$0.0 && $0.1 >= 2 }, "Ordinary event lost deferred targets")
precondition(prefs.data(forKey: "fileSearchLastStats") == legacyStats, "Index scans wrote back to watched preferences")
print("PASS routine service events batch, ordinary changes preempt, and per-scan preferences stay unchanged")
controller.stopRuntime()
