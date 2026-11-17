import AppKit
import Combine
import KeylaneCore
import UniformTypeIdentifiers
import QuickLookThumbnailing

final class DropShelfController: ObservableObject {
    @Published var copyByDefault: Bool { didSet { preferences.set(copyByDefault, forKey: "dropShelf.copy"); updateDragOperations() } }
    @Published var keepOpen: Bool { didSet { preferences.set(keepOpen, forKey: "dropShelf.keepOpen") } }
    @Published var shakeEnabled: Bool { didSet { preferences.set(shakeEnabled, forKey: "dropShelf.shake") } }
    @Published var error = ""
    @Published private(set) var managedShelves: [DropShelfStore.Shelf] = []
    @Published var selectedShelfID: UUID?
    @Published var shelfFilter = "all" { didSet { refreshManagement() } }
    @Published private(set) var managementActive = false
    func beginManagement(_ query: String) { managementActive = true; searchShelves(query) }
    func endManagement() { managementActive = false; pendingRemoval = nil; pendingRename = nil }
    @Published var pendingRemoval: DropShelfStore.Shelf?
    @Published var pendingRename: DropShelfStore.Shelf?
    private var managementQuery = ""
    var openManager: (() -> Void)?
    var selectedShelf: DropShelfStore.Shelf? { managedShelves.first { $0.id == selectedShelfID } }
    func searchShelves(_ query: String) { managementQuery = query; refreshManagement() }
    func refreshManagement() {
        let terms = managementQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        let values = (store?.shelves ?? []).filter { shelf in
            (shelfFilter == "all" || (shelfFilter == "pinned" ? shelf.pinned : !shelf.pinned)) && terms.allSatisfy { term in
                ([shelf.title] + shelf.items.flatMap { [$0.title, $0.value ?? "", $0.url?.path ?? ""] }).contains { $0.localizedStandardContains(term) }
            }
        }
        let ordered = values.filter(\.pinned) + values.filter { !$0.pinned }
        if managedShelves != ordered { managedShelves = ordered }
        if !ordered.contains(where: { $0.id == selectedShelfID }) { selectedShelfID = ordered.first?.id }
    }
    func moveShelf(_ delta: Int) {
        guard !managedShelves.isEmpty else { return }
        let index = managedShelves.firstIndex { $0.id == selectedShelfID } ?? 0
        selectedShelfID = managedShelves[min(max(index + delta, 0), managedShelves.count - 1)].id
    }
    func openSelectedShelf() { if let id = selectedShelfID { _ = reveal(id) } }
    func toggleSelectedPin() {
        guard let shelf = selectedShelf else { return }
        do { try store?.pin(shelf.id, value: !shelf.pinned); windows[shelf.id]?.refresh() } catch { report(error) }
    }
    func removeManagedShelf(_ id: UUID) {
        guard store?.shelf(id) != nil else { return }
        // Detach before closing: cancel imports normally, but do not retain/trim history.
        windows.removeValue(forKey: id)?.close()
        do { try store?.deleteShelf(id) } catch { report(error) }
        pendingRemoval = nil
    }
    func renameManagedShelf(_ id: UUID, title: String) {
        guard store?.shelf(id) != nil else { pendingRename = nil; return }
        do { try store?.rename(id, title: title); windows[id]?.refresh(); pendingRename = nil } catch { report(error) }
    }
    private let preferences: UserDefaults
    private let directory: URL
    private(set) var store: DropShelfStore?
    private var windows: [UUID: DropShelfWindow] = [:]
    private weak var registry: MenuBarRegistry?
    private var timer: Timer?
    private var automaticShelves = Set<UUID>()
    @discardableResult func createForDrag() -> DropShelfWindow? {
        guard let window = create(activate: false) else { return nil }
        automaticShelves.insert(window.shelfID)
        return window
    }
    func finishDragActivation() {
        for id in Array(automaticShelves) {
            automaticShelves.remove(id)
            guard let window = windows[id], store?.shelf(id)?.items.isEmpty == true, !window.receivedDrop else { continue }
            window.close()
        }
    }
    private var active = false
    private var performedStartupCleanup = false
    private var lastX: CGFloat?
    private var direction: CGFloat = 0
    private var turns: [TimeInterval] = []
    private var shookThisDrag = false
    private var refreshTick = 0
    private var appearance: NSAppearance?
    func applyAppearance(_ value: String) {
        appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
        windows.values.forEach { $0.appearance = appearance }
    }
    static let menuID = "keylane.drop-shelf"
    static let marker = NSPasteboard.PasteboardType("org.keylane.drop-shelf.item")
    static let imageTypes: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.tiff, "tiff"), (.init("public.jpeg"), "jpg"), (.init("com.compuserve.gif"), "gif"), (.init("public.heic"), "heic")]
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string] + imageTypes.map(\.0) + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    init(directory: URL? = nil, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/DropShelves", isDirectory: true)
        copyByDefault = preferences.bool(forKey: "dropShelf.copy")
        keepOpen = preferences.bool(forKey: "dropShelf.keepOpen")
        shakeEnabled = (preferences.object(forKey: "dropShelf.shake") as? Bool) ?? true
    }
    func start(registry: MenuBarRegistry) {
        guard !active else { return }
        do {
            store = try DropShelfStore(directory: directory)
            store?.didChange = { [weak self] in self?.refreshManagement() }
            refreshManagement()
            if !performedStartupCleanup { try store?.collectUnusedAssets(); performedStartupCleanup = true }
        } catch { self.error = error.localizedDescription; return }
        active = true; self.registry = registry
        registry.register(id: Self.menuID, owner: "keylane.drop-shelf", title: "暂存架", defaultVisible: true,
                          presentation: .init(symbol: "tray", toolTip: "拖入内容创建暂存架")) { [weak self] in self?.menu() ?? [] }
        registry.setDropHandler(id: Self.menuID, types: Self.types) { [weak self] board in
            guard let self, let window = self.create(activate: false) else { return false }
            return window.receive(board, isDrag: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() {
        active = false; timer?.invalidate(); timer = nil
        endManagement()
        for window in Array(windows.values) { window.close() }
        windows.removeAll()
        registry?.unregister(owner: "keylane.drop-shelf"); registry = nil
        // Keep the store until promise callbacks finish; old windows revoke their import batches.
    }
    @discardableResult func create(activate: Bool = true) -> DropShelfWindow? {
        guard active, let store else { return nil }
        do { let id = try store.create(); return reveal(id, activate: activate) }
        catch { report(error); return nil }
    }
    @discardableResult func reveal(_ id: UUID, activate: Bool = true) -> DropShelfWindow? {
        guard active, let store, store.shelf(id) != nil else { return nil }
        let window: DropShelfWindow
        if let existing = windows[id] { window = existing }
        else {
            window = DropShelfWindow(id: id, store: store, controller: self)
            windows[id] = window
            window.appearance = appearance
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                let x = min(max(mouse.x + 25, frame.minX), frame.maxX - window.frame.width)
                let y = min(max(mouse.y - window.frame.height / 2, frame.minY), frame.maxY - window.frame.height)
                window.setFrameOrigin(NSPoint(x: x, y: y))
            }
        }
        window.refresh()
        window.orderFrontRegardless()
        if activate { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); window.focusContents() }
        return window
    }
    func closed(_ window: DropShelfWindow) {
        automaticShelves.remove(window.shelfID)
        guard windows.removeValue(forKey: window.shelfID) != nil else { return }
        do { try store?.remember(window.shelfID, keeping: Set(windows.keys)) } catch { report(error) }
    }
    func clipboardShelf() { _ = create()?.receive(.general) }
    func selectShelf() {
        if let window = windows.values.sorted(by: { $0.shelfID.uuidString < $1.shelfID.uuidString }).first { _ = reveal(window.shelfID) }
        else if let id = store?.shelves.first?.id { _ = reveal(id) }
        else { create() }
    }
    func report(_ failure: Error) { error = failure.localizedDescription }
    private func menu() -> [MenuBarCommand] {
        var commands: [MenuBarCommand] = [
            .init(title: "管理暂存架", symbol: "tray.full", action: { [weak self] in self?.openManager?() }),
            .init(title: "新建暂存架", symbol: "plus", action: { [weak self] in self?.create() }),
            .init(title: "从剪贴板创建", symbol: "doc.on.clipboard", action: { [weak self] in self?.clipboardShelf() })
        ]
        if !error.isEmpty { commands.append(.init(title: error, enabled: false)) }
        let shelves = store?.shelves ?? []
        for shelf in shelves.filter(\.pinned) { commands.append(menuItem(shelf)) }
        let recent = shelves.filter { !$0.pinned && !$0.items.isEmpty }.prefix(10).map(menuItem)
        if !recent.isEmpty { commands.append(.init(title: "最近的暂存架", symbol: "clock", children: recent)) }
        commands.append(.init(title: "关闭所有暂存架", enabled: !windows.isEmpty, action: { [weak self] in
            for window in Array(self?.windows.values ?? Dictionary<UUID, DropShelfWindow>().values) { window.close() }
        }))
        return commands
    }
    private func menuItem(_ shelf: DropShelfStore.Shelf) -> MenuBarCommand {
        .init(title: "\(shelf.title) · \(shelf.items.count) 项", symbol: shelf.pinned ? "pin" : "tray", action: { [weak self] in self?.reveal(shelf.id) })
    }
    private func updateDragOperations() { windows.values.forEach { $0.updateDragOperations() } }
    private func tick() {
        refreshTick += 1
        if refreshTick % 40 == 0 { windows.values.forEach { $0.refreshFiles() } }
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            finishDragActivation()
            lastX = nil; direction = 0; turns = []; shookThisDrag = false; return
        }
        guard shakeEnabled, !shookThisDrag else { return }
        let board = NSPasteboard(name: .drag)
        guard board.types?.contains(where: { Self.types.contains($0) }) == true,
              board.data(forType: Self.marker) == nil else { return }
        let x = NSEvent.mouseLocation.x
        defer { lastX = x }
        guard let lastX, abs(x - lastX) > 12 else { return }
        let next: CGFloat = x > lastX ? 1 : -1
        let now = ProcessInfo.processInfo.systemUptime
        turns = turns.filter { now - $0 < 0.8 }
        if direction != 0 && next != direction { turns.append(now) }
        direction = next
        if turns.count >= 3 { shookThisDrag = true; createForDrag() }
    }
}

/// Separate the revocable import transaction from AppKit's drag-callback-only receiver.
/// Tests use controlled providers, never pretend a named clipboard is a physical drag.
protocol DropShelfReceiving {
    var expectedCount: Int { get }
    var names: [String] { get }
    func receive(at destination: URL, queue: OperationQueue, reader: @escaping (URL, Error?) -> Void)
}
private struct DropShelfNativePromise: DropShelfReceiving {
    let receiver: NSFilePromiseReceiver
    var expectedCount: Int { receiver.fileTypes.count }
    var names: [String] { receiver.fileNames }
    func receive(at destination: URL, queue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        receiver.receivePromisedFiles(atDestination: destination, options: [:], operationQueue: queue, reader: reader)
    }
}

/// Each batch has one private destination and a revocable commit token. Cancellation does not
/// assume another app has stopped writing; late results are ignored and cleaned after completion.
final class DropShelfImport {
    let id = UUID()
    let directory: URL
    let queue = OperationQueue()
    var valid = true
    var remaining: Int
    var results: [Int: [(URL, Error?)]] = [:]
    init(root: URL, count: Int) throws {
        directory = root.appendingPathComponent("Incoming", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
        remaining = count
        queue.maxConcurrentOperationCount = 2
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func finished() {
        remaining -= 1
        if remaining <= 0 { try? FileManager.default.removeItem(at: directory) }
    }
}

final class DropShelfTable: NSTableView {
    var shortcut: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if shortcut?(event) != true { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), shortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class DropShelfWindow: NSPanel, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let shelfID: UUID
    let store: DropShelfStore
    weak var controller: DropShelfController?
    let table = DropShelfTable()
    private let gridTable = DropShelfTable()
    private let gridPreviews = NSMapTable<NSUUID, DropShelfPreview>.strongToWeakObjects()
    private let contentScroll = NSScrollView()
    private let closeControl = NSButton()
    private let expandedTitle = NSTextField(labelWithString: "")
    private let sortControl = NSButton()
    private let viewControl = NSSegmentedControl()
    private var gridMode = true
    private var sortMode = 0
    private let capsule = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "拖入文件、文件夹、图片、链接或文字")
    private var batches: [UUID: DropShelfImport] = [:]
    private var rows: [DropShelfStore.Item] = []
    private var heldAccess: [URL] = []
    private var dragItems: [UUID] = []
    private(set) var receivedDrop = false
    private var receivedSequence: Int?
    private var refreshInProgress = false
    private var internalReorder = false
    private let preview = DropShelfPreview(frame: .zero)
    private let filename = NSButton(title: "暂存架", target: nil, action: nil)
    private let disclosure = NSButton()
    private let details = NSStackView()
    private var expanded = false
    private var detailWidth: NSLayoutConstraint?
    private var thumbnailKey: String?
    private var thumbnailRequest: QLThumbnailGenerator.Request?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), key(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override var canBecomeKey: Bool { true }
    init(id: UUID, store: DropShelfStore, controller: DropShelfController) {
        shelfID = id; self.store = store; self.controller = controller
        super.init(contentRect: NSRect(x: 0, y: 0, width: 210, height: 210), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Keylane · 暂存架"; isReleasedWhenClosed = false; delegate = self
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false; isMovableByWindowBackground = true
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        let effect = NSGlassEffectView(); effect.style = .regular; effect.cornerRadius = 28
        if #available(macOS 27.0, *), effect.responds(to: NSSelectorFromString("setEffectIsInteractive:")) { effect.setValue(false, forKey: "effectIsInteractive") }
        effect.wantsLayer = true; effect.layer?.cornerRadius = 28; effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true; effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        let surface = NSView(); effect.contentView = surface; contentView = effect
        configureRound(closeControl, symbol: "xmark", label: "关闭暂存架", action: #selector(closeShelf))
        configureRound(disclosure, symbol: "chevron.down", label: "展开暂存内容", action: #selector(disclosureAction))
        let spacer = NSView()
        configureRound(sortControl, symbol: "arrow.up.arrow.down", label: "排序", action: #selector(showSortMenu))
        expandedTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        viewControl.segmentCount = 2; viewControl.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "网格"), forSegment: 0)
        viewControl.setImage(NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "列表"), forSegment: 1)
        viewControl.selectedSegment = 0; viewControl.target = self; viewControl.action = #selector(changeViewMode)
        viewControl.setAccessibilityLabel("内容显示方式")
        expandedTitle.isHidden = true; sortControl.isHidden = true; viewControl.isHidden = true
        let top = NSStackView(views: [closeControl, expandedTitle, spacer, sortControl, viewControl, disclosure]); top.spacing = 6
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filename.target = self; filename.action = #selector(toggleDetails); filename.isBordered = false
        filename.font = .systemFont(ofSize: 12, weight: .medium); filename.lineBreakMode = .byTruncatingMiddle
        filename.wantsLayer = true; filename.layer?.cornerRadius = 14
        filename.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        filename.setAccessibilityLabel("展开暂存内容")
        preview.receive = { [weak self] in self?.receive($0, isDrag: true) ?? false }
        preview.begin = { [weak self] in self?.beginCompactDrag($0) ?? [] }
        preview.ended = { [weak self] in self?.finishDrag($0) }
        preview.operations = { [weak controller] in controller?.copyByDefault == true ? .copy : [.copy, .move] }
        preview.shortcut = { [weak self] in self?.key($0) ?? false }
        let scroll = contentScroll; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let column = NSTableColumn(identifier: .init("content")); column.title = "内容"; column.resizingMask = .autoresizingMask; table.addTableColumn(column); table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.rowHeight = 40; table.style = .fullWidth; table.backgroundColor = .clear
        table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes(DropShelfController.types + [DropShelfController.marker])
        table.setAccessibilityLabel("暂存内容，可拖出到其他应用")
        table.shortcut = { [weak self] event in self?.key(event) ?? false }
        let gridColumn = NSTableColumn(identifier: .init("grid")); gridColumn.resizingMask = .autoresizingMask; gridTable.addTableColumn(gridColumn); gridTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        gridTable.headerView = nil; gridTable.rowHeight = 132; gridTable.backgroundColor = .clear
        gridTable.style = .fullWidth; gridTable.selectionHighlightStyle = .none
        gridTable.dataSource = self; gridTable.delegate = self
        gridTable.registerForDraggedTypes(DropShelfController.types)
        gridTable.shortcut = { [weak self] in self?.key($0) ?? false }
        gridTable.setAccessibilityLabel("暂存内容网格")
        scroll.documentView = gridTable
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 10
        let finder = NSButton(title: "在 Finder 中显示", target: self, action: #selector(revealInFinder))
        finder.image = NSImage(systemSymbolName: "arrowshape.turn.up.right.circle", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 32, weight: .regular))
        finder.imagePosition = .imageAbove; finder.isBordered = false; finder.font = .systemFont(ofSize: 12)
        let finderRow = NSStackView(views: [finder, NSView()]); finderRow.alignment = .top
        finder.heightAnchor.constraint(equalToConstant: 68).isActive = true
        for view in [scroll, finderRow] { details.addArrangedSubview(view) }
        details.isHidden = true
        for view in [NSView(), filename, NSView()] { capsule.addArrangedSubview(view) }; capsule.distribution = .equalCentering
        let stack = NSStackView(views: [top, preview, capsule, details, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        surface.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        let grabber = NSView(); grabber.wantsLayer = true; grabber.layer?.cornerRadius = 2
        grabber.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        surface.addSubview(grabber); grabber.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([grabber.centerXAnchor.constraint(equalTo: surface.centerXAnchor), grabber.topAnchor.constraint(equalTo: surface.topAnchor, constant: 5), grabber.widthAnchor.constraint(equalToConstant: 36), grabber.heightAnchor.constraint(equalToConstant: 4)])
        for view in [top, preview, capsule, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        details.translatesAutoresizingMaskIntoConstraints = false
        detailWidth = details.widthAnchor.constraint(equalTo: stack.widthAnchor)
        for view in details.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        }
        status.isHidden = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -7),
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 7),
            stack.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -10),
            top.heightAnchor.constraint(equalToConstant: 32),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            filename.heightAnchor.constraint(equalToConstant: 28),
            filename.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
            filename.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            scroll.heightAnchor.constraint(equalToConstant: 155)
        ])
        updateDragOperations(); refresh()
    }
    func updateDragOperations() {
        let operations: NSDragOperation = controller?.copyByDefault == true ? .copy : [.copy, .move]
        table.setDraggingSourceOperationMask(operations, forLocal: false)
        table.setDraggingSourceOperationMask(operations, forLocal: true)
    }
    func refresh() {
        let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        rows = store.shelf(shelfID)?.items ?? []
        if sortMode == 1 { rows.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
        if sortMode == 2 { rows.sort { $0.kind.rawValue < $1.kind.rawValue } }
        table.reloadData(); gridTable.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false)
        updateCompactPreview()
        expandedTitle.stringValue = contentTitle
    }
    private func configureRound(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false; button.target = self; button.action = action
        button.wantsLayer = true; button.layer?.cornerRadius = 16
        button.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        button.contentTintColor = .labelColor; button.toolTip = label; button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }
    @objc private func closeShelf() { if expanded { toggleDetails() } else { close() } }
    @objc func toggleDetails() {
        expanded.toggle(); details.isHidden = !expanded; detailWidth?.isActive = expanded
        preview.isHidden = expanded; capsule.isHidden = expanded
        expandedTitle.isHidden = !expanded; sortControl.isHidden = !expanded; viewControl.isHidden = !expanded
        closeControl.image = NSImage(systemSymbolName: expanded ? "chevron.backward" : "xmark", accessibilityDescription: nil)
        closeControl.setAccessibilityLabel(expanded ? "返回收起的暂存架" : "关闭暂存架")
        closeControl.toolTip = expanded ? "返回收起的暂存架" : "关闭暂存架"
        disclosure.image = NSImage(systemSymbolName: expanded ? "slider.horizontal.3" : "chevron.down", accessibilityDescription: expanded ? "暂存架设置" : "展开暂存内容")
        disclosure.setAccessibilityLabel(expanded ? "暂存架设置" : "展开暂存内容")
        disclosure.toolTip = expanded ? "暂存架设置" : "展开暂存内容"
        resizeCard()
        makeFirstResponder(expanded ? table : preview)
    }
    func focusContents() { makeFirstResponder(expanded ? table : preview) }
    private func resizeCard() {
        let size = expanded ? NSSize(width: 420, height: 320) : NSSize(width: status.isHidden ? 210 : 246, height: status.isHidden ? 210 : 246)
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
    private func updateCompactPreview() {
        filename.title = rows.isEmpty ? "暂存架" : rows.count == 1 ? rows[0].title : contentTitle
        filename.toolTip = rows.map(\.title).joined(separator: "\n")
        preview.placeholder.isHidden = !rows.isEmpty
        let icons = rows.prefix(3).compactMap { item -> NSImage? in
            guard let url = try? store.resolve(item) else { return NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        preview.setBackingImages(icons)
        guard let item = rows.first else { preview.imageView.image = nil; thumbnailKey = nil; return }
        let key = item.id.uuidString + item.title
        guard key != thumbnailKey else { return }
        thumbnailKey = key
        if let thumbnailRequest { QLThumbnailGenerator.shared.cancel(thumbnailRequest) }
        preview.imageView.image = NSImage(systemSymbolName: item.kind == .link ? "link" : item.kind == .text ? "doc.text" : "doc", accessibilityDescription: item.title)
        do {
            guard let url = try store.resolve(item) else { return }
            let access = DropShelfFileAccess(url)
            let request = QLThumbnailGenerator.Request(fileAt: url, size: NSSize(width: 110, height: 90), scale: backingScaleFactor, representationTypes: .all)
            thumbnailRequest = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, access] representation, _ in
                DispatchQueue.main.async {
                    _ = access
                    guard let self, self.thumbnailKey == key, let representation else { return }
                    self.preview.imageView.image = representation.nsImage
                }
            }
        } catch { message(error.localizedDescription, failed: true) }
    }
    private func beginCompactDrag(_ event: NSEvent) -> [NSDraggingItem] {
        var items: [NSDraggingItem] = []
        do {
            for (index, item) in rows.enumerated() {
                let drag = NSDraggingItem(pasteboardWriter: try writer(item))
                let point = preview.convert(event.locationInWindow, from: nil)
                drag.setDraggingFrame(NSRect(x: point.x - 35 + CGFloat(index % 4) * 3, y: point.y - 30, width: 70, height: 60), contents: preview.imageView.image)
                items.append(drag)
            }
            dragItems = rows.map(\.id)
        } catch { releaseAccess(); message(error.localizedDescription, failed: true); return [] }
        return items
    }
    private func gridRow(_ row: Int) -> NSView {
        let stack = NSStackView(); stack.orientation = .horizontal; stack.spacing = 8; stack.distribution = .fillEqually
        for index in (row * 3)..<min(row * 3 + 3, rows.count) {
            let item = rows[index]
            let icon = DropShelfPreview(frame: NSRect(x: 0, y: 0, width: 110, height: 86))
            icon.placeholder.isHidden = true
            gridPreviews.setObject(icon, forKey: item.id as NSUUID)
            icon.showSelection(table.selectedRowIndexes.contains(index))
            let url = try? store.resolve(item)
            let access = url.map(DropShelfFileAccess.init)
            defer { withExtendedLifetime(access) {} }
            icon.imageView.image = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: item.kind == .link ? "link" : "doc.text", accessibilityDescription: nil)
            icon.selected = { [weak self] event in
                guard let self, let index = self.rows.firstIndex(where: { $0.id == item.id }) else { return }
                self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: event.modifierFlags.contains(.command))
            }
            icon.receive = { [weak self] in self?.receive($0, isDrag: true) ?? false }
            icon.operations = { [weak self] in self?.controller?.copyByDefault == true ? .copy : [.copy, .move] }
            icon.begin = { [weak self, weak icon] event in
                guard let self, let icon else { return [] }
                do {
                    let point = icon.convert(event.locationInWindow, from: nil)
                    let selected = self.selectedItems
                    let items = try selected.map { value -> NSDraggingItem in
                        let drag = NSDraggingItem(pasteboardWriter: try self.writer(value))
                        drag.setDraggingFrame(NSRect(x: point.x - 35, y: point.y - 30, width: 70, height: 60), contents: icon.imageView.image)
                        return drag
                    }
                    self.dragItems = selected.map(\.id)
                    return items
                } catch { self.message(error.localizedDescription, failed: true); return [] }
            }
            icon.ended = { [weak self] in self?.finishDrag($0) }
            icon.shortcut = { [weak self] in self?.key($0) ?? false }
            icon.heightAnchor.constraint(equalToConstant: 86).isActive = true
            let label = NSTextField(labelWithString: item.title); label.alignment = .center; label.lineBreakMode = .byTruncatingMiddle
            label.font = .systemFont(ofSize: 12, weight: .medium)
            let detail = NSTextField(labelWithString: ""); detail.alignment = .center; detail.font = .systemFont(ofSize: 10); detail.textColor = .secondaryLabelColor
            if let url, let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) {
                detail.stringValue = values.isDirectory == true ? "文件夹" : values.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "文件"
            }
            let tile = DropShelfTile(views: [icon, label, detail]); tile.preview = icon
            tile.orientation = .vertical; tile.spacing = 3; tile.alignment = .centerX
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 115).isActive = true
            stack.addArrangedSubview(tile)
        }
        while stack.arrangedSubviews.count < 3 { stack.addArrangedSubview(NSView()) }
        return stack
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        for (index, item) in rows.enumerated() {
            gridPreviews.object(forKey: item.id as NSUUID)?.showSelection(table.selectedRowIndexes.contains(index))
        }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard tableView === gridTable else { return true }
        // Grid rows contain three independent tiles; never keep a second row selection.
        table.deselectAll(nil)
        return false
    }
    private var contentTitle: String {
        let folders = !rows.isEmpty && rows.allSatisfy { item in
            guard let url = try? store.resolve(item) else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return "\(rows.count) 个" + (folders ? "文件夹" : "项目")
    }
    @objc private func disclosureAction() { if expanded { showShelfOptions() } else { toggleDetails() } }
    @objc private func changeViewMode() {
        gridMode = viewControl.selectedSegment == 0
        contentScroll.documentView = gridMode ? gridTable : table
        refresh()
    }
    @objc private func showSortMenu() {
        let menu = NSMenu()
        for (index, title) in ["原始顺序", "名称", "内容类型"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(changeSort(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = index == sortMode ? .on : .off; menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: sortControl)
    }
    @objc private func changeSort(_ sender: NSMenuItem) { sortMode = sender.tag; refresh() }
    private func showShelfOptions() {
        let menu = NSMenu()
        let entries: [(String, Selector)] = [
            (store.shelf(shelfID)?.pinned == true ? "取消固定" : "固定暂存架", #selector(pinFromMenu)),
            ("重命名暂存架…", #selector(renameFromMenu)), ("复制内容", #selector(copyContents)),
            ("粘贴内容", #selector(pasteContents)), ("清空暂存架", #selector(clearContents)),
            ("取消加载", #selector(cancelImports)), ("关闭暂存架", #selector(closeFromMenu))
        ]
        for (title, selector) in entries { let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: disclosure)
    }
    @objc private func pinFromMenu() {
        do { try store.pin(shelfID, value: store.shelf(shelfID)?.pinned != true); refresh() } catch { message(error.localizedDescription, failed: true) }
    }
    @objc private func closeFromMenu() { close() }
    @objc private func renameFromMenu() {
        let alert = NSAlert(); alert.messageText = "重命名暂存架"; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: store.shelf(shelfID)?.title ?? "暂存架"); field.frame.size = NSSize(width: 240, height: 24); alert.accessoryView = field
        alert.beginSheetModal(for: self) { [weak self] result in
            guard result == .alertFirstButtonReturn, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let self else { return }
            do { try self.store.rename(self.shelfID, title: field.stringValue); self.refresh() } catch { self.message(error.localizedDescription, failed: true) }
        }
    }
    @objc private func revealInFinder() {
        do {
            let urls = try selectedItems.compactMap { try store.resolve($0) }
            for url in urls where url.startAccessingSecurityScopedResource() { heldAccess.append(url) }
            guard !urls.isEmpty else { message("文字和链接可从复制菜单获取"); return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        } catch { message(error.localizedDescription, failed: true) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === gridTable ? (rows.count + 2) / 3 : rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === gridTable { return gridRow(row) }
        let item = rows[row]
        let symbol = item.kind == .image ? "photo" : item.kind == .link ? "link" : item.kind == .text ? "text.alignleft" : "doc"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.translatesAutoresizingMaskIntoConstraints = false; icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let label = NSTextField(labelWithString: item.title); label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize: 13)
        let view = NSStackView(views: [icon, label]); view.spacing = 10; return view
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === table ? (sortMode == 0 ? .move : []) : .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if info.draggingSource as? NSTableView === table {
            guard let text = info.draggingPasteboard.string(forType: DropShelfController.marker), let id = UUID(uuidString: text) else { return false }
            do { internalReorder = true; try store.reorder(shelfID, item: id, before: rows.indices.contains(row) ? rows[row].id : nil); refresh(); return true }
            catch { message(error.localizedDescription, failed: true); return false }
        }
        guard receivedSequence != info.draggingSequenceNumber else { return true }
        receivedSequence = info.draggingSequenceNumber
        return receive(info.draggingPasteboard, isDrag: true)
    }
    @discardableResult func receive(_ board: NSPasteboard, isDrag: Bool = false) -> Bool {
        guard isVisible, let items = board.pasteboardItems, !items.isEmpty else { return false }
        let promises: [DropShelfReceiving] = isDrag ? (board.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []).map(DropShelfNativePromise.init) : []
        let promiseAccepted = !promises.isEmpty && receivePromises(promises)
        var accepted = 0; var duplicates = 0; var failures: [String] = []
        for item in items {
            // A promised item may also advertise a URL or thumbnail; prefer its promise once.
            if !promises.isEmpty && item.types.contains(where: { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) }) { continue }
            do {
                let added: Bool
                let internalTransfer = item.string(forType: DropShelfController.marker).flatMap(UUID.init(uuidString:)) != nil
                if internalTransfer, let text = item.string(forType: .URL) { added = try store.addText(text, link: true, to: shelfID) }
                else if internalTransfer, let text = item.string(forType: .string) { added = try store.addText(text, to: shelfID) }
                else if let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL { added = try store.addFile(url, to: shelfID) }
                else if let image = DropShelfController.imageTypes.first(where: { item.types.contains($0.0) }), let data = item.data(forType: image.0) {
                    added = try store.addAsset(data, name: "图片." + image.1, kind: .image, to: shelfID)
                }
                else if let text = item.string(forType: .URL) { added = try store.addText(text, link: true, to: shelfID) }
                else if let text = item.string(forType: .string) { added = try store.addText(text, to: shelfID) }
                else { failures.append("不支持的拖入类型"); continue }
                if added { accepted += 1 } else { duplicates += 1 }
            } catch { failures.append(error.localizedDescription) }
        }
        refresh()
        message((promiseAccepted ? "正在接收文件；已加入 \(accepted) 项" : "已加入 \(accepted) 项") + (duplicates > 0 ? "，\(duplicates) 项已存在" : "") + (failures.isEmpty ? "" : "；" + failures.joined(separator: "；")), failed: !failures.isEmpty)
        let received = accepted + duplicates > 0 || promiseAccepted
        if isDrag && received { receivedDrop = true }
        return received
    }
    func receivePromises(_ promises: [DropShelfReceiving]) -> Bool {
        do {
            let count = promises.reduce(0) { $0 + max(1, $1.expectedCount) }
            guard count + rows.count <= 1000 else { throw DropShelfStore.Failure.limit }
            let batch = try DropShelfImport(root: store.directory, count: count)
            batches[batch.id] = batch; refresh(); message("正在接收文件…")
            for (position, receiver) in promises.enumerated() {
                receiver.receive(at: batch.directory, queue: batch.queue) { [weak self, batch, receiver] url, error in
                    DispatchQueue.main.async {
                        batch.results[position, default: []].append((url, error))
                        guard batch.remaining == 1 else { batch.remaining -= 1; return }
                        defer {
                            batch.finished()
                            self?.batches.removeValue(forKey: batch.id)
                            self?.refresh()
                        }
                        guard let self, batch.valid else { return }
                        var accepted = 0
                        var failures: [String] = []
                        // Complete a batch in source order, even if providers finish out of order.
                        for index in promises.indices {
                            let names = promises[index].names
                            let results = (batch.results[index] ?? []).sorted {
                                (names.firstIndex(of: $0.0.lastPathComponent) ?? 0) < (names.firstIndex(of: $1.0.lastPathComponent) ?? 0)
                            }
                            for (file, error) in results {
                                do {
                                    if let error { throw error }
                                    if try self.store.adoptPromise(file, from: batch.directory, to: self.shelfID) { accepted += 1 }
                                } catch { failures.append(error.localizedDescription) }
                            }
                        }
                        _ = receiver // Keep each provider alive through its asynchronous callback.
                        self.batches.removeValue(forKey: batch.id)
                        self.message("已接收 \(accepted) 项" + (failures.isEmpty ? "" : "；" + failures.joined(separator: "；")), failed: !failures.isEmpty)
                    }
                }
            }
            return true
        } catch { message(error.localizedDescription, failed: true); return false }
    }
    @objc func cancelImports() {
        for batch in batches.values { batch.valid = false }
        batches.removeAll(); refresh(); message("已取消加载；源文件保持原样")
    }
    @objc private func clearContents() {
        cancelImports()
        do { try store.remove(shelfID); refresh(); message("已清空暂存内容，未删除源文件") }
        catch { message(error.localizedDescription, failed: true) }
    }
    private var selectedItems: [DropShelfStore.Item] {
        let indexes = table.selectedRowIndexes
        return indexes.isEmpty ? rows : indexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
    }
    private func writer(_ item: DropShelfStore.Item) throws -> NSPasteboardItem {
        let output = NSPasteboardItem()
        output.setString(item.id.uuidString, forType: DropShelfController.marker)
        if let url = try store.resolve(item) {
            let scoped = url.startAccessingSecurityScopedResource()
            if scoped { heldAccess.append(url) }
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw DropShelfStore.Failure.unavailable }
            output.setString(url.absoluteString, forType: .fileURL)
            if item.kind == .image {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image), !type.isDynamic {
                    output.setData(data, forType: .init(type.identifier))
                }
            }
        } else if let value = item.value {
            output.setString(value, forType: .string)
            if item.kind == .link { output.setString(value, forType: .URL) }
            // Finder receives a real generated file; editors retain the original string/URL representation.
            let ext = item.kind == .link ? "webloc" : "txt"
            let url = store.assetsDirectory.appendingPathComponent(item.id.uuidString + "." + ext)
            if item.kind == .link { try PropertyListSerialization.data(fromPropertyList: ["URL": value], format: .xml, options: 0).write(to: url, options: .atomic) }
            else { try Data(value.utf8).write(to: url, options: .atomic) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            output.setString(url.absoluteString, forType: .fileURL)
        }
        return output
    }
    private func releaseAccess() { heldAccess.forEach { $0.stopAccessingSecurityScopedResource() }; heldAccess.removeAll() }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        do { return try writer(rows[row]) } catch { message(error.localizedDescription, failed: true); return nil }
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragItems = rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishDrag(operation)
    }
    private func finishDrag(_ operation: NSDragOperation) {
        releaseAccess(); dragItems = []
        if internalReorder { internalReorder = false; message("已调整暂存顺序"); return }
        if !operation.isEmpty {
            refreshFiles()
            message(operation.contains(.move) ? "已由目标接收（移动）" : "已由目标接收（复制）")
            if controller?.keepOpen != true { close() }
        } else { message("拖动已取消或目标未接收，暂存内容已保留") }
    }
    @objc private func copyContents() {
        do {
            let objects = try selectedItems.map(writer)
            guard !objects.isEmpty else { return }
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects(objects) else { throw DropShelfStore.Failure.unavailable }
            message("已复制 \(objects.count) 项")
        } catch { message(error.localizedDescription, failed: true) }
        // Scope grants are held until the shelf closes; pasteboard consumers can read asynchronously.
    }
    @objc private func pasteContents() { _ = receive(.general) }
    private func key(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": close(); return true
            case "c": copyContents(); return true
            case "v": pasteContents(); return true
            default: break
            }
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if expanded && gridMode && table.selectedRowIndexes.isEmpty {
                message("请先选择要移除的内容"); return true
            }
            cancelImports()
            do { try store.remove(shelfID, items: Set(selectedItems.map(\.id))); refresh(); message("已从暂存架移除，未删除源文件") }
            catch { message(error.localizedDescription, failed: true) }; return true
        }
        if event.keyCode == 49 {
            do {
                let urls = try selectedItems.compactMap { try store.resolve($0) }
                let access = DropShelfPreviewAccess(urls)
                if !urls.isEmpty { FilePreview.shared.show(urls, retaining: access, owner: .dropShelf(shelfID)) }
            }
            catch { message(error.localizedDescription, failed: true) }; return true
        }
        return false
    }
    func refreshFiles() {
        guard !refreshInProgress, dragItems.isEmpty else { return }
        refreshInProgress = true; defer { refreshInProgress = false }
        // Resolve bookmarks again rather than retaining a stale path after a Finder move/rename.
        var missing = Set<UUID>()
        for item in rows where item.kind == .file || item.asset != nil {
            do {
                let resolved: URL?
                do { resolved = try store.resolve(item) }
                catch {
                    // Bookmark resolution can report "not found" when traversal is denied.
                    // Confirm against the saved path instead of deleting on that error alone.
                    let cocoa = error as NSError
                    guard cocoa.domain == NSCocoaErrorDomain,
                          [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code),
                          let saved = item.url else {
                        message(error.localizedDescription, failed: true); continue
                    }
                    resolved = saved
                }
                if let url = resolved {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    // Boolean existence checks also return false for permission/volume errors.
                    // Let the error-aware path below remove only definite missing-file errors.
                    _ = try FileManager.default.attributesOfItem(atPath: url.path)
                    try store.refreshReference(item, in: shelfID, resolved: url)
                }
            } catch {
                let cocoa = error as NSError
                if cocoa.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) { missing.insert(item.id) }
                else { message(error.localizedDescription, failed: true) }
            }
        }
        refresh()
        if !missing.isEmpty {
            do { try store.remove(shelfID, items: missing); refresh(); message("\(missing.count) 项文件已消失，已从暂存架移除", failed: true) }
            catch { message(error.localizedDescription, failed: true) }
        }
    }
    var feedbackText: String { status.stringValue }
    private func message(_ text: String, failed: Bool = false) {
        status.stringValue = text; status.textColor = failed ? .systemRed : .secondaryLabelColor; status.setAccessibilityValue(text)
        let show = failed || !batches.isEmpty
        if status.isHidden == show { status.isHidden = !show; resizeCard() }
        filename.toolTip = text
    }
    func windowWillClose(_ notification: Notification) { cancelImports(); releaseAccess(); FilePreview.shared.dismiss(owner: .dropShelf(shelfID)); controller?.closed(self) }
}

private final class DropShelfFileAccess {
    let url: URL
    let scoped: Bool
    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

private final class DropShelfPreviewAccess {
    let grants: [DropShelfFileAccess]
    init(_ urls: [URL]) { grants = urls.map(DropShelfFileAccess.init) }
}
