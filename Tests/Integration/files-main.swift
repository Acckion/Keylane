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
let mixedContent = scope.appendingPathComponent("预算-fixture.md")
let nameOnly = scope.appendingPathComponent("预算 季度材料.txt")
let contentOnly = scope.appendingPathComponent("synopsis.txt")
try Data("季度材料 and English body".utf8).write(to: mixedContent)
try Data().write(to: nameOnly)
try Data("预算和季度材料".utf8).write(to: contentOnly)
try Data([0xff, 0xfe, 0x00] + Array("invalidbodyfixture".utf8)).write(to: scope.appendingPathComponent("invalid.txt"))
try Data("unknownformatfixture".utf8).write(to: scope.appendingPathComponent("unknown.docx"))
try Data("invalidpdffixture".utf8).write(to: scope.appendingPathComponent("invalid.pdf"))
let limitText = "boundaryheadfixture" + String(repeating: "x", count: 100_000 - "boundaryheadfixture".count) + "boundarytailfixture"
try Data(limitText.utf8).write(to: scope.appendingPathComponent("long-body.txt"))
var maxSize = Data("bytelimitfixture".utf8)
maxSize.append(Data(repeating: 0x78, count: 2_097_152 - maxSize.count))
try maxSize.write(to: scope.appendingPathComponent("max-bytes.txt"))
maxSize.append(0x78)
try maxSize.write(to: scope.appendingPathComponent("oversized.txt"))
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
var resultStatus = ""
var recordsRefresh = false; var emptyFrames = 0; var repeatedRefreshes = 0
controller.updated = { rows,status in results = rows; resultStatus = status; if recordsRefresh { repeatedRefreshes += 1; if rows.isEmpty { emptyFrames += 1 } } }
func wait(_ label: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(35)
    while !condition(), Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.03)) }
    precondition(condition(), label + " status=" + controller.indexStatus + " results=" + results.map(\.id).description + " detail=" + resultStatus)
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
controller.search("预算 季度材料")
wait("Chinese name, body and mixed matches") { !controller.isSearching && results.count == 3 }
precondition(results.first?.id == nameOnly.path)
precondition(Set(results.filter(\.matchesContent).map(\.id)) == [mixedContent.path, contentOnly.path])
controller.search("预算 季度材料", includeContents: false)
wait("No content markers when searching names") { !controller.isSearching && results.map(\.id) == [nameOnly.path] }
precondition(results.first?.matchesContent == false)
controller.search("English body")
controller.search("bytelimitfixture")
wait("Latest query supersedes earlier content search") { !controller.isSearching && results.map(\.name) == ["max-bytes.txt"] }
for query in ["boundarytailfixture", "invalidbodyfixture", "unknownformatfixture", "invalidpdffixture"] {
    controller.search(query)
    wait("Unsupported body: \(query)") { !controller.isSearching && results.isEmpty }
}
controller.search("boundaryheadfixture")
wait("Text before the character cap") { !controller.isSearching && results.first?.name == "long-body.txt" }
controller.search("oversized")
wait("Oversized files retain searchable names") { !controller.isSearching && results.first?.name == "oversized.txt" }
precondition(results.first?.matchesContent == false)
controller.search("English body")
controller.cancel()
let cancelledQuery = controller.lastPublishedQuery
RunLoop.current.run(until: Date().addingTimeInterval(0.2))
precondition(!controller.isSearching && controller.lastPublishedQuery == cancelledQuery)
controller.search("English body")
wait("Repeat a cancelled content query") { !controller.isSearching && results.first?.id == mixedContent.path }
precondition(results.first?.matchesContent == true)
controller.setIndexPaused(true)
wait("Pause updates current result without editing query") { resultStatus.contains("已暂停") }
controller.search("PDF DOCUMENT NEEDLE")
wait("Paused index still finds PDF") { !controller.isSearching && results.first?.name == "作业-2.pdf" }
precondition(resultStatus.contains("已暂停"), "Paused search must describe its coverage: " + resultStatus)
controller.search("missing-content-fixture")
wait("Paused index reports a miss") { !controller.isSearching && results.isEmpty }
precondition(resultStatus.contains("已暂停"), "Paused misses must describe their coverage: " + resultStatus)
controller.options.contentSearch = false
controller.search("PDF DOCUMENT NEEDLE")
wait("Content is disabled while index is paused") { !controller.isSearching && results.isEmpty }
controller.options.contentSearch = true
controller.setIndexPaused(false)
wait("Resuming re-extracts bodies cleared while paused") {
    !controller.indexing && !resultStatus.contains("已暂停") && results.first?.name == "作业-2.pdf"
}
precondition(results.first?.matchesContent == true)
print("PASS body-only and mixed hits, UTF-8 and PDF boundaries, query cancellation, and body re-extraction after pause")
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
controller.options.useIgnoreFiles = true
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
let blockedPreferences = UserDefaults(suiteName:suite+".blocked")!
blockedPreferences.set([scope.path], forKey: "fileSearchSelectedScopes")
let blocked = FileSearchController(directory:root.appendingPathComponent("blocked-index"),preferences:blockedPreferences,defaultOptions:blockedOptions,watchChanges:false,availableCapacity:{ _ in 0 })
// Restore a live synthetic scope so the low-space branch is reached.
try FileManager.default.createDirectory(at:scope,withIntermediateDirectories:true)
try Data("capacity check".utf8).write(to:scope.appendingPathComponent("capacity.txt"))
var blockedStatus = ""
blocked.updated = { _, status in blockedStatus = status }
blocked.search("capacity check")
blocked.startIndex(); wait("Low capacity blocks writes") { !blocked.indexing && blocked.indexStatus.contains("空间不足") }
wait("Search reports the low-space index failure") { blockedStatus.contains("空间不足") }
precondition(blocked.stats.entries == 0)
UserDefaults(suiteName:suite+".blocked")!.removePersistentDomain(forName:suite+".blocked")
controller.options.keepRemovedVolumes = true
wait("Reopened file scope") { !controller.indexing }
controller.search("capacity")
wait("Existing file before runtime stop") { results.first?.name == "capacity.txt" }
controller.options.includeHidden = false
controller.options.useIgnoreFiles = true
wait("Restore ignore rules before browsing") { !controller.indexing }
let browse = scope.appendingPathComponent("目录 [测试]", isDirectory: true)
try FileManager.default.createDirectory(at: browse, withIntermediateDirectories: false)
let special = browse.appendingPathComponent("A [预算]*?.txt")
let newer = browse.appendingPathComponent("Z 文件.txt")
try Data("exact file".utf8).write(to: special)
try Data("newer file".utf8).write(to: newer)
try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 15_000),
                                       .modificationDate: Date(timeIntervalSince1970: 5_000)], ofItemAtPath: special.path)
try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 3_000),
                                       .modificationDate: Date(timeIntervalSince1970: 10_000)], ofItemAtPath: newer.path)
try Data("skip-*.txt\n".utf8).write(to: browse.appendingPathComponent(".rayignore"))
try Data().write(to: browse.appendingPathComponent("skip-private.txt"))
let outside = root.appendingPathComponent("outside.txt")
try Data().write(to: outside)
let alias = browse.appendingPathComponent("outside-link")
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
controller.search(browse.path)
wait("Browse only authorized, nonexcluded children") { !controller.isSearching && results.map(\.id) == [special.path, newer.path] }
controller.setDirectorySort(.created)
wait("Browse creation sort") { !controller.isSearching && results.map(\.id) == [special.path, newer.path] }
controller.setDirectorySort(.modified)
wait("Browse modification sort") { !controller.isSearching && results.map(\.id) == [newer.path, special.path] }
let restoredPrefs = FileSearchController(directory: root.appendingPathComponent("unused-index"), preferences: prefs, startImmediately: false)
precondition(restoredPrefs.directorySort == .modified)
let capped = root.appendingPathComponent("capped", isDirectory: true)
try FileManager.default.createDirectory(at: capped, withIntermediateDirectories: false)
try Data("skip-*.txt\n".utf8).write(to: capped.appendingPathComponent(".rayignore"))
try Data().write(to: capped.appendingPathComponent("skip-private.txt"))
try FileManager.default.createSymbolicLink(at: capped.appendingPathComponent("0-outside.txt"), withDestinationURL: outside)
let expected = try (0..<206).map { index -> URL in
    let url = capped.appendingPathComponent(String(format: "z-%03d.txt", index))
    try Data().write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(20_000 + index))],
                                          ofItemAtPath: url.path)
    return url
}
var cappedOptions = FileSearchOptions(roots: [capped.path, scope.path])
cappedOptions.ignorePatterns = ["*.tmp"]
cappedOptions.excludedPaths = [expected[0].path, expected[205].path]
var location = FileSearchLocation(options: cappedOptions, automaticExclusions: [])
let allowed = Array(expected.dropFirst().dropLast())
let byName = try location.children(of: capped, sortedBy: .name)
let byModified = try location.children(of: capped, sortedBy: .modified)
precondition(byName.map(\.id) == allowed.prefix(200).map(\.path))
precondition(byModified.map(\.id) == allowed.reversed().prefix(200).map(\.path))
precondition((byName + byModified).allSatisfy { $0.contentType?.conforms(to: .plainText) == true })
var cancellationChecks = 0
let cancelledBrowse = try location.children(of: capped, sortedBy: .name) {
    cancellationChecks += 1
    return cancellationChecks > 12
}
precondition(cancelledBrowse.isEmpty && cancellationChecks == 13)
controller.search(special.path, standalone: false)
wait("Exact special-character path") { !controller.isSearching && results.map(\.id) == [special.path] }
controller.search(browse.path, showPathItself: true)
wait("Directory itself can be selected for detail") { !controller.isSearching && results.map(\.id) == [browse.path] }
controller.search(alias.path)
wait("Escaping symlink must not expose its target") { !controller.isSearching && results.isEmpty }
controller.search(outside.path)
wait("Outside scope") { !controller.isSearching && results.isEmpty }
controller.options.roots.append(root.path)
wait("Unapproved configured root stays unavailable") { !controller.indexing && !controller.isSearching && results.isEmpty }
controller.options.roots.removeAll { $0 == root.path }
controller.search(browse.appendingPathComponent("missing.txt").path)
wait("Missing path") { !controller.isSearching && results.isEmpty }

controller.rememberOpenedFile(try controller.inspect(special))
controller.rememberOpenedFile(try controller.inspect(newer))
controller.rememberOpenedFile(try controller.inspect(special))
controller.search("")
wait("Recents are deduplicated and ordered by successful opens") { !controller.isSearching && results.map(\.id) == [special.path, newer.path] }
precondition(prefs.stringArray(forKey: "fileSearchRecentPaths") == [special.path, newer.path])
let excludedPath = try controller.exclude(special)
wait("Exact exclusion removes recent file") { !controller.isSearching && results.map(\.id) == [newer.path] }
let storedExclusions = try JSONDecoder().decode(FileSearchOptions.self, from: prefs.data(forKey: "fileSearchOptions")!).excludedPaths
precondition(storedExclusions == [special.path])
controller.undoExclusion(excludedPath)
controller.undoExclusion(excludedPath)
wait("Undo restores the recent file") { !controller.isSearching && results.map(\.id) == [special.path, newer.path] }
controller.startIndex(force: true)
controller.search("预算")
wait("Rebuild indexes newly created files") { !controller.indexing && results.contains { $0.id == special.path } }
controller.setIndexPaused(true)
let whilePaused = browse.appendingPathComponent("new-while-paused.txt")
try Data().write(to: whilePaused)
controller.search("预算")
wait("Paused reader still has existing results") { !controller.isSearching && results.contains { $0.id == special.path } }
controller.search("new-while-paused")
wait("Pause prevents background ingestion") { !controller.isSearching && results.isEmpty }
controller.setIndexPaused(false)
wait("Resume indexes new content and refreshes active query") { !controller.indexing && results.map(\.id) == [whilePaused.path] }

let copy = try FileResultOperations.duplicate(controller.mutationTarget(special))
let secondCopy = try FileResultOperations.duplicate(controller.mutationTarget(special))
let sourceBytes = try Data(contentsOf: special)
let copyBytes = try Data(contentsOf: copy)
precondition(copy != secondCopy && copyBytes == sourceBytes)
try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: copy.path)
do {
    _ = try controller.inspect(copy)
    preconditionFailure("Unreadable files must not be used")
} catch {}
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
let oldTarget = try controller.mutationTarget(copy)
try FileManager.default.moveItem(at: copy, to: browse.appendingPathComponent("original-copy.txt"))
try Data().write(to: copy)
do {
    _ = try FileResultOperations.duplicate(oldTarget)
    preconditionFailure("A replacement file must not be copied with an old target")
} catch {}
if ProcessInfo.processInfo.environment["KEYLANE_VERIFY_FILE_TRASH"] == "1" {
    let unique = browse.appendingPathComponent("Keylane-Trash-Fixture-" + UUID().uuidString + ".txt")
    try FileManager.default.copyItem(at: secondCopy, to: unique)
    controller.startIndex()
    controller.search(unique.lastPathComponent)
    wait("Synthetic copy indexed before trash") { !controller.indexing && results.first?.id == unique.path }
    let target = try controller.mutationTarget(unique)
    // Constructing a confirmation target has no filesystem side effect when cancelled.
    precondition(FileManager.default.fileExists(atPath: unique.path))
    let trashed = try FileResultOperations.trash(target)!
    controller.refreshAfterFileAction(unique, removed: true)
    wait("Trashed file removed from active results") { !controller.isSearching && results.isEmpty }
    precondition(!FileManager.default.fileExists(atPath: unique.path))
    precondition(FileManager.default.fileExists(atPath: trashed.path) && FileManager.default.fileExists(atPath: special.path))
    try FileManager.default.moveItem(at: trashed, to: unique)
    precondition(FileManager.default.fileExists(atPath: unique.path))
    print("PASS synthetic copy moved to Trash and restored")
}
print("PASS authorized paths, folder sort persistence, recents, undo, pause/resume, duplicate and permission failures")
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
