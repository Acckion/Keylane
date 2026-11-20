// Isolated executable using production shelf, menu-bar, and file-preview code.
// No Keylane services are started and the user's normal preference domain is never opened.
final class ShelfTestPromise: DropShelfReceiving {
    let name: String
    let fail: Bool
    let delay: TimeInterval
    let contents: String?
    let overwrite: Bool
    private(set) var destination: URL?
    var expectedCount: Int { 1 }
    var names: [String] { [name] }
    init(_ name: String, fail: Bool = false, delay: TimeInterval = 0.1, contents: String? = nil, overwrite: Bool = false) {
        self.name = name; self.fail = fail; self.delay = delay; self.contents = contents; self.overwrite = overwrite
    }
    func receive(at destination: URL, queue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        self.destination = destination
        queue.addOperation { [self] in
            Thread.sleep(forTimeInterval: delay)
            let url = destination.appendingPathComponent(name)
            do {
                if fail {
                    try Data("partial".utf8).write(to: url)
                    throw NSError(domain: "KeylaneSyntheticPromise", code: 1, userInfo: [NSLocalizedDescriptionKey: "synthetic promise failure"])
                }
                try Data((contents ?? "Synthetic " + name).utf8).write(to: url, options: overwrite ? .atomic : .withoutOverwriting)
                reader(url, nil)
            } catch { reader(url, error) }
        }
    }
}
final class ShelfTestMultiPromise: DropShelfReceiving {
    let producerQueue = OperationQueue()
    private var registered = false
    var expectedCount: Int { 1 } // Legacy source: one advertised type, two delivered files.
    var names: [String] { registered ? ["ordered-one.txt", "ordered-two.txt"] : [] }
    func receive(at destination: URL, queue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        registered = true
        for (index, name) in names.enumerated() {
            producerQueue.addOperation {
                Thread.sleep(forTimeInterval: index == 0 ? 0.3 : 0.05)
                let file = destination.appendingPathComponent(name)
                do {
                    try Data(name.utf8).write(to: file, options: .withoutOverwriting)
                    queue.addOperation { reader(file, nil) }
                } catch { queue.addOperation { reader(file, error) } }
            }
        }
    }
}
// Protocol double for destination callback ordering; not a physical drag session.
final class ShelfTestDragInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber = 4321
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var testDraggingItems: [NSDraggingItem] = []
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, board: NSPasteboard) { draggingDestinationWindow = window; draggingPasteboard = board }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        for (index, item) in testDraggingItems.enumerated() {
            block(item, index, &stop)
            if stop.boolValue { break }
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
func descendantViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendantViews) }
if !CommandLine.arguments.contains("--empty") {
expect(abs(window.frame.width - window.frame.height) < 1, "compact shelf is square: \(window.frame)")
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
let snapScreen = NSRect(x: -800, y: 40, width: 800, height: 600)
func snapCandidate(_ x: CGFloat, _ y: CGFloat) -> NSRect { NSRect(x: x, y: y, width: 210, height: 210) }
expect(DropShelfDock.target(for: snapCandidate(-830, 417), in: snapScreen) == nil, "a mostly visible shelf does not dock")
let leftDock = DropShelfDock.target(for: snapCandidate(-925, 417), in: snapScreen)!
expect(leftDock.frame(for: snapCandidate(-925, 417)).origin == NSPoint(x: -982, y: 417) && leftDock.edge.symbol == "chevron.right",
       "the exposed left strip has an inward-facing handle")
let snapSecondScreen = NSRect(x: 0, y: -60, width: 700, height: 650)
let rightDock = DropShelfDock.target(for: snapCandidate(630, 0), in: snapSecondScreen)!
expect(rightDock.frame(for: snapCandidate(630, 0)).minX == 672 && rightDock.edge.symbol == "chevron.left", "the opposite edge mirrors its handle")
expect(DropShelfDock.target(for: snapCandidate(-925, 417), in: snapScreen,
                           neighboring: [NSRect(x: -1600, y: 40, width: 800, height: 600)]) == nil,
       "the seam between displays does not dock a shelf")
let menuBarSafeArea = NSRect(x: -800, y: 40, width: 800, height: 562)
let highShelf = snapCandidate(-500, 555)
let topDock = DropShelfDock.target(for: highShelf, in: snapScreen, usable: menuBarSafeArea)!
expect(topDock.edge == .top && topDock.frame(for: highShelf).minY == menuBarSafeArea.maxY - DropShelfDock.strip,
       "top docking keeps the entire visible handle below a tall menu bar")

if let screen = window.screen {
    let moveShelf = shelves.create()!
    let area = screen.frame
    moveShelf.setFrameOrigin(NSPoint(x: area.midX - moveShelf.frame.width / 2, y: area.midY - moveShelf.frame.height / 2))
    moveShelf.contentView!.layoutSubtreeIfNeeded()
    let grabPoint = NSPoint(x: moveShelf.frame.width - 10, y: moveShelf.frame.height - 6)
    func shelfMouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: moveShelf.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    let emptyPreview = descendantViews(moveShelf.contentView!).compactMap { $0 as? DropShelfPreview }.first!
    expect(moveShelf.dropOverlay.primaryMouseTarget(at: midpointInWindow(emptyPreview)) == nil,
           "an empty shelf preview is a window drag region")
    let start = moveShelf.frame.origin
    let mouse = moveShelf.convertPoint(toScreen: grabPoint)
    moveShelf.dropOverlay.mouseDown(with: shelfMouse(.leftMouseDown, at: grabPoint))
    let partlyOutside = NSPoint(x: mouse.x + area.minX - 40 - start.x, y: mouse.y)
    moveShelf.dropOverlay.mouseDragged(with: shelfMouse(.leftMouseDragged, at: moveShelf.convertPoint(fromScreen: partlyOutside)))
    expect(abs(moveShelf.frame.minX - area.minX + 40) < 0.5, "dragging the shelf handle can move the window beyond the screen")
    let pastThreshold = NSPoint(x: partlyOutside.x - 85, y: partlyOutside.y)
    moveShelf.dropOverlay.mouseDragged(with: shelfMouse(.leftMouseDragged, at: moveShelf.convertPoint(fromScreen: pastThreshold)))
    let releaseOrigin = moveShelf.frame.origin
    expect(abs(releaseOrigin.x - area.minX + 125) < 0.5 && moveShelf.dropOverlay.dock == nil,
           "crossing the threshold keeps following the pointer until mouse up")
    moveShelf.dropOverlay.mouseUp(with: shelfMouse(.leftMouseUp, at: moveShelf.convertPoint(fromScreen: pastThreshold)))
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        expect(moveShelf.frame.origin == releaseOrigin, "dock animation starts at the mouse-up position")
        drain(0.06)
        expect(moveShelf.frame.minX < releaseOrigin.x && moveShelf.frame.maxX > area.minX + 28,
               "dock animation moves through intermediate positions")
    }
    drain(0.3)
    expect(abs(moveShelf.frame.maxX - area.minX - 28) < 0.5 && moveShelf.dropOverlay.dock?.edge == .left,
           "animation ends with the shelf docked at the screen edge")
    let overlay = moveShelf.dropOverlay
    moveShelf.contentView!.layoutSubtreeIfNeeded()
    let arrow = overlay.subviews.compactMap { $0 as? NSImageView }.first!
    expect(overlay.underlying?.isHidden == true && !arrow.isHidden && arrow.image != nil &&
           abs(arrow.frame.midX - overlay.bounds.maxX + 14) < 0.5 && abs(arrow.frame.midY - overlay.bounds.midY) < 0.5,
           "the strip shows only a centered inward handle")
    let handlePoint = midpointInWindow(arrow)
    overlay.mouseDown(with: shelfMouse(.leftMouseDown, at: handlePoint))
    overlay.mouseUp(with: shelfMouse(.leftMouseUp, at: handlePoint))
    drain(0.3)
    expect(moveShelf.frame.minX >= area.minX && overlay.dock == nil && overlay.underlying?.isHidden == false && arrow.isHidden,
           "clicking the handle restores the whole shelf and its controls")
    moveShelf.toggleDetails()
    let movingGrab = NSPoint(x: moveShelf.frame.midX - moveShelf.frame.minX, y: moveShelf.frame.height - 6)
    let movingMouse = moveShelf.convertPoint(toScreen: movingGrab)
    overlay.mouseDown(with: shelfMouse(.leftMouseDown, at: movingGrab))
    let shiftedMouse = NSPoint(x: movingMouse.x + 50, y: movingMouse.y - 10)
    overlay.mouseDragged(with: shelfMouse(.leftMouseDragged, at: moveShelf.convertPoint(fromScreen: shiftedMouse)))
    overlay.mouseUp(with: shelfMouse(.leftMouseUp, at: moveShelf.convertPoint(fromScreen: shiftedMouse)))
    let movedFrame = moveShelf.frame
    drain(0.3)
    expect(moveShelf.frame == movedFrame && movedFrame.width == 420, "starting to move an expanding shelf finishes its resize without resetting the dragged position")
    moveShelf.toggleDetails(); drain(0.3)
    let usable = screen.visibleFrame
    moveShelf.setFrameOrigin(NSPoint(x: usable.maxX - moveShelf.frame.width, y: usable.maxY - moveShelf.frame.height))
    moveShelf.toggleDetails(); drain(0.3)
    expect(moveShelf.frame.maxY <= usable.maxY && moveShelf.frame.maxX <= usable.maxX,
           "expanding at the upper-right edge keeps the shelf controls within the visible screen")
    moveShelf.close()
}
let notchScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
let notchLeft = NSRect(x: 0, y: 862, width: 620, height: 38)
let notchRight = NSRect(x: 820, y: 862, width: 620, height: 38)
expect(ShelfNotchTarget.region(frame: notchScreen, topInset: 38, left: notchLeft, right: notchRight) == NSRect(x: 620, y: 850, width: 200, height: 50), "notch drop region uses the real housing gap and exposes a strip underneath")
expect(ShelfNotchTarget.region(frame: notchScreen, topInset: 0, left: nil, right: nil) == nil, "a display without a notch has no drop target")
let settingsSuite = UserDefaults(suiteName: "org.keylane.test.shelf-activation." + UUID().uuidString)!
let activationSettings = DropShelfController(directory: root, preferences: settingsSuite)
expect(!activationSettings.keyActivation && activationSettings.activationKey == .command && !activationSettings.dropToNotch,
       "modifier activation is opt-in, with Command as the initial key")
expect(!ShelfActivationKey.command.matches([]) && ShelfActivationKey.command.matches(.command),
       "Command activation requires holding Command")
expect(!ShelfActivationKey.command.matches(.option) && !ShelfActivationKey.command.matches([.option, .command]) &&
       !ShelfActivationKey.command.matches([.function, .command]),
       "another modifier or a combination does not trigger Command activation")
expect(ShelfActivationKey.shift.matches([.shift, .capsLock]) && !ShelfActivationKey.shift.matches(.command),
       "the selected modifier is required and Caps Lock does not affect matching")
activationSettings.keyActivation = true
activationSettings.shakeSensitivity = .high
activationSettings.defaultPosition = .bottomRight
activationSettings.ignoredApps["fixture.example"] = "Fixture"
let reread = DropShelfController(directory: root, preferences: settingsSuite)
expect(reread.keyActivation, "an explicitly enabled modifier activation setting persists")
expect(reread.shakeSensitivity == .high && reread.defaultPosition == .bottomRight && reread.ignoredApps["fixture.example"] == "Fixture", "saved sensitivity, location and ignored apps persist")
let emptyDragShelf = shelves.createForDrag()!
let populatedDragShelf = shelves.createForDrag()!
expect(emptyDragShelf.frame.intersection(window.frame).isEmpty &&
       populatedDragShelf.frame.intersection(window.frame).isEmpty &&
       populatedDragShelf.frame.intersection(emptyDragShelf.frame).isEmpty,
       "drag-triggered shelves avoid existing visible shelves and each other")
let crowded = NSRect(x: -420, y: -100, width: 420, height: 210)
let neighboring = NSRect(x: 0, y: -100, width: 420, height: 210)
let obstruction = NSRect(x: -420, y: -100, width: 210, height: 210)
expect(DropShelfController.dragShelfOrigin(near: NSPoint(x: -410, y: 0), in: [crowded], avoiding: [obstruction]) == NSPoint(x: -210, y: -100),
       "drag placement uses an exact-fit slot before leaving the pointer display")
expect(DropShelfController.dragShelfOrigin(near: NSPoint(x: -410, y: 0), in: [crowded, neighboring], avoiding: [crowded]) == NSPoint(x: 10, y: -100),
       "drag placement can use a neighboring display when the current display is full")
expect(DropShelfController.dragShelfOrigin(near: NSPoint(x: -410, y: 0), in: [crowded], avoiding: [crowded]) == nil,
       "drag cannot create an overlapping shelf when all available space is occupied")

try shelves.store!.addFile(source, to: populatedDragShelf.shelfID)
populatedDragShelf.refresh()
let manualEmptyShelf = shelves.create()!
shelves.finishDragActivation()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
expect(!emptyDragShelf.isVisible, "unused drag-triggered empty shelf closes when drag ends")
expect(populatedDragShelf.isVisible, "populated drag-triggered shelf remains open")
expect(manualEmptyShelf.isVisible, "manually opened empty shelf is not auto-closed")
populatedDragShelf.close(); manualEmptyShelf.close()
let glassButtons = descendantViews(window.contentView!).compactMap { $0 as? NSButton }.filter { $0.action == NSSelectorFromString("closeShelf") || $0.action == NSSelectorFromString("disclosureAction") }
expect(window.contentView is LauncherGlassView, "shelf uses the shared Launcher window glass at the root")
expect(glassButtons.count == 2 && glassButtons.allSatisfy { !$0.isBordered && $0.superview?.subviews.count == 2 }, "corner actions overlay the shared glass surface without a second bezel")
let compactCenter = NSPoint(x: window.frame.midX, y: window.frame.midY)
window.toggleDetails(); drain(0.06)
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    expect(window.frame.width > 210 && window.frame.width < 420, "expansion has intermediate animation frames")
}
drain(0.3)
expect(window.frame.width > window.frame.height, "expanded shelf uses the wide content layout")
expect(abs(window.frame.midX - compactCenter.x) < 1 && abs(window.frame.midY - compactCenter.y) < 1, "expansion preserves both center coordinates")
let modeButtons = descendantViews(window.contentView!).compactMap { $0 as? NSButton }.filter { $0.action == NSSelectorFromString("changeViewMode:") }
let listMode = modeButtons.first { $0.accessibilityLabel() == "列表" }!
let gridMode = modeButtons.first { $0.accessibilityLabel() == "网格" }!
listMode.performClick(nil)
window.contentView!.layoutSubtreeIfNeeded()
let visibleTable = descendantViews(window.contentView!).compactMap { $0 as? NSTableView }.first!
expect(listMode.state == .on && gridMode.state == .off && visibleTable.numberOfRows == 6, "list switch selects one segment and presents all shelf items")
expect(visibleTable.tableColumns[0].width > 300, "file list column fills the visible viewport")
expect(descendantViews(visibleTable).compactMap { $0 as? NSButton }.contains { $0.action == NSSelectorFromString("revealListItem:") }, "file rows expose the Finder action")
let firstListItem = visibleTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as! DropShelfListItemView
firstListItem.layoutSubtreeIfNeeded()
func midpointInWindow(_ view: NSView) -> NSPoint {
    view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
}
expect(window.dropOverlay.primaryMouseTarget(at: midpointInWindow(firstListItem.arrangedSubviews[1])) === visibleTable,
       "dragging a list filename uses the native file drag source")
expect(window.dropOverlay.primaryMouseTarget(at: midpointInWindow(firstListItem.arrangedSubviews[2])) == nil,
       "empty space beside a list filename moves the shelf")

gridMode.performClick(nil)
expect(gridMode.state == .on && listMode.state == .off, "switching back activates only the grid segment")
func hoverShelfButton(_ button: NSButton) {
    let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
    window.dropOverlay.mouseMoved(with: event)
}
hoverShelfButton(gridMode)
expect((gridMode as? DropShelfHoverButton)?.isHovered == true, "overlay routes pointer highlight to the grid segment")
hoverShelfButton(listMode)
expect((gridMode as? DropShelfHoverButton)?.isHovered == false && (listMode as? DropShelfHoverButton)?.isHovered == true,
       "pointer entering another segment clears the previous hover")

window.collapseIfOutside(at: compactCenter)
expect(window.frame.width > window.frame.height, "inside click does not collapse shelf")
window.collapseIfOutside(at: NSPoint(x: window.frame.maxX + 20, y: window.frame.midY)); drain(0.3)
expect(abs(window.frame.width - window.frame.height) < 1, "outside click restores square shelf")
expect(abs(window.frame.midX - compactCenter.x) < 1 && abs(window.frame.midY - compactCenter.y) < 1, "collapse preserves both center coordinates")
let managed = try shelves.store!.create()
try shelves.store!.rename(managed, title: "Manager fixture")
try shelves.store!.addText("searchable payload token", to: managed)
try shelves.store!.addFile(source, to: managed)
shelves.searchShelves("payload token")
expect(shelves.managedShelves.map(\.id) == [managed], "manager searches nested content with all query terms")
expect(shelves.selectedShelfID == managed, "manager maintains a valid selection")
shelves.shelfFilter = "recent"
shelves.toggleManagedPin(managed)
expect(shelves.isShelfOpen(managed), "pinning a manager card opens its corresponding desktop shelf")
expect(shelves.selectedShelfID == nil, "pinning from the closed filter never leaves a hidden selection")
shelves.shelfFilter = "pinned"
expect(shelves.selectedShelf?.id == managed, "the fixed filter contains the desktop shelf")
shelves.toggleSelectedPin(); drain(0.25)
expect(!shelves.isShelfOpen(managed) && shelves.store!.shelf(managed)?.items.count == 2,
       "unpinning closes only the window and preserves its contents")
expect(shelves.selectedShelfID == nil, "the fixed filter drops a shelf as soon as its window closes")
shelves.shelfFilter = "recent"
shelves.openSelectedShelf()
expect(shelves.isShelfOpen(managed), "opening a saved card normally also activates its desktop status")
shelves.shelfFilter = "all"
shelves.renameManagedShelf(managed, title: "Renamed manager fixture")
expect(shelves.selectedShelf?.title == "Renamed manager fixture", "manager rename refreshes snapshots")
let emptySavedWindow = shelves.create()!
let emptySavedID = emptySavedWindow.shelfID
shelves.renameManagedShelf(emptySavedID, title: "Saved empty fixture")
shelves.toggleManagedPin(emptySavedID); drain(0.25)
expect(!shelves.isShelfOpen(emptySavedID), "unpinning a named empty shelf closes its window")
shelves.closeManagedShelf(managed); drain(0.25)
let afterClose = try DropShelfStore(directory: shelves.store!.directory)
expect(afterClose.shelf(emptySavedID)?.title == "Saved empty fixture", "a later window close and reopening the archive preserve a saved empty shelf")
shelves.removeManagedShelf(emptySavedID)
shelves.searchShelves("unmatched manager query")
expect(shelves.managedShelves.isEmpty && shelves.selectedShelfID == nil, "empty search clears stale selection")
shelves.searchShelves("")
shelves.selectedShelfID = managed
shelves.removeManagedShelf(managed)
expect(shelves.store!.shelf(managed) == nil, "manager removes the selected shelf record")
expect(FileManager.default.fileExists(atPath: source.path), "manager removal preserves source files")
shelves.shelfFilter = "all"
shelves.searchShelves("")
let placementIDs = try (0..<3).map { index -> UUID in
    let id = try shelves.store!.create()
    try shelves.store!.addText("A distinct placement shelf \(index)", to: id)
    return id
}
let preexistingFrames = NSApp.windows.compactMap { $0 as? DropShelfWindow }
    .filter { $0.isVisible && $0.controller === shelves }.map(\.frame)
shelves.launcherShown()
let openingOrder = shelves.managedShelves.map(\.id)
let activationOrder = [placementIDs[2], placementIDs[0], placementIDs[1]]
for id in activationOrder {
    shelves.toggleManagedPin(id)
    expect(shelves.managedShelves.map(\.id) == openingOrder, "pinning keeps every card in its position for this Launcher opening")
}
let placementWindows = NSApp.windows.compactMap { $0 as? DropShelfWindow }
    .filter { $0.isVisible && placementIDs.contains($0.shelfID) }
expect(placementWindows.count == placementIDs.count, "consecutive pins open each shelf once")
for (index, window) in placementWindows.enumerated() {
    let otherFrames = preexistingFrames + placementWindows.dropFirst(index + 1).map(\.frame)
    expect(otherFrames.allSatisfy { $0.intersection(window.frame).isEmpty },
           "newly pinned shelf avoids every already visible shelf")
}
placementWindows.first { $0.shelfID == placementIDs[0] }?.close()
shelves.endManagement()
shelves.beginManagement("")
expect(shelves.managedShelves.map(\.id) == openingOrder, "returning to the manager in the same Launcher keeps the original order")
shelves.toggleManagedPin(placementIDs[0])
expect(shelves.isShelfOpen(placementIDs[0]) && shelves.managedShelves.map(\.id) == openingOrder,
       "the same card can be pinned again without moving")
shelves.toggleManagedPin(placementIDs[0]); drain(0.25)
expect(shelves.managedShelves.map(\.id) == openingOrder, "unpinning keeps the card in the same position")
expect(!shelves.isShelfOpen(placementIDs[0]) && shelves.isShelfOpen(placementIDs[1]) && shelves.isShelfOpen(placementIDs[2]),
       "desktop close and reopening management reflect each window independently")
shelves.launcherHidden(); shelves.launcherShown()
expect(Array(shelves.managedShelves.prefix(3).map(\.id)) == [placementIDs[0], placementIDs[1], placementIDs[2]],
       "the next Launcher opening applies actual use order without promoting closes")
let newDuringSession = try shelves.store!.create()
expect(shelves.managedShelves.last?.id == newDuringSession, "new shelves append without displacing current card positions")
try shelves.store!.deleteShelf(newDuringSession)
shelves.launcherHidden()
for id in placementIDs { shelves.removeManagedShelf(id) }
let navigationFixtureIDs = try (0..<5).map { _ in try shelves.store!.create() }
for id in navigationFixtureIDs { try shelves.store!.rename(id, title: "grid-navigation-token") }
shelves.searchShelves("grid-navigation-token")
let gridOrder = shelves.managedShelves.map(\.id)
shelves.managementGridColumns = 3
shelves.selectedShelfID = gridOrder[1]
shelves.moveShelf(1, vertical: true)
expect(shelves.selectedShelfID == gridOrder[4], "down moves to the same grid column")
shelves.moveShelf(-1)
expect(shelves.selectedShelfID == gridOrder[3], "left moves to the adjacent card")
for id in navigationFixtureIDs { try shelves.store!.deleteShelf(id) }
shelves.managementGridColumns = 1
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
    try deletionStore.trimHistory()
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
let screenshotShelf = shelves.create()!
for index in 1...4 {
    let url = fixtures.appendingPathComponent("Screenshot-\(index).png")
    try FileManager.default.copyItem(at: imageURL, to: url)
    board.clearContents(); board.writeObjects([url as NSURL])
    expect(screenshotShelf.receive(board, isDrag: true), "expanded preview fixture imports a PNG through the drag receiver")
}
screenshotShelf.refresh(); screenshotShelf.toggleDetails(); drain(0.3)
screenshotShelf.contentView!.layoutSubtreeIfNeeded()
let screenshotGrid = descendantViews(screenshotShelf.contentView!).compactMap { $0 as? DropShelfTable }.first!
let screenshotRow = screenshotGrid.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSStackView
let screenshotLastRow = screenshotGrid.view(atColumn: 0, row: 1, makeIfNecessary: true) as! NSStackView
let lastFileTile = screenshotLastRow.arrangedSubviews[0] as! DropShelfTile
let finderTile = screenshotLastRow.arrangedSubviews[1] as! DropShelfTile
let finderButton = finderTile.subviews.compactMap { $0 as? NSButton }.first!
expect(screenshotGrid.numberOfRows == 2 && finderButton.accessibilityLabel() == "在 Finder 中显示", "four files put the Finder action in the fifth grid position")
screenshotLastRow.layoutSubtreeIfNeeded()
func centerY(_ view: NSView) -> CGFloat {
    view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: screenshotLastRow).y
}
expect(abs(centerY(lastFileTile.preview!.imageView) - centerY(finderTile.arrangedSubviews[0])) < 0.5 &&
       abs(centerY(lastFileTile.arrangedSubviews[1]) - centerY(finderTile.arrangedSubviews[1])) < 0.5,
       "Finder symbol and title align with the neighboring file thumbnail and filename")
let finderLabel = finderTile.arrangedSubviews[1]
let finderLabelPoint = finderLabel.convert(NSPoint(x: finderLabel.bounds.midX, y: finderLabel.bounds.midY), to: nil)
expect(screenshotShelf.dropOverlay.forwardedView(at: finderLabelPoint) === finderButton, "the Finder label remains clickable")
let screenshotPreview = (screenshotRow.arrangedSubviews[0] as! DropShelfTile).preview!
func hasScreenshotAspectRatio() -> Bool {
    guard let size = screenshotPreview.imageView.image?.size, size.height > 0 else { return false }
    return abs(size.width / size.height - 1.6) < 0.03
}
for _ in 0..<40 where !hasScreenshotAspectRatio() { drain(0.05) }
expect(hasScreenshotAspectRatio(), "an expanded PNG file tile loads the image thumbnail with its original aspect ratio")
let screenshotPoint = midpointInWindow(screenshotPreview.imageView)
expect(screenshotShelf.dropOverlay.primaryMouseTarget(at: screenshotPoint) === screenshotPreview,
       "dragging the visible screenshot uses the file drag source")
let screenshotTile = screenshotRow.arrangedSubviews[0]
let gridPadding = screenshotTile.convert(NSPoint(x: screenshotTile.bounds.minX + 2, y: screenshotTile.bounds.midY), to: nil)
expect(screenshotShelf.dropOverlay.primaryMouseTarget(at: gridPadding) == nil,
       "padding beside the thumbnail moves the shelf")
screenshotShelf.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
func clickScreenshotPadding(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: gridPadding, modifierFlags: [], timestamp: 0,
                      windowNumber: screenshotShelf.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
}
screenshotShelf.dropOverlay.mouseDown(with: clickScreenshotPadding(.leftMouseDown))
screenshotShelf.dropOverlay.mouseUp(with: clickScreenshotPadding(.leftMouseUp))
expect(screenshotShelf.table.selectedRowIndexes.isEmpty, "clicking grid padding through the real overlay clears the old file selection")

expect(screenshotShelf.dropOverlay.primaryMouseTarget(at: finderLabelPoint) === finderButton,
       "the Finder control still keeps its click action")

screenshotShelf.refreshFiles()
screenshotShelf.contentView!.layoutSubtreeIfNeeded()
let rebuiltScreenshotRow = screenshotGrid.view(atColumn: 0, row: 0, makeIfNecessary: true) as! NSStackView
let rebuiltScreenshotPreview = (rebuiltScreenshotRow.arrangedSubviews[0] as! DropShelfTile).preview!
let rebuiltSize = rebuiltScreenshotPreview.imageView.image!.size
expect(abs(rebuiltSize.width / rebuiltSize.height - 1.6) < 0.03, "reference polling keeps a decoded screenshot visible immediately after the grid is rebuilt")

screenshotShelf.close()
let collisionWindow = shelves.create()!
let collisionProviders = [
    ShelfTestPromise("invoice.pdf", delay: 0.3, contents: "first"),
    ShelfTestPromise("invoice.pdf", fail: true),
    ShelfTestPromise("invoice.pdf", contents: "second", overwrite: true),
    ShelfTestPromise("invoice.pdf", contents: "third")
]
expect(collisionWindow.receivePromises(collisionProviders), "same-name promise batch begins")
expect(collisionProviders.allSatisfy { $0.destination != nil }, "every receiver is registered synchronously before acceptance returns")
for _ in 0..<100 where shelves.store!.shelf(collisionWindow.shelfID)!.items.count < 3 { drain(0.05) }
let collisionItems = shelves.store!.shelf(collisionWindow.shelfID)!.items
expect(collisionItems.count == 3 && collisionItems.allSatisfy { $0.title == "invoice.pdf" }, "same-name successes survive partial failure with original names")
let collisionData = try collisionItems.map { try String(contentsOf: shelves.store!.resolve($0)!, encoding: .utf8) }
expect(collisionData == ["first", "second", "third"], "same-name promises never overwrite earlier bytes and retain source order")
expect(Set(collisionProviders.compactMap(\.destination)).count == 1 && collisionProviders.allSatisfy { $0.destination != nil }, "all receivers use the same AppKit destination")
expect(collisionWindow.feedbackText.contains("synthetic promise failure"), "same-name partial failure remains visible")
expect(collisionWindow.receivePromises([ShelfTestMultiPromise()]), "multi-file receiver begins")
for _ in 0..<100 where shelves.store!.shelf(collisionWindow.shelfID)!.items.count < 5 { drain(0.05) }
expect(Array(shelves.store!.shelf(collisionWindow.shelfID)!.items.suffix(2)).map(\.title) == ["ordered-one.txt", "ordered-two.txt"], "out-of-order callbacks within a receiver retain declared order")
let cancelledProviders = [ShelfTestPromise("cancel.pdf", delay: 0.05), ShelfTestPromise("cancel.pdf", delay: 0.4), ShelfTestPromise("cancel.pdf")]
expect(collisionWindow.receivePromises(cancelledProviders), "multi-receiver cancellation begins")
expect(cancelledProviders.allSatisfy { $0.destination != nil }, "cancelable receivers are all registered within acceptance")
for _ in 0..<100 where (try? FileManager.default.contentsOfDirectory(atPath: incoming.path).contains { $0.hasSuffix("-staged") }) != true { drain(0.01) }
expect((try? FileManager.default.contentsOfDirectory(atPath: incoming.path).contains { $0.hasSuffix("-staged") }) == true, "cancellation occurs after an earlier receiver has staged its result")
collisionWindow.cancelImports(); drain(0.8)
expect(shelves.store!.shelf(collisionWindow.shelfID)!.items.count == 5, "cancelled staged results never enter the shelf")
expect(cancelledProviders[2].destination != nil, "cancellation revokes commits without assuming native writes can be stopped")
expect((try? FileManager.default.contentsOfDirectory(atPath: incoming.path).isEmpty) == true, "collision success failure and cancellation clean receiving and staging directories")
collisionWindow.close()
let droppingWindow = shelves.createForDrag()!
let dropSurface = droppingWindow.dropOverlay
expect(droppingWindow.showsDragEntry && !dropSurface.showsEntryHighlight, "automatic shelf starts in the neutral entry state")
let entryViews = descendantViews(droppingWindow.contentView!)
expect(entryViews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "放置你的内容项" && !$0.isHiddenOrHasHiddenAncestor }, "entry shows the centered drop prompt")
expect(entryViews.compactMap { $0 as? NSButton }.allSatisfy { $0.isHiddenOrHasHiddenAncestor }, "entry hides all normal shelf buttons")

board.clearContents(); board.writeObjects([source as NSURL])
let dropInfo = ShelfTestDragInfo(window: droppingWindow, board: board)
let detachedFrame = NSRect(x: -90, y: -70, width: 84, height: 64)
dropInfo.testDraggingItems = (0..<3).map { index in
    let item = NSDraggingItem(pasteboardWriter: "fixture-\(index)" as NSString)
    item.setDraggingFrame(detachedFrame, contents: nil)
    return item
}
expect(dropSurface.registeredDraggedTypes.contains(.fileURL), "whole card surface registers file drops")
expect(dropSurface.draggingEntered(dropInfo) == .copy && droppingWindow.receivingDrag, "native destination entry marks a pending drop")
expect(dropSurface.showsEntryHighlight, "drag hover shows the blue outline with the mouse still down")
dropSurface.draggingExited(dropInfo)
expect(!dropSurface.showsEntryHighlight && droppingWindow.showsDragEntry, "dragging away clears the blue outline without activating the normal shelf")
_ = dropSurface.draggingEntered(dropInfo)
shelves.finishDragActivation()
expect(droppingWindow.isVisible, "mouse release cleanup cannot close a pending destination before perform")
expect(dropSurface.prepareForDragOperation(dropInfo) && dropSurface.performDragOperation(dropInfo), "card-wide destination delivers the dropped file")
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    expect(dropInfo.animatesToDestination && dropSurface.waitsForNativeLanding && droppingWindow.showsDragEntry,
           "entry waits for AppKit landing before showing normal shelf chrome")
    let frames = dropInfo.testDraggingItems.map(\.draggingFrame)
    expect(frames.allSatisfy { dropSurface.bounds.contains($0) && $0.width <= 52 } && Set(frames.map(\.midX)).count == 3,
           "AppKit gets distinct landing frames for all three drag images")
}
dropSurface.concludeDragOperation(dropInfo); dropSurface.draggingEnded(dropInfo)
shelves.finishDragActivation()
expect(droppingWindow.isVisible && shelves.store!.shelf(droppingWindow.shelfID)!.items.count == 1, "completed file drop keeps the populated automatic shelf")
expect(!droppingWindow.receivingDrag, "completed drop clears pending destination state")
expect(!droppingWindow.showsDragEntry && !dropSurface.showsEntryHighlight, "successful drop begins the transition to normal shelf chrome")
drain(0.42)
expect(droppingWindow.isVisible && droppingWindow.alphaValue == 1 && !droppingWindow.ignoresMouseEvents,
       "window fade-in and post-drop chrome transition leave the shelf visible and interactive")
expect(entryViews.compactMap { $0 as? NSTextField }.filter { $0.stringValue == "放置你的内容项" }.allSatisfy(\.isHidden), "transition retires the entry prompt")
expect(dropSurface.performDragOperation(dropInfo) && shelves.store!.shelf(droppingWindow.shelfID)!.items.count == 1, "repeated perform callback does not duplicate the file")
droppingWindow.contentView!.layoutSubtreeIfNeeded()
expect(dropSurface.frame.size == droppingWindow.contentView!.bounds.size, "drop surface fills the entire square card")
for x in [0.15, 0.5, 0.85] {
    for y in [0.1, 0.5, 0.9] {
        dropInfo.draggingLocation = NSPoint(x: droppingWindow.frame.width * x, y: droppingWindow.frame.height * y)
        dropInfo.draggingSequenceNumber += 1
        let content = droppingWindow.contentView!
        let hit = content.hitTest(content.superview?.convert(dropInfo.draggingLocation, from: nil) ?? dropInfo.draggingLocation)
        expect(hit === dropSurface, "actual view hit testing selects the same top capture layer across the entire card")
        expect(droppingWindow.draggingEntered(dropInfo) == .copy && droppingWindow.prepareForDragOperation(dropInfo), "window fallback accepts top middle and bottom card regions")
        expect(droppingWindow.performDragOperation(dropInfo), "window fallback receives across the card including footer controls")
        droppingWindow.concludeDragOperation(dropInfo); droppingWindow.draggingEnded(dropInfo)
    }
}
let footerButton = descendantViews(droppingWindow.contentView!).compactMap { $0 as? NSButton }.first { $0.title == source.lastPathComponent }!
let footerPoint = footerButton.convert(NSPoint(x: footerButton.bounds.midX, y: footerButton.bounds.midY), to: nil)
expect(droppingWindow.dropOverlay.forwardedView(at: footerPoint) === footerButton, "full capture layer forwards ordinary footer clicks to the real button")
dropInfo.draggingLocation = NSPoint(x: -5, y: -5)
expect(droppingWindow.draggingEntered(dropInfo).isEmpty, "window fallback rejects locations outside the card")
let abandonedWindow = shelves.createForDrag()!
let abandonedSurface = abandonedWindow.dropOverlay
let abandonedInfo = ShelfTestDragInfo(window: abandonedWindow, board: board)
_ = abandonedSurface.draggingEntered(abandonedInfo)
abandonedSurface.draggingExited(abandonedInfo); abandonedSurface.draggingEnded(abandonedInfo)
shelves.finishDragActivation()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
expect(!abandonedWindow.isVisible && droppingWindow.isVisible, "cancelled empty drop closes only the empty shelf")
droppingWindow.close()
final class ShelfSamplePaper: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        ("KEYLANE\n\nSynthetic document preview\n\n1. Native file icon\n2. Original page proportions\n3. Independent local fixture" as NSString).draw(in: bounds.insetBy(dx: 45, dy: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
    }
}
let paperView = ShelfSamplePaper(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
let paperURLs = (1...2).map { fixtures.appendingPathComponent("preview-paper-\($0).pdf") }
for url in paperURLs { try paperView.dataWithPDF(inside: paperView.bounds).write(to: url) }
let previewFolder = fixtures.appendingPathComponent("Preview Folder", isDirectory: true)
try FileManager.default.createDirectory(at: previewFolder, withIntermediateDirectories: true)
let visualWindow = shelves.create()!
for urls in [[paperURLs[0]], paperURLs, [previewFolder] + paperURLs] {
    try shelves.store!.remove(visualWindow.shelfID)
    for url in urls { try shelves.store!.addFile(url, to: visualWindow.shelfID) }
    visualWindow.refresh(); drain(0.8)
    visualWindow.contentView!.layoutSubtreeIfNeeded()
    let visualPreview = descendantViews(visualWindow.contentView!).compactMap { $0 as? DropShelfPreview }.first!
    let layers = visualPreview.subviews.compactMap { $0 as? NSImageView }.filter { !$0.isHidden && $0.image != nil }
    expect(layers.count == urls.count, "one two and three items render distinct native preview layers")
    expect(visualWindow.frame.width == visualWindow.frame.height, "native stacked preview preserves square shelf geometry")
    let bitmap = visualPreview.bitmapImageRepForCachingDisplay(in: visualPreview.bounds)!
    visualPreview.cacheDisplay(in: visualPreview.bounds, to: bitmap)
    let rendered = NSImage(size: visualPreview.bounds.size)
    rendered.lockFocus()
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill(); NSRect(origin: .zero, size: rendered.size).fill()
    bitmap.draw(in: NSRect(origin: .zero, size: rendered.size))
    rendered.unlockFocus()
    try NSBitmapImageRep(data: rendered.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("native-preview-\(urls.count).png"))
}
visualWindow.close()
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
    let sampleFolders = try (1...3).map { index in
        let folder = fixtures.appendingPathComponent("manager-folder-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    var folderShelfIDs: [UUID] = []
    for _ in 0..<6 {
        let folderShelf = try managerStore.create()
        folderShelfIDs.append(folderShelf)
        for url in sampleFolders { try managerStore.addFile(url, to: folderShelf) }
    }
    previewModel.runCommand(.init(rawValue: "drop-shelf-history"), origin: .search)
    expect(previewModel.pageID == PageID(rawValue: "DropShelfHistory"), "registered manager command opens Launcher page")
    guard let managerPage = previewModel.activeLauncherPage else { fatalError("manager page registration missing") }
    do {
        let controller = previewModel.dropShelf
        let matches = Array(folderShelfIDs.prefix(3))
        for id in matches { try managerStore.rename(id, title: "Keyboard fixture match") }
        controller.managementGridColumns = 4
        controller.searchShelves("Keyboard fixture match")
        let filtered = controller.managedShelves.map(\.id)
        expect(filtered.count == 3 && managerPage.navigateWhileTyping, "search field enables Option-arrow navigation for a single filtered row")
        controller.selectedShelfID = filtered[0]
        managerPage.moveHorizontal?(1)
        expect(controller.selectedShelfID == filtered[1], "horizontal movement reaches the neighboring filtered card")
        controller.searchShelves("")
    }
    let previewWindow = LauncherPanel(contentRect: NSRect(x: 100, y: 100, width: 760, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
    previewDelegate.window = previewWindow
    previewWindow.title = "Keylane Shelf Manager — Isolated Preview"
    previewWindow.isOpaque = false; previewWindow.backgroundColor = .clear
    let hosted = NSHostingView(rootView: Launcher(model: previewModel))
    hosted.sizingOptions = []
    previewWindow.contentView = LauncherGlassHostView(content: hosted)
    previewWindow.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    NotificationCenter.default.post(name: .launcherShown, object: nil)
    for mode in ["dark", "light"] {
        previewModel.appearance = mode
        previewWindow.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosted.layoutSubtreeIfNeeded()
        let previews = descendantViews(hosted).compactMap { $0 as? DropShelfPreview }
            .filter { $0.imageView.image != nil && !$0.isHiddenOrHasHiddenAncestor }
        let gridColumns = previewModel.dropShelf.managementGridColumns
        let spacing: CGFloat = 12
        let inset = VisualStyle.launcherEdgeInset
        let cellWidth = (hosted.bounds.width - 2 * inset - CGFloat(gridColumns - 1) * spacing) / CGFloat(gridColumns)
        let centers = (0..<gridColumns).map { inset + cellWidth / 2 + CGFloat($0) * (cellWidth + spacing) }
        var stackedCount = 0
        for preview in previews {
            let imageViews: [NSImageView] = preview.subviews.compactMap { $0 as? NSImageView }
            let visibleImages = imageViews.filter { view in view.image != nil && !view.isHidden }
            if visibleImages.count == 3 { stackedCount += 1 }
        }
        expect(gridColumns == 4 && stackedCount > 0, "manager loads three-image stacks in the four-column grid")
        expect(previews.allSatisfy { preview in
            let frame = preview.convert(preview.bounds, to: hosted)
            return abs(frame.width - (cellWidth - 20)) < 2 && centers.contains { abs($0 - frame.midX) < 2 }
        }, "single and stacked thumbnails stay centered within their own card")
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
    if !CommandLine.arguments.contains("--manager-interactive"), let id = folderShelfIDs.first {
        previewWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        expect(previewWindow.isVisible && previewWindow.isKeyWindow, "Launcher is visible and key before pinning")
        let launcherOpeningOrder = previewModel.dropShelf.managedShelves.map(\.id)
        previewModel.dropShelf.toggleManagedPin(id)
        expect(previewModel.dropShelf.managedShelves.map(\.id) == launcherOpeningOrder,
               "registered Launcher lifecycle freezes grid order while its pin is pressed")
        let pinnedWindow = NSApp.windows.compactMap { $0 as? DropShelfWindow }.first { $0.shelfID == id }
        guard let pinnedWindow else { fatalError("pinned shelf did not open") }
        expect(previewWindow.isVisible && previewWindow.isKeyWindow && pinnedWindow.isVisible,
               "pinning presents a desktop shelf and preserves Launcher keyboard focus")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            expect(pinnedWindow.alphaValue > 0 && pinnedWindow.alphaValue < 1,
                   "pinning fades the desktop shelf through an intermediate opacity")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        expect(pinnedWindow.alphaValue == 1 && previewWindow.isKeyWindow, "pinned shelf finishes fading while Launcher stays key")
        let contentFrame = pinnedWindow.contentView?.frame.size
        expect(pinnedWindow.frame.size == DropShelfWindow.compactSize && contentFrame == pinnedWindow.frame.size,
               "pinning a saved three-folder shelf opens a square desktop window and glass: \(pinnedWindow.frame), \(String(describing: contentFrame))")
        pinnedWindow.toggleDetails(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        expect(pinnedWindow.frame.width > pinnedWindow.frame.height, "pinned desktop shelf can still expand")
        pinnedWindow.toggleDetails(); RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        expect(pinnedWindow.frame.size == DropShelfWindow.compactSize, "pinned desktop shelf collapses to a square")
        pinnedWindow.close()
    }
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
if CommandLine.arguments.contains("--region-interactive") {
    if let screen = NSScreen.main {
        window.setFrameOrigin(NSPoint(x: 550, y: screen.frame.maxY - 660))
    }
    let receive = window.dropOverlay.receive
    var nativeCount = 0
    window.dropOverlay.receive = { board in
        let result = receive?(board) ?? false
        nativeCount += 1
        print("NATIVE_DROP count=\(nativeCount) accepted=\(result) point=\(NSEvent.mouseLocation)")
        return result
    }
    print("NATIVE_TARGET frame=\(window.frame)")
}
if CommandLine.arguments.contains("--interactive") {
    NSApp.run()
} else {
    window.close(); shelves.stop(); registry.shutdown()
}
