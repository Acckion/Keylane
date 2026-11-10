import Foundation
import AppKit
import KeylaneCore

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
let suite = "org.keylane.file-integration." + UUID().uuidString
let prefs = UserDefaults(suiteName:suite)!
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
controller.search("作业")
wait("Chinese filename") { !controller.indexing && results.contains { $0.name == "作业-2.pdf" } }
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
controller.options.includeHidden = true
wait("Hidden index scan") { !controller.indexing }
controller.search("隐藏文件"); wait("Hidden name search") { results.first?.name == ".隐藏文件.txt" }
controller.options.useIgnoreFiles = false
wait("Ignore setting update") { !controller.indexing }
controller.search("skip.log"); wait("Ignore disabled") { results.first?.name == "skip.log" }
// Actual FSEvents refresh, not a manual reindex after the file is created.
try Data("event fixture".utf8).write(to:scope.appendingPathComponent("实时新增文件.txt"))
controller.search("实时新增")
wait("FSEvents refresh") { results.contains { $0.name == "实时新增文件.txt" } }
let stats = controller.stats
precondition(stats.entries > 0 && stats.files > 0 && stats.bytes > 0)
try FileManager.default.moveItem(at:scope,to:root.appendingPathComponent("disconnected"))
controller.startIndex(); wait("Disconnected retention scan") { !controller.indexing }
controller.search("作业"); wait("Keep offline record") { results.first?.name == "作业-2.pdf" }
controller.options.keepRemovedVolumes = false
wait("Remove offline records") { !controller.indexing && controller.stats.entries == 0 }
var blockedOptions = config; blockedOptions.enforceDiskSpace = true
let blocked = FileSearchController(directory:root.appendingPathComponent("blocked-index"),preferences:UserDefaults(suiteName:suite+".blocked")!,defaultOptions:blockedOptions,watchChanges:false,availableCapacity:{ _ in 0 })
// Restore a live synthetic scope so the low-space branch is reached.
try FileManager.default.createDirectory(at:scope,withIntermediateDirectories:true)
try Data("capacity check".utf8).write(to:scope.appendingPathComponent("capacity.txt"))
blocked.startIndex(); wait("Low capacity blocks writes") { !blocked.indexing && blocked.indexStatus.contains("空间不足") }
precondition(blocked.stats.entries == 0)
UserDefaults(suiteName:suite+".blocked")!.removePersistentDomain(forName:suite+".blocked")
controller.options.enabled = false; blocked.options.enabled = false
print("PASS file controller: stable refresh/no empty frames, stale-query cancellation, launcher preference, Chinese filename, multiple keywords, ignore/negation, opt-in text/PDF content, low-space pause, hidden files, ignore toggle, FSEvents refresh, real stats, offline retention/removal")
