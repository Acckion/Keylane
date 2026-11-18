import AppKit

/// Labels and tile padding use the icon's selection and drag handling as well.
final class DropShelfTile: NSStackView {
    weak var preview: DropShelfPreview?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return preview
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

/// The only external drop destination. It sits above glass and controls so that
/// AppKit sees one full-card rectangle. Ordinary mouse input is forwarded below.
final class DropShelfCaptureOverlay: DropShelfDropView {
    weak var underlying: NSView?
    private weak var mouseTarget: NSView?
    private weak var hoveredButton: DropShelfHoverButton?
    private var hoverArea: NSTrackingArea?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    func forwardedView(at windowPoint: NSPoint) -> NSView? {
        guard let underlying else { return nil }
        return underlying.hitTest(underlying.superview?.convert(windowPoint, from: nil) ?? windowPoint)
    }
    private func target(_ event: NSEvent) -> NSView? { forwardedView(at: event.locationInWindow) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) { updateHover(target(event) as? DropShelfHoverButton) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { updateHover(nil) }

    private func updateHover(_ button: DropShelfHoverButton?) {
        guard hoveredButton !== button else { return }
        hoveredButton?.isHovered = false
        hoveredButton = button
        button?.isHovered = true
    }

    override func mouseDown(with event: NSEvent) {
        let target = target(event)
        updateHover(target as? DropShelfHoverButton)
        guard let target else { return }
        mouseTarget = target
        if target is NSControl || target is DropShelfPreview || target is NSScrollView || target.enclosingScrollView != nil {
            target.mouseDown(with: event)
        } else {
            mouseTarget = nil
            window?.performDrag(with: event)
        }
    }
    override func mouseDragged(with event: NSEvent) { mouseTarget?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { mouseTarget?.mouseUp(with: event); mouseTarget = nil }
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
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
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
