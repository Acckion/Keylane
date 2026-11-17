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
    private let preferences: UserDefaults
    private let directory: URL
    private(set) var store: DropShelfStore?
    private var windows: [UUID: DropShelfWindow] = [:]
    private weak var registry: MenuBarRegistry?
    private var timer: Timer?
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
        windows.removeValue(forKey: window.shelfID)
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
        if turns.count >= 3 { shookThisDrag = true; create(activate: false) }
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
    private let status = NSTextField(wrappingLabelWithString: "拖入文件、文件夹、图片、链接或文字")
    private let titleField = NSTextField(string: "")
    private let pinButton = NSButton(checkboxWithTitle: "固定", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var batches: [UUID: DropShelfImport] = [:]
    private var rows: [DropShelfStore.Item] = []
    private var heldAccess: [URL] = []
    private var dragItems: [UUID] = []
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
        if firstResponder !== titleField.currentEditor(), event.modifierFlags.contains(.command), key(event) { return true }
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
        let closeButton = roundButton(symbol: "xmark", label: "关闭暂存架", action: #selector(closeShelf))
        configureRound(disclosure, symbol: "chevron.down", label: "展开暂存内容", action: #selector(toggleDetails))
        let spacer = NSView()
        let top = NSStackView(views: [closeButton, spacer, disclosure]); top.spacing = 4
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
        titleField.placeholderString = "暂存架名称"; titleField.target = self; titleField.action = #selector(renameShelf)
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.setAccessibilityLabel("暂存架名称")
        pinButton.target = self; pinButton.action = #selector(togglePin)
        let header = NSStackView(views: [titleField, pinButton]); header.spacing = 10
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let column = NSTableColumn(identifier: .init("content")); column.title = "内容"; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 40; table.style = .fullWidth; table.backgroundColor = .clear
        table.allowsMultipleSelection = true; table.dataSource = self; table.delegate = self
        table.registerForDraggedTypes(DropShelfController.types + [DropShelfController.marker])
        table.setAccessibilityLabel("暂存内容，可拖出到其他应用")
        table.shortcut = { [weak self] event in self?.key(event) ?? false }
        scroll.documentView = table
        let copy = NSButton(title: "复制", target: self, action: #selector(copyContents))
        let paste = NSButton(title: "粘贴", target: self, action: #selector(pasteContents))
        let clear = NSButton(title: "清空", target: self, action: #selector(clearContents))
        let cancel = NSButton(title: "取消加载", target: self, action: #selector(cancelImports))
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        let buttons = NSStackView(views: [copy, paste, clear, cancel, progress]); buttons.spacing = 6
        buttons.distribution = .fillProportionally
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        details.orientation = .vertical; details.alignment = .leading; details.spacing = 10
        for view in [header, scroll, buttons] { details.addArrangedSubview(view) }
        details.isHidden = true
        let capsule = NSStackView(views: [NSView(), filename, NSView()]); capsule.distribution = .equalCentering
        let stack = NSStackView(views: [top, preview, capsule, details, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        surface.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [top, preview, capsule, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        details.translatesAutoresizingMaskIntoConstraints = false
        detailWidth = details.widthAnchor.constraint(equalTo: stack.widthAnchor)
        for view in [header, scroll, buttons] {
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
            scroll.heightAnchor.constraint(equalToConstant: 150)
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
        if firstResponder !== titleField.currentEditor() { titleField.stringValue = store.shelf(shelfID)?.title ?? "暂存架" }
        pinButton.state = store.shelf(shelfID)?.pinned == true ? .on : .off
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false)
        updateCompactPreview()
        progress.isHidden = batches.isEmpty
        if batches.isEmpty { progress.stopAnimation(nil) } else { progress.startAnimation(nil) }
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
    private func roundButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(); configureRound(button, symbol: symbol, label: label, action: action); return button
    }
    @objc private func closeShelf() { close() }
    @objc private func toggleDetails() {
        expanded.toggle(); details.isHidden = !expanded; detailWidth?.isActive = expanded
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: expanded ? "收起暂存内容" : "展开暂存内容")
        disclosure.setAccessibilityLabel(expanded ? "收起暂存内容" : "展开暂存内容")
        resizeCard()
        makeFirstResponder(expanded ? table : preview)
    }
    func focusContents() { makeFirstResponder(expanded ? table : preview) }
    private func resizeCard() {
        let size = expanded ? NSSize(width: 370, height: 450) : NSSize(width: status.isHidden ? 210 : 246, height: status.isHidden ? 210 : 246)
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
    private func updateCompactPreview() {
        filename.title = rows.isEmpty ? "暂存架" : rows.count == 1 ? rows[0].title : "\(rows.count) 个项目"
        filename.toolTip = rows.map(\.title).joined(separator: "\n")
        preview.placeholder.isHidden = !rows.isEmpty
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
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let symbol = item.kind == .image ? "photo" : item.kind == .link ? "link" : item.kind == .text ? "text.alignleft" : "doc"
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.translatesAutoresizingMaskIntoConstraints = false; icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let label = NSTextField(labelWithString: item.title); label.lineBreakMode = .byTruncatingMiddle; label.font = .systemFont(ofSize: 13)
        let view = NSStackView(views: [icon, label]); view.spacing = 10; return view
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === table ? .move : .copy
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
                if let text = item.string(forType: .fileURL), let url = URL(string: text), url.isFileURL { added = try store.addFile(url, to: shelfID) }
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
        return accepted + duplicates > 0 || promiseAccepted
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
    @objc private func renameShelf() {
        do { try store.rename(shelfID, title: titleField.stringValue); refresh() } catch { message(error.localizedDescription, failed: true) }
    }
    @objc private func togglePin() {
        do { try store.pin(shelfID, value: pinButton.state == .on); refresh() } catch { message(error.localizedDescription, failed: true) }
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
                if let url = try store.resolve(item) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if !FileManager.default.fileExists(atPath: url.path) { missing.insert(item.id) }
                    else { try store.refreshReference(item, in: shelfID, resolved: url) }
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
