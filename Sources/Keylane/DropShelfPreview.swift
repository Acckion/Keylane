import AppKit

/// Match the drawn image or text instead of the full layout rectangle around it.
private enum DropShelfContentHit {
    static func image(_ view: NSImageView, at windowPoint: NSPoint) -> Bool {
        guard !view.isHiddenOrHasHiddenAncestor, let image = view.image,
              image.size.width > 0, image.size.height > 0, !view.bounds.isEmpty else { return false }
        let fit = min(view.bounds.width / image.size.width, view.bounds.height / image.size.height)
        let scale = view.imageScaling == .scaleProportionallyDown ? min(1, fit) : fit
        let width = image.size.width * scale
        let height = image.size.height * scale
        let drawing = NSRect(x: view.bounds.midX - width / 2, y: view.bounds.midY - height / 2, width: width, height: height)
        return drawing.contains(view.convert(windowPoint, from: nil))
    }

    static func text(_ field: NSTextField, at windowPoint: NSPoint) -> Bool {
        guard !field.isHiddenOrHasHiddenAncestor, !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let width = min(field.bounds.width, field.intrinsicContentSize.width)
        let x = field.alignment == .center ? field.bounds.midX - width / 2 : field.bounds.minX
        let drawing = NSRect(x: x, y: field.bounds.minY, width: width, height: field.bounds.height)
        return drawing.contains(field.convert(windowPoint, from: nil))
    }
}

/// Keep the thumbnail and filename on the same drag source; leave tile padding free.
final class DropShelfTile: NSStackView {
    weak var preview: DropShelfPreview?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard let preview else { return hit }
        let windowPoint = superview?.convert(point, to: nil) ?? point
        if preview.containsImage(at: windowPoint) || arrangedSubviews.contains(where: {
            guard let field = $0 as? NSTextField else { return false }
            return DropShelfContentHit.text(field, at: windowPoint)
        }) { return preview }
        return self
    }
}

final class DropShelfListItemView: NSStackView {
    func containsFile(at point: NSPoint) -> Bool {
        arrangedSubviews.contains {
            if let image = $0 as? NSImageView { return DropShelfContentHit.image(image, at: point) }
            if let field = $0 as? NSTextField { return DropShelfContentHit.text(field, at: point) }
            return false
        }
    }
}

/// A card-wide drop destination. Keep automatic shelves alive until AppKit finishes the drop.
class DropShelfDropView: NSView {
    var receive: ((NSPasteboard) -> Bool)?
    var dragActivity: ((Bool) -> Void)?
    private var sequence: Int?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropShelfController.types)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation: NSDragOperation = (sender.draggingSource as? NSView)?.window === window ? [] : .copy
        dragActivity?(!operation.isEmpty)
        return operation
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragActivity?(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { dragActivity?(false) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dragActivity?(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dragActivity?(false) }
        guard sequence != sender.draggingSequenceNumber else { return true }
        sequence = sender.draggingSequenceNumber
        return receive?(sender.draggingPasteboard) ?? false
    }
}

/// The side and display that anchor a shelf after a qualifying drop.
struct DropShelfDock {
    enum Edge: CaseIterable {
        case left, right, bottom, top

        var symbol: String {
            switch self {
            case .left: return "chevron.right"
            case .right: return "chevron.left"
            case .bottom: return "chevron.up"
            case .top: return "chevron.down"
            }
        }
    }

    static let strip: CGFloat = 28
    let edge: Edge
    let area: NSRect

    func frame(for shelf: NSRect) -> NSRect {
        var target = shelf
        switch edge {
        case .left: target.origin.x = area.minX + Self.strip - shelf.width
        case .right: target.origin.x = area.maxX - Self.strip
        case .bottom: target.origin.y = area.minY + Self.strip - shelf.height
        case .top: target.origin.y = area.maxY - Self.strip
        }
        if edge == .left || edge == .right {
            target.origin.y = max(area.minY, min(target.minY, area.maxY - target.height))
        } else {
            target.origin.x = max(area.minX, min(target.minX, area.maxX - target.width))
        }
        return target
    }

    static func target(for shelf: NSRect, in area: NSRect, neighboring: [NSRect] = []) -> Self? {
        let visible: [(Edge, CGFloat)] = [
            (.left, (shelf.maxX - area.minX) / shelf.width),
            (.right, (area.maxX - shelf.minX) / shelf.width),
            (.bottom, (shelf.maxY - area.minY) / shelf.height),
            (.top, (area.maxY - shelf.minY) / shelf.height)
        ]
        for (edge, fraction) in visible.sorted(by: { $0.1 < $1.1 }) where fraction <= 0.52 {
            let dock = Self(edge: edge, area: area)
            let target = dock.frame(for: shelf)
            if neighboring.allSatisfy({ $0.intersection(target).isEmpty }) { return dock }
        }
        return nil
    }
}

/// The only external drop destination. It sits above glass and controls so that
/// AppKit sees one full-card rectangle. Ordinary mouse input is forwarded below.
final class DropShelfCaptureOverlay: DropShelfDropView {
    weak var underlying: NSView?
    private weak var mouseTarget: NSView?
    private var windowDrag: (mouse: NSPoint, origin: NSPoint)?
    private var didMoveWindow = false
    private(set) var dock: DropShelfDock?
    private let dockHandle = NSImageView()
    private var dockAnimation: Timer?
    private weak var hoveredButton: DropShelfHoverButton?
    private var hoverArea: NSTrackingArea?
    override init(frame: NSRect) {
        super.init(frame: frame)
        dockHandle.imageScaling = .scaleNone
        dockHandle.contentTintColor = .tertiaryLabelColor
        dockHandle.isHidden = true
        dockHandle.setAccessibilityElement(false)
        addSubview(dockHandle)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard let dock else { return }
        let halfStrip = DropShelfDock.strip / 2
        var center = NSPoint(x: bounds.midX, y: bounds.midY)
        switch dock.edge {
        case .left: center.x = bounds.maxX - halfStrip
        case .right: center.x = bounds.minX + halfStrip
        case .bottom: center.y = bounds.maxY - halfStrip
        case .top: center.y = bounds.minY + halfStrip
        }
        dockHandle.frame = NSRect(x: center.x - 14, y: center.y - 22, width: 28, height: 44)
    }

    private func showDock(_ state: DropShelfDock?) {
        dock = state
        underlying?.isHidden = state != nil
        dockHandle.isHidden = state == nil
        dockHandle.image = state.flatMap { NSImage(systemSymbolName: $0.edge.symbol, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .bold))
        setAccessibilityRole(.button)
        setAccessibilityLabel(state == nil ? nil : "拉回暂存架")
        setAccessibilityElement(state != nil)
        needsLayout = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard dock != nil else { return false }
        restoreDockedShelf()
        return true
    }

    func restoreDockedShelf(animated: Bool = true) {
        guard let dock, let window else { return }
        let usable = NSScreen.screens.first { $0.frame == dock.area }?.visibleFrame ?? dock.area
        let frame = window.frame
        let origin = NSPoint(x: max(usable.minX, min(frame.minX, usable.maxX - frame.width)),
                             y: max(usable.minY, min(frame.minY, usable.maxY - frame.height)))
        showDock(nil)
        moveWindow(to: origin, animated: animated)
    }

    private func moveWindow(to origin: NSPoint, animated: Bool = true, completion: (() -> Void)? = nil) {
        cancelDockAnimation()
        guard let window else { return }
        let start = window.frame.origin
        guard animated, window.isVisible, start != origin, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.setFrameOrigin(origin)
            completion?()
            return
        }
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak window] timer in
            guard let self, let window, window.isVisible else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / 0.22)
            let eased = 1 - pow(1 - progress, 3)
            window.setFrameOrigin(NSPoint(x: start.x + (origin.x - start.x) * eased,
                                          y: start.y + (origin.y - start.y) * eased))
            if progress == 1 {
                self.cancelDockAnimation()
                completion?()
            }
        }
        dockAnimation = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelDockAnimation() {
        dockAnimation?.invalidate()
        dockAnimation = nil
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    func forwardedView(at windowPoint: NSPoint) -> NSView? {
        guard dock == nil, let underlying else { return nil }
        return underlying.hitTest(underlying.superview?.convert(windowPoint, from: nil) ?? windowPoint)
    }
    func primaryMouseTarget(at point: NSPoint) -> NSView? {
        var view = forwardedView(at: point)
        while let hit = view {
            if let preview = hit as? DropShelfPreview { return preview }
            if hit is NSButton || hit is NSScroller { return hit }
            // NSTableView can return itself from hitTest even when a cell is visible.
            if let table = hit as? NSTableView {
                let row = table.row(at: table.convert(point, from: nil))
                guard row >= 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
                let cellHit = cell.hitTest(cell.superview?.convert(point, from: nil) ?? point)
                if let control = cellHit as? NSButton { return control }
                if let preview = cellHit as? DropShelfPreview { return preview }
                return (cell as? DropShelfListItemView)?.containsFile(at: point) == true ? table : nil
            }
            if let row = hit as? DropShelfListItemView {
                guard row.containsFile(at: point) else { return nil }
                var parent = row.superview
                while let ancestor = parent {
                    if ancestor is NSTableView { return ancestor }
                    parent = ancestor.superview
                }
                return nil
            }
            view = hit.superview
        }
        return nil
    }
    private func target(_ event: NSEvent) -> NSView? { forwardedView(at: event.locationInWindow) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) {
        let target = primaryMouseTarget(at: event.locationInWindow)
        updateHover(target as? DropShelfHoverButton)
        (target == nil ? NSCursor.openHand : .arrow).set()
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        updateHover(nil)
        NSCursor.arrow.set()
    }

    private func updateHover(_ button: DropShelfHoverButton?) {
        guard hoveredButton !== button else { return }
        hoveredButton?.isHovered = false
        hoveredButton = button
        button?.isHovered = true
    }

    override func mouseDown(with event: NSEvent) {
        cancelDockAnimation()
        windowDrag = nil
        didMoveWindow = false
        let target = primaryMouseTarget(at: event.locationInWindow)
        updateHover(target as? DropShelfHoverButton)
        mouseTarget = target
        if let target {
            target.mouseDown(with: event)
        } else if let window {
            windowDrag = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let windowDrag, let window else { mouseTarget?.mouseDragged(with: event); return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        guard didMoveWindow || hypot(mouse.x - windowDrag.mouse.x, mouse.y - windowDrag.mouse.y) >= 3 else { return }
        didMoveWindow = true
        if dock != nil { showDock(nil) }
        NSCursor.closedHand.set()
        let origin = NSPoint(x: windowDrag.origin.x + mouse.x - windowDrag.mouse.x,
                             y: windowDrag.origin.y + mouse.y - windowDrag.mouse.y)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
    }
    override func mouseUp(with event: NSEvent) {
        if windowDrag != nil, let window {
            if !didMoveWindow, dock != nil {
                restoreDockedShelf()
            } else if didMoveWindow {
                let mouse = window.convertPoint(toScreen: event.locationInWindow)
                let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? window.screen
                if let screen, let target = DropShelfDock.target(for: window.frame, in: screen.frame,
                        neighboring: NSScreen.screens.filter { $0 != screen }.map(\.frame)) {
                    moveWindow(to: target.frame(for: window.frame).origin) { [weak self] in
                        self?.showDock(target)
                    }
                }
            }
            mouseMoved(with: event)
        }
        windowDrag = nil
        mouseTarget?.mouseUp(with: event)
        mouseTarget = nil
    }
    override func rightMouseDown(with event: NSEvent) { target(event)?.rightMouseDown(with: event) }
    override func scrollWheel(with event: NSEvent) { target(event)?.scrollWheel(with: event) }
}

/// Compact preview, serving as both a drop destination and drag source.
final class DropShelfPreview: DropShelfDropView, NSDraggingSource {
    let imageView = NSImageView()
    private let backImages = [NSImageView(), NSImageView()]
    func setImages(_ images: [NSImage]) {
        imageView.image = images.first
        for (index, view) in backImages.enumerated() { view.image = images.count > index + 1 ? images[index + 1] : nil; view.isHidden = view.image == nil }
    }
    let placeholder = NSTextField(wrappingLabelWithString: "拖放到此处")
    func showSelection(_ selected: Bool) {
        wantsLayer = true; layer?.cornerRadius = 10
        layer?.borderWidth = selected ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        layer?.backgroundColor = selected ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
    }
    var selected: ((NSEvent) -> Void)?
    var begin: ((NSEvent) -> [NSDraggingItem])?
    var ended: ((NSDragOperation) -> Void)?
    var operations: () -> NSDragOperation = { [.copy, .move] }
    override var acceptsFirstResponder: Bool { true }
    var shortcut: ((NSEvent) -> Bool)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView); imageView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center; placeholder.textColor = .secondaryLabelColor; placeholder.font = .systemFont(ofSize: 13)
        for (index, image) in backImages.enumerated() {
            image.imageScaling = .scaleProportionallyUpOrDown
            addSubview(image, positioned: .below, relativeTo: index == 0 ? imageView : backImages[0]); image.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([image.widthAnchor.constraint(equalTo: imageView.widthAnchor), image.heightAnchor.constraint(equalTo: imageView.heightAnchor), image.centerXAnchor.constraint(equalTo: centerXAnchor, constant: index == 0 ? -4 : 5), image.centerYAnchor.constraint(equalTo: centerYAnchor, constant: index == 0 ? 3 : 5)])
            image.frameCenterRotation = index == 0 ? -4 : 5
        }
        addSubview(placeholder); placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor), imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 110),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 104),
            imageView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -8),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -12)
        ])
        let imageHeight = imageView.heightAnchor.constraint(equalToConstant: 104)
        imageHeight.priority = .defaultHigh; imageHeight.isActive = true
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("暂存内容预览，可拖入或拖出")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func containsImage(at point: NSPoint) -> Bool {
        ([imageView] + backImages).contains { DropShelfContentHit.image($0, at: point) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        let windowPoint = superview?.convert(point, to: nil) ?? point
        return containsImage(at: windowPoint) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); selected?(event) }
    override func mouseDragged(with event: NSEvent) {
        guard let items = begin?(event), !items.isEmpty else { return }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func keyDown(with event: NSEvent) { if shortcut?(event) != true { super.keyDown(with: event) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), shortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { operations() }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { ended?(operation) }
}

/// Leave breathing room on both sides of the compact title and its chevron.
final class DropShelfCapsuleCell: NSButtonCell {
    private let horizontalInset: CGFloat = 10

    override var cellSize: NSSize {
        var size = super.cellSize
        size.width += 2 * horizontalInset
        return size
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame.insetBy(dx: horizontalInset, dy: 0), in: controlView)
    }
}

final class DropShelfHoverButton: NSButton {
    var isHovered = false { didSet { updateHighlight() } }
    var showsSelection = false { didSet { updateHighlight() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHighlight()
    }

    private func updateHighlight() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovered ? NSColor.tertiaryLabelColor.cgColor
                : showsSelection ? NSColor.quaternaryLabelColor.cgColor : nil
        }
    }
}
