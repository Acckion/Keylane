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
for (type, data) in [(NSPasteboard.PasteboardType.png, try Data(contentsOf: imageURL)), (.tiff, image.tiffRepresentation!)] {
    let imageShelf = shelves.create()!
    let imageInput = NSPasteboardItem(); imageInput.setData(data, forType: type)
    board.clearContents(); board.writeObjects([imageInput])
    expect(imageShelf.receive(board), "image representation imported: " + type.rawValue)
    let exported = imageShelf.tableView(NSTableView(), pasteboardWriterForRow: 0) as! NSPasteboardItem
    expect(exported.string(forType: .fileURL) != nil, "image export retains Finder file URL")
    expect(exported.data(forType: type) == data, "image export preserves original typed bytes: " + type.rawValue)
    let imageOnly = NSPasteboardItem(); imageOnly.setData(exported.data(forType: type)!, forType: type)
    board.clearContents(); board.writeObjects([imageOnly])
    expect(NSImage(pasteboard: board) != nil, "image-only consumer reads shelf export: " + type.rawValue)
    imageShelf.close()
}
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
for (index, name) in ["promise-one.txt", "promise-two.txt"].enumerated() {
    let writer = window.tableView(NSTableView(), pasteboardWriterForRow: 4 + index) as! NSPasteboardItem
    let exported = URL(string: writer.string(forType: .fileURL)!)!
    expect(exported.lastPathComponent == name, "promised export URL keeps original filename: " + name)
}
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
let deletionRegistry = MenuBarRegistry(preferences: preferences)
let deletionController = DropShelfController(directory: root.appendingPathComponent("DeletionStorage"), preferences: preferences)
deletionController.start(registry: deletionRegistry)
let deletionStore = deletionController.store!
var savedHistory = Set<UUID>()
for index in 0..<10 {
    let id = try deletionStore.create()
    try deletionStore.addText("history \(index)", to: id)
    try deletionStore.remember(id)
    savedHistory.insert(id)
}
let removedWindow = deletionController.create()!
try deletionStore.addFile(source, to: removedWindow.shelfID)
removedWindow.refresh()
expect(removedWindow.receivePromises([ShelfTestPromise("removed-pending.txt", delay: 0.4)]), "open shelf deletion starts with a pending import")
deletionController.removeManagedShelf(removedWindow.shelfID)
expect(!removedWindow.isVisible && deletionStore.shelf(removedWindow.shelfID) == nil, "manager deletion closes and removes the open shelf")
expect(Set(deletionStore.shelves.map(\.id)) == savedHistory, "deleting an open populated shelf preserves all ten unrelated history records")
drain(0.9)
expect(Set(deletionStore.shelves.map(\.id)) == savedHistory, "late import cannot revive the deleted shelf or evict history")
expect((try? FileManager.default.contentsOfDirectory(atPath: deletionStore.directory.appendingPathComponent("Incoming").path).isEmpty) == true, "deleted shelf import leaves no batch residue")
expect(FileManager.default.fileExists(atPath: source.path), "deleting an open shelf preserves its external source")
let restoredDeletionStore = try KeylaneCore.DropShelfStore(directory: deletionStore.directory)
expect(Set(restoredDeletionStore.shelves.map(\.id)) == savedHistory, "all ten history records survive reload after open shelf deletion")
deletionController.stop(); deletionRegistry.shutdown()
let restrictedParent = fixtures.appendingPathComponent("Restricted", isDirectory: true)
try FileManager.default.createDirectory(at: restrictedParent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let restrictedFile = restrictedParent.appendingPathComponent("retained.txt")
try Data("permission fixture".utf8).write(to: restrictedFile)
let permissionWindow = shelves.create()!
try shelves.store!.addFile(restrictedFile, to: permissionWindow.shelfID)
try shelves.store!.pin(permissionWindow.shelfID, value: true)
permissionWindow.refresh()
let permissionItem = shelves.store!.shelf(permissionWindow.shelfID)!.items.first!
let initialPermissionFeedback = permissionWindow.feedbackText
var deniedBooleanCheck = false
var deniedInspectionCode: Int?
var retainedInaccessibleReference = false
var inaccessibleFeedback = ""
var retainedInaccessibleArchive = false
do {
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restrictedParent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restrictedParent.path) }
    deniedBooleanCheck = !FileManager.default.fileExists(atPath: restrictedFile.path)
    do { _ = try FileManager.default.attributesOfItem(atPath: restrictedFile.path) }
    catch { deniedInspectionCode = (error as NSError).code }
    permissionWindow.refreshFiles()
    retainedInaccessibleReference = shelves.store!.shelf(permissionWindow.shelfID)?.items.map(\.id) == [permissionItem.id]
    inaccessibleFeedback = permissionWindow.feedbackText
    let inaccessibleReload = try KeylaneCore.DropShelfStore(directory: root.appendingPathComponent("Storage"))
    retainedInaccessibleArchive = inaccessibleReload.shelf(permissionWindow.shelfID)?.pinned == true && inaccessibleReload.shelf(permissionWindow.shelfID)?.items.map(\.id) == [permissionItem.id]
}
// Restore permissions before assertions, including when a regression aborts this executable.
expect(deniedBooleanCheck, "permission fixture reproduces ambiguous false existence result")
expect(deniedInspectionCode == NSFileReadNoPermissionError, "error-aware check distinguishes permission denial")
expect(retainedInaccessibleReference, "permission failure retains the pinned shelf reference")
expect(inaccessibleFeedback != initialPermissionFeedback && !inaccessibleFeedback.contains("已从暂存架移除"), "permission failure reports feedback without claiming removal")
expect(retainedInaccessibleArchive, "pinned reference persists across reload while inaccessible")
permissionWindow.refreshFiles()
expect(shelves.store!.shelf(permissionWindow.shelfID)?.items.map(\.id) == [permissionItem.id], "restored permissions keep the original reference")
let recoveredData = try Data(contentsOf: shelves.store!.resolve(permissionItem)!)
expect(recoveredData == Data("permission fixture".utf8), "restored pinned file remains readable")
try FileManager.default.removeItem(at: restrictedFile)
permissionWindow.refreshFiles()
expect(shelves.store!.shelf(permissionWindow.shelfID)?.items.isEmpty == true, "definite file deletion removes only the missing reference")
expect(permissionWindow.feedbackText.contains("已从暂存架移除"), "definite deletion reports removal")
permissionWindow.close()
let transferSource = shelves.create()!
let transferDestination = shelves.create()!
let fullText = String(repeating: "sample ", count: 20) + "internal-transfer-search-token"
let fullLink = "https://example.invalid/internal-transfer-link"
try shelves.store!.addText(fullText, to: transferSource.shelfID)
try shelves.store!.addText(fullLink, link: true, to: transferSource.shelfID)
transferSource.refresh()
for row in 0..<2 {
    let writer = transferSource.tableView(NSTableView(), pasteboardWriterForRow: row) as! NSPasteboardItem
    expect(writer.string(forType: .fileURL) != nil, "internal text/link writer still supplies external file representation")
    board.clearContents(); board.writeObjects([writer])
    expect(transferDestination.receive(board), "internal text/link transfer accepted")
    expect(transferDestination.receive(board), "repeated internal transfer acknowledged")
    expect(transferSource.receive(board), "same-shelf text/link paste acknowledged as duplicate")
}
let transferred = shelves.store!.shelf(transferDestination.shelfID)!.items
expect(transferred.map(\.kind) == [.text, .link] && transferred.map(\.value) == [fullText, fullLink], "internal transfers preserve content kinds and complete values")
expect(shelves.store!.shelf(transferSource.shelfID)!.items.count == 2, "same-shelf paste creates no generated file duplicate")
for (row, value) in [fullText, fullLink].enumerated() {
    let writer = transferDestination.tableView(NSTableView(), pasteboardWriterForRow: row) as! NSPasteboardItem
    expect(writer.string(forType: .string) == value, "transferred content can be copied again as its original string")
    if row == 1 { expect(writer.string(forType: .URL) == value, "transferred link can be copied again as URL") }
}
shelves.searchShelves("internal-transfer-search-token")
expect(shelves.managedShelves.contains { $0.id == transferDestination.shelfID }, "manager searches full transferred content beyond title preview")
shelves.searchShelves("")
let transferReload = try KeylaneCore.DropShelfStore(directory: root.appendingPathComponent("Storage"))
expect(transferReload.shelf(transferDestination.shelfID)?.items.map(\.value) == [fullText, fullLink], "transferred native content persists across reload")
let externalMixed = NSPasteboardItem()
externalMixed.setString(source.absoluteString, forType: .fileURL); externalMixed.setString("external description", forType: .string)
board.clearContents(); board.writeObjects([externalMixed])
expect(transferDestination.receive(board), "external mixed representation accepted")
expect(shelves.store!.shelf(transferDestination.shelfID)?.items.last?.kind == .file, "external mixed input still prefers its file URL")
transferSource.close(); transferDestination.close()

func descendantViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendantViews) }
let gridWindow = shelves.create()!
for name in ["first", "second", "third"] { try shelves.store!.addText(name, to: gridWindow.shelfID) }
gridWindow.refresh(); gridWindow.toggleDetails()
gridWindow.contentView!.layoutSubtreeIfNeeded()
let nativeGrid = descendantViews(gridWindow.contentView!).compactMap { $0 as? DropShelfTable }.first!
let gridRowView = nativeGrid.view(atColumn: 0, row: 0, makeIfNecessary: true)!
gridRowView.layoutSubtreeIfNeeded()
let tiles = descendantViews(gridRowView).compactMap { $0 as? DropShelfTile }
expect(tiles.count == 3, "grid mounts three selectable tiles")
let deleteKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: gridWindow.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
let gridIDs = shelves.store!.shelf(gridWindow.shelfID)!.items.map(\.id)
nativeGrid.keyDown(with: deleteKey)
expect(shelves.store!.shelf(gridWindow.shelfID)!.items.map(\.id) == gridIDs, "Delete without grid item selection preserves every item")
gridWindow.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
expect(!gridWindow.tableView(nativeGrid, shouldSelectRow: 0) && gridWindow.table.selectedRowIndexes.isEmpty, "native grid row interaction clears stale item selection without selecting a row")
nativeGrid.keyDown(with: deleteKey)
expect(shelves.store!.shelf(gridWindow.shelfID)!.items.map(\.id) == gridIDs, "Delete after grid background interaction does not clear the shelf")
gridWindow.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
let tile = tiles[1]
let label = tile.arrangedSubviews[1]
let labelPoint = NSPoint(x: label.bounds.midX, y: label.bounds.midY)
let hit = tile.hitTest(label.convert(labelPoint, to: tile.superview))
expect(hit === tile.preview, "filename hit testing routes to its own tile selection handler")
let click = NSEvent.mouseEvent(with: .leftMouseDown, location: label.convert(labelPoint, to: nil), modifierFlags: [], timestamp: 0, windowNumber: gridWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
hit!.mouseDown(with: click)
expect(gridWindow.table.selectedRowIndexes == IndexSet(integer: 1), "filename interaction replaces stale list selection with the clicked item")
nativeGrid.keyDown(with: deleteKey)
expect(shelves.store!.shelf(gridWindow.shelfID)!.items.map(\.id) == [gridIDs[0], gridIDs[2]], "Delete removes only the filename-selected tile")
gridWindow.close()
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
