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
let controller = FileSearchController(directory: base.appendingPathComponent("index"), preferences: prefs, startImmediately: false)
var scans: [(Bool, Int)] = []
controller.testScanCompleted = { scans.append(($0, $1)) }
func wait(_ label: String, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(30)
    while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition(), label + ": " + controller.indexStatus)
}
controller.startRuntime()
wait("baseline") { !scans.isEmpty && controller.testEventsIdle }
let before = controller.stats.entries
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
controller.testIndexEvents(paths: [folder.path], flags: [FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)])
wait("global recovery") { !scans.isEmpty && controller.testEventsIdle }
precondition(scans.contains { $0.0 }, "Actual event loss must still rebuild the baseline")
print("PASS actual dropped events retain complete baseline recovery")
controller.stopRuntime()
