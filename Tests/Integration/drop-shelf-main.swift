// Isolated executable using production shelf, menu-bar, and file-preview code.
// No Keylane services are started and the user's normal preference domain is never opened.
final class ShelfTestPromise: DropShelfReceiving {
    let name: String
    let fail: Bool
    let delay: TimeInterval
    var expectedCount: Int { 1 }
    var names: [String] { [name] }
    init(_ name: String, fail: Bool = false, delay: TimeInterval = 0.1) { self.name = name; self.fail = fail; self.delay = delay }
    func receive(at destination: URL, queue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        queue.addOperation { [self] in
            Thread.sleep(forTimeInterval: delay)
            let url = destination.appendingPathComponent(name)
            do {
                if fail { throw NSError(domain: "KeylaneSyntheticPromise", code: 1, userInfo: [NSLocalizedDescriptionKey: "synthetic promise failure"]) }
                try Data(("Synthetic " + name).utf8).write(to: url, options: .withoutOverwriting)
                reader(url, nil)
            } catch { reader(url, error) }
        }
    }
}
let _ = NSApplication.shared
NSApp.setActivationPolicy(.regular)
NSApp.finishLaunching()
setbuf(stdout, nil)
let root = ProcessInfo.processInfo.environment["KEYLANE_SHELF_FIXTURE"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Bundle.main.bundleURL.deletingLastPathComponent()
precondition(root.path.hasPrefix("/private/tmp/KeylaneDropShelf") || root.path.hasPrefix("/tmp/KeylaneDropShelf"))
let fixtures = root.appendingPathComponent("Fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
let source = fixtures.appendingPathComponent("source.txt")
if !FileManager.default.fileExists(atPath: source.path) { try Data("Keylane synthetic shelf fixture\n".utf8).write(to: source) }
let destination = root.appendingPathComponent("Destination", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
    NSColor.systemTeal.setFill(); rect.fill(); return true
}
let imageURL = fixtures.appendingPathComponent("fixture.png")
try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: imageURL)
let html = "<html><body><h1>Synthetic drag fixture</h1><p draggable='true'>Keylane synthetic text</p><a href='https://example.invalid/shelf'>Synthetic link</a><p><img src='fixture.png' width='160' height='100'></p></body></html>"
try Data(html.utf8).write(to: fixtures.appendingPathComponent("index.html"))
precondition(Bundle.main.bundleIdentifier?.hasPrefix("org.keylane.test.drop-shelf.") == true)
let preferences = UserDefaults.standard
let registry = MenuBarRegistry(preferences: preferences)
let shelves = DropShelfController(directory: root.appendingPathComponent("Storage"), preferences: preferences)
shelves.start(registry: registry)
guard let window = shelves.create() else { fatalError("Shelf startup failed: " + shelves.error) }
window.setFrameOrigin(NSPoint(x: 150, y: 240))
window.title = "Keylane Shelf — Isolated Fixtures"
if CommandLine.arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
if CommandLine.arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
func expect(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); print("PASS " + label) }
if !CommandLine.arguments.contains("--empty") {
expect(abs(window.frame.width - window.frame.height) < 1, "compact shelf is square")
expect(!window.styleMask.contains(.titled), "no standard titlebar or traffic lights")
let board = NSPasteboard(name: .init("org.keylane.test.shelf." + UUID().uuidString))
board.clearContents(); board.writeObjects([source as NSURL])
expect(window.receive(board), "named pasteboard accepts file reference")
expect(window.receive(board), "duplicate drop acknowledged")
expect(shelves.store!.shelf(window.shelfID)!.items.count == 1, "duplicate file adds no second item")
expect(FileManager.default.fileExists(atPath: source.path), "source remains in place")
board.clearContents(); board.writeObjects(["Synthetic text" as NSString])
expect(window.receive(board), "text accepted")
let png = NSPasteboardItem(); png.setData(try Data(contentsOf: imageURL), forType: .png)
board.clearContents(); board.writeObjects([png]); expect(window.receive(board), "image accepted")
let link = NSPasteboardItem(); link.setString("https://example.invalid", forType: .URL)
board.clearContents(); board.writeObjects([link]); expect(window.receive(board), "link accepted")
expect(shelves.store!.shelf(window.shelfID)!.items.count == 4, "all four kinds retained")
let reopened = try KeylaneCore.DropShelfStore(directory: root.appendingPathComponent("Storage"))
expect(reopened.shelf(window.shelfID)!.items.count == 4, "cross-instance persistence")
let moved = fixtures.appendingPathComponent("renamed.txt")
try FileManager.default.moveItem(at: source, to: moved)
window.refreshFiles()
expect(shelves.store!.shelf(window.shelfID)!.items.first!.title == "renamed.txt", "bookmark follows rename")
try FileManager.default.moveItem(at: moved, to: source)
window.refreshFiles()
func drain(_ duration: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
let promiseDelegates = [ShelfTestPromise("promise-one.txt", delay: 0.4), ShelfTestPromise("promise-two.txt", delay: 0.1)]
expect(window.receivePromises(promiseDelegates), "controlled asynchronous imports begin loading")
for _ in 0..<100 where shelves.store!.shelf(window.shelfID)!.items.count < 6 { drain(0.05) }
expect(Array(shelves.store!.shelf(window.shelfID)!.items.suffix(2)).map(\.title) == ["promise-one.txt", "promise-two.txt"], "out-of-order promises preserve source order")
let failing = ShelfTestPromise("failed.txt", fail: true)
expect(window.receivePromises([failing]), "failed import accepted asynchronously")
for _ in 0..<100 where !window.feedbackText.contains("synthetic promise failure") { drain(0.05) }
expect(window.feedbackText.contains("synthetic promise failure"), "provider failure is visible")
expect(shelves.store!.shelf(window.shelfID)!.items.count == 6, "failure adds no false file")
let slow = ShelfTestPromise("cancelled.txt", delay: 0.4)
expect(window.receivePromises([slow]), "cancelled import starts")
window.cancelImports(); drain(0.9)
expect(shelves.store!.shelf(window.shelfID)!.items.count == 6, "late cancelled callback cannot revive content")
let incoming = root.appendingPathComponent("Storage/Incoming")
expect((try? FileManager.default.contentsOfDirectory(atPath: incoming.path).isEmpty) == true, "finished and failed promise batches leave no residue")
let emptyDragShelf = shelves.createForDrag()!
let populatedDragShelf = shelves.createForDrag()!
try shelves.store!.addFile(source, to: populatedDragShelf.shelfID)
populatedDragShelf.refresh()
let manualEmptyShelf = shelves.create()!
shelves.finishDragActivation()
expect(!emptyDragShelf.isVisible, "unused drag-triggered empty shelf closes when drag ends")
expect(populatedDragShelf.isVisible, "populated drag-triggered shelf remains open")
expect(manualEmptyShelf.isVisible, "manually opened empty shelf is not auto-closed")
populatedDragShelf.close(); manualEmptyShelf.close()
window.toggleDetails()
expect(window.frame.width > window.frame.height, "expanded shelf uses the wide content layout")
window.toggleDetails()
expect(abs(window.frame.width - window.frame.height) < 1, "returning from expanded mode restores square shelf")
let managed = try shelves.store!.create()
try shelves.store!.rename(managed, title: "Manager fixture")
try shelves.store!.addText("searchable payload token", to: managed)
try shelves.store!.addFile(source, to: managed)
shelves.searchShelves("payload token")
expect(shelves.managedShelves.map(\.id) == [managed], "manager searches nested content with all query terms")
expect(shelves.selectedShelfID == managed, "manager maintains a valid selection")
shelves.toggleSelectedPin()
shelves.shelfFilter = "pinned"
expect(shelves.selectedShelf?.id == managed && shelves.selectedShelf!.pinned, "manager pin and filter update live")
shelves.renameManagedShelf(managed, title: "Renamed manager fixture")
expect(shelves.selectedShelf?.title == "Renamed manager fixture", "manager rename refreshes snapshots")
shelves.searchShelves("unmatched manager query")
expect(shelves.managedShelves.isEmpty && shelves.selectedShelfID == nil, "empty search clears stale selection")
shelves.searchShelves("")
shelves.selectedShelfID = managed
shelves.removeManagedShelf(managed)
expect(shelves.store!.shelf(managed) == nil, "manager removes the selected shelf record")
expect(FileManager.default.fileExists(atPath: source.path), "manager removal preserves source files")
shelves.shelfFilter = "all"
shelves.searchShelves("")
shelves.beginManagement("")
shelves.pendingRemoval = shelves.selectedShelf
shelves.pendingRename = shelves.selectedShelf
shelves.endManagement()
expect(!shelves.managementActive && shelves.pendingRemoval == nil && shelves.pendingRename == nil, "leaving manager clears drafts and preview activation")
print("PASS production shelf integration (synthetic pasteboard, not physical drag acceptance)")
}
print("FIXTURE_ROOT " + root.path)
if CommandLine.arguments.contains("--folder-preview") {
    try shelves.store!.remove(window.shelfID)
    for name in ["Dev", "Downloads", "Library"] {
        let folder = fixtures.appendingPathComponent("FolderSamples/" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try shelves.store!.addFile(folder, to: window.shelfID)
    }
    window.refresh()
}
if CommandLine.arguments.contains("--manager-preview") {
    precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == root.appendingPathComponent("home").resolvingSymlinksInPath(), "manager fixture requires its isolated home")
    let previewDelegate = Delegate()
    let previewModel = previewDelegate.model
    NSApp.delegate = previewDelegate
    previewModel.dropShelf.start(registry: previewModel.menuBar)
    guard let managerStore = previewModel.dropShelf.store else { fatalError(previewModel.dropShelf.error) }
    for old in managerStore.shelves { try managerStore.deleteShelf(old.id) }
    let designShelf = try managerStore.create()
    try managerStore.rename(designShelf, title: "设计素材")
    try managerStore.addFile(imageURL, to: designShelf)
    try managerStore.pin(designShelf, value: true)
    let documentShelf = try managerStore.create()
    try managerStore.rename(documentShelf, title: "本周资料")
    try managerStore.addText("页面草稿与待整理的资料", to: documentShelf)
    try managerStore.addText("https://example.invalid/reference", link: true, to: documentShelf)
    previewModel.runCommand(.init(rawValue: "drop-shelf-history"), origin: .search)
    expect(previewModel.pageID == PageID(rawValue: "DropShelfHistory"), "registered manager command opens Launcher page")
    let previewWindow = LauncherPanel(contentRect: NSRect(x: 100, y: 100, width: 760, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
    previewDelegate.window = previewWindow
    previewWindow.title = "Keylane Shelf Manager — Isolated Preview"
    previewWindow.isOpaque = false; previewWindow.backgroundColor = .clear
    let glass = NSGlassEffectView(); glass.style = .regular; glass.cornerRadius = 28
    let hosted = NSHostingView(rootView: Launcher(model: previewModel))
    glass.contentView = hosted; previewWindow.contentView = glass
    previewWindow.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    NotificationCenter.default.post(name: .launcherShown, object: nil)
    for mode in ["dark", "light"] {
        previewModel.appearance = mode
        previewWindow.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosted.layoutSubtreeIfNeeded()
        guard let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) else { fatalError("manager snapshot allocation") }
        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
        var visibleSamples = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 25)) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 25)) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { visibleSamples += 1 }
            }
        }
        expect(visibleSamples > 5, "Launcher manager snapshot contains visible content")
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("manager-" + mode + ".png"))

    }
    withExtendedLifetime(previewDelegate) { print("PASS registered Launcher manager mounted in light and dark appearance (visual QA separate)") }
    if CommandLine.arguments.contains("--manager-interactive") {
        previewModel.appearance = "dark"
        previewWindow.appearance = NSAppearance(named: .darkAqua)
        previewWindow.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        NSApp.run()
    }
    previewWindow.close(); previewModel.dropShelf.stop(); previewModel.menuBar.shutdown(); NSApp.delegate = nil
}
if CommandLine.arguments.contains("--image-preview") {
    try shelves.store!.remove(window.shelfID)
    try shelves.store!.addFile(imageURL, to: window.shelfID)
    window.refresh()
}
if CommandLine.arguments.contains("--interactive") {
    NSApp.run()
} else {
    window.close(); shelves.stop(); registry.shutdown()
}
