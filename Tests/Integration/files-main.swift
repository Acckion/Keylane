import Foundation
import AppKit
import KeylaneCore
import UniformTypeIdentifiers

let app = NSApplication.shared
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!)
let scope = root.appendingPathComponent("scope")
try FileManager.default.createDirectory(at:scope,withIntermediateDirectories:true)
var pageBox = CGRect(x:0,y:0,width:612,height:792)
let pdf = CGContext(scope.appendingPathComponent("作业-2.pdf") as CFURL, mediaBox:&pageBox,nil)!
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:pdf,flipped:false)
("PDF DOCUMENT NEEDLE" as NSString).draw(at:CGPoint(x:30,y:500),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.black])
NSGraphicsContext.restoreGraphicsState(); pdf.endPDFPage(); pdf.closePDF()
try Data("LOCAL CONTENT NEEDLE".utf8).write(to:scope.appendingPathComponent("报告 预算2026.txt"))
try Data("*.log\n!keep.log\n".utf8).write(to:scope.appendingPathComponent(".gitignore"))
try Data("ignored".utf8).write(to:scope.appendingPathComponent("skip.log"))
try Data("kept".utf8).write(to:scope.appendingPathComponent("keep.log"))
try Data("hidden".utf8).write(to:scope.appendingPathComponent(".隐藏文件.txt"))
let wideDirectory = scope.appendingPathComponent("wide", isDirectory: true)
try FileManager.default.createDirectory(at: wideDirectory, withIntermediateDirectories: false)
for index in 0..<130 {
    try Data("batch fixture".utf8).write(to: wideDirectory.appendingPathComponent("batch-fixture-\(index).txt"))
}
let suite = "org.keylane.file-integration." + UUID().uuidString
let prefs = UserDefaults(suiteName:suite)!
let excluded = scope.appendingPathComponent("already-excluded", isDirectory: true)
try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: false)
let exclusion = AutomaticFileExclusion(path: excluded.path, reason: "fixture", events: 0)
prefs.set(try JSONEncoder().encode([exclusion]), forKey: "fileSearchAutomaticExclusions")
let localScope = root.appendingPathComponent("always-available", isDirectory: true)
try FileManager.default.createDirectory(at: localScope, withIntermediateDirectories: false)
prefs.set([scope.path, localScope.path], forKey: "fileSearchSelectedScopes")
defer { prefs.removePersistentDomain(forName:suite) }
var config = FileSearchOptions(roots:[scope.path]); config.ignorePatterns = ["*.tmp"]
let controller = FileSearchController(directory:root.appendingPathComponent("index"),preferences:prefs,defaultOptions:config,watchChanges:true)
var results: [SpotlightFile] = []
var recordsRefresh = false; var emptyFrames = 0; var repeatedRefreshes = 0
controller.updated = { rows,_ in results = rows; if recordsRefresh { repeatedRefreshes += 1; if rows.isEmpty { emptyFrames += 1 } } }
func wait(_ label: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(35)
    while !condition(), Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
    precondition(condition(),label + " status=" + controller.indexStatus)
}
controller.search("")
precondition(!controller.indexing, "Opening an empty search should not start a full scan")
controller.search("batch-fixture")
wait("Wide directory across index batches") { !controller.indexing && results.count == 130 }
controller.search("作业")
wait("Chinese filename") { !controller.indexing && results.contains { $0.name == "作业-2.pdf" } }
precondition(results.first(where: { $0.name == "作业-2.pdf" })?.contentType?.conforms(to: .pdf) == true,
             "Published search results must carry the type used by the UI filter")
let directory = scope.appendingPathComponent("keylane-filter-folder.pdf", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
controller.search("keylane-filter-folder")
wait("Folder metadata") { results.first?.isDirectory == true }
controller.search("作业")
wait("Restore original query") { !controller.isSearching && results.first?.name == "作业-2.pdf" }
recordsRefresh = true
controller.search("作业"); controller.search("作业")
controller.startIndex(); wait("Stable index refresh") { !controller.indexing }
RunLoop.current.run(until:Date().addingTimeInterval(0.2))
precondition(emptyFrames == 0 && repeatedRefreshes == 0,"Unchanged query must not clear or republish the list")
controller.search("不存在A"); controller.search("不存在B"); controller.search("作业")
RunLoop.current.run(until:Date().addingTimeInterval(0.3))
precondition(emptyFrames == 0 && results.first?.name == "作业-2.pdf")
recordsRefresh = false
controller.options.searchFromLauncher = true
precondition(!controller.indexing,"Launcher setting must not trigger a full index rebuild")
precondition(try! JSONDecoder().decode(FileSearchOptions.self,from:prefs.data(forKey:"fileSearchOptions")!).searchFromLauncher)
controller.search("预算 报告")
wait("Multiple Chinese words") { results.count == 1 && results.first?.name == "报告 预算2026.txt" }
controller.search("skip.log"); RunLoop.current.run(until:Date().addingTimeInterval(0.2)); precondition(results.isEmpty)
controller.search("keep.log"); wait("Ignore negation") { results.first?.name == "keep.log" }
controller.search("LOCAL CONTENT"); RunLoop.current.run(until:Date().addingTimeInterval(0.2)); precondition(results.isEmpty)
controller.options.contentSearch = true
wait("Opt-in content index") { !controller.indexing && results.first?.name == "报告 预算2026.txt" }
controller.search("PDF DOCUMENT NEEDLE"); wait("PDF text extraction") { results.first?.name == "作业-2.pdf" }
controller.search("PDF DOCUMENT NEEDLE", includeContents: false)
wait("Same query restricted to file names") { !controller.isSearching && results.isEmpty }
precondition(controller.options.contentSearch && !controller.indexing)
controller.search("PDF DOCUMENT NEEDLE")
wait("Dedicated file search can still use indexed content") { results.first?.name == "作业-2.pdf" }
controller.options.includeHidden = true
wait("Hidden index scan") { !controller.indexing }
controller.search("隐藏文件"); wait("Hidden name search") { results.first?.name == ".隐藏文件.txt" }
controller.options.useIgnoreFiles = false
wait("Ignore setting update") { !controller.indexing }
controller.search("skip.log"); wait("Ignore disabled") { results.first?.name == "skip.log" }
// A record outside the changed path remains untouched. A full sweep would remove it.
let index = try FileSearchIndex(url: root.appendingPathComponent("index/index.sqlite"))
let sentinel = scope.appendingPathComponent("sentinel-unvisited.txt").path
try index.put(.init(path: sentinel, name: "sentinel-unvisited.txt", volume: "/", modified: 0,
                    directory: false, symlink: false), root: scope.path, epoch: "fixture")
let added = scope.appendingPathComponent("实时新增文件.txt")
let renamed = scope.appendingPathComponent("实时重命名文件.txt")
try Data("event fixture".utf8).write(to: added)
controller.search("实时")
wait("FSEvents refresh") { results.contains { $0.url == added } }
precondition(try! index.search("sentinel", options: controller.options).first?.id == sentinel)
try FileManager.default.moveItem(at: added, to: renamed)
wait("FSEvents rename reconciles both paths") { results.map(\.url) == [renamed] }
try FileManager.default.removeItem(at: renamed)
wait("FSEvents deletion removes stale row") { results.isEmpty }
let events = controller.automaticExclusions.first { $0.path == excluded.path }?.events ?? 0
try Data("ignored event".utf8).write(to: excluded.appendingPathComponent("ignored.txt"))
wait("FSEvents reports excluded change") {
    (controller.automaticExclusions.first { $0.path == excluded.path }?.events ?? 0) > events
}
RunLoop.current.run(until: Date().addingTimeInterval(2.5))
let untouched = try index.search("sentinel", options: controller.options)
precondition(untouched.first?.id == sentinel, "An already excluded path must not trigger a full sweep")
let stats = controller.stats
precondition(stats.entries > 0 && stats.files > 0 && stats.bytes > 0)
let disconnected = root.appendingPathComponent("disconnected", isDirectory: true)
try FileManager.default.moveItem(at: scope, to: disconnected)
controller.options.enabled = false
controller.options.roots = [scope.path, localScope.path]
precondition(controller.hasAuthorizedScope, "The readable scope must allow re-enabling file search")
controller.applyPermissionEnabled(true)
precondition(controller.options.enabled && controller.options.roots == [scope.path, localScope.path],
             "Enabling must retain configured scopes on disconnected volumes")
let savedOptions = try JSONDecoder().decode(FileSearchOptions.self, from: prefs.data(forKey: "fileSearchOptions")!)
precondition(savedOptions.roots == [scope.path, localScope.path], "Disconnected scope must remain in saved options")
wait("Disconnected retention scan") { !controller.indexing }
controller.search("作业"); wait("Keep offline record") { results.first?.name == "作业-2.pdf" }
try FileManager.default.moveItem(at: disconnected, to: scope)
let reconnected = scope.appendingPathComponent("reconnected-fixture.txt")
try Data("reconnected scope".utf8).write(to: reconnected)
controller.startIndex()
controller.search("reconnected-fixture")
wait("Reconnected scope indexed without selecting it again") { !controller.indexing && results.first?.id == reconnected.path }
try FileManager.default.moveItem(at: scope, to: disconnected)
controller.options.keepRemovedVolumes = false
wait("Remove offline records") { !controller.indexing && controller.stats.entries == 0 }
precondition(controller.options.roots == [scope.path, localScope.path], "Removing offline records must keep configured scopes")
var blockedOptions = config; blockedOptions.enforceDiskSpace = true
let blocked = FileSearchController(directory:root.appendingPathComponent("blocked-index"),preferences:UserDefaults(suiteName:suite+".blocked")!,defaultOptions:blockedOptions,watchChanges:false,availableCapacity:{ _ in 0 })
// Restore a live synthetic scope so the low-space branch is reached.
try FileManager.default.createDirectory(at:scope,withIntermediateDirectories:true)
try Data("capacity check".utf8).write(to:scope.appendingPathComponent("capacity.txt"))
blocked.startIndex(); wait("Low capacity blocks writes") { !blocked.indexing && blocked.indexStatus.contains("空间不足") }
precondition(blocked.stats.entries == 0)
UserDefaults(suiteName:suite+".blocked")!.removePersistentDomain(forName:suite+".blocked")
controller.options.keepRemovedVolumes = true
wait("Reopened file scope") { !controller.indexing }
controller.search("capacity")
wait("Existing file before runtime stop") { results.first?.name == "capacity.txt" }
controller.stopRuntime()
precondition(!controller.isRunning && !controller.indexing && results.isEmpty && controller.options.enabled)
let resumed = scope.appendingPathComponent("runtime-restored.txt")
try Data("file created while disabled".utf8).write(to: resumed)
RunLoop.current.run(until: Date().addingTimeInterval(1))
precondition(results.isEmpty && !controller.indexing && controller.options.roots.contains(scope.path))
controller.startRuntime()
controller.startIndex()
controller.search("runtime-restored")
wait("File changed while disabled appears after restart") { !controller.indexing && results.first?.id == resumed.path }
controller.stopRuntime()
blocked.stopRuntime()
print("PASS file controller: stable refresh/no empty frames, stale-query cancellation, launcher preference, Chinese filename, multiple keywords, ignore/negation, opt-in text/PDF content, low-space pause, hidden files, ignore toggle, FSEvents refresh, real stats, offline retention/removal")
