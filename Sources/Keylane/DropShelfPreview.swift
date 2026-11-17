import AppKit

/// Compact shelf surface, serving both as a native drop destination and drag source.
final class DropShelfPreview: NSView, NSDraggingSource {
    let imageView = NSImageView()
    let placeholder = NSTextField(wrappingLabelWithString: "拖放到此处")
    var receive: ((NSPasteboard) -> Bool)?
    var begin: ((NSEvent) -> [NSDraggingItem])?
    var ended: ((NSDragOperation) -> Void)?
    var operations: () -> NSDragOperation = { [.copy, .move] }
    private var sequence: Int?
    override var acceptsFirstResponder: Bool { true }
    var shortcut: ((NSEvent) -> Bool)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyDown
        placeholder.alignment = .center; placeholder.textColor = .secondaryLabelColor; placeholder.font = .systemFont(ofSize: 13)
        for view in [imageView, placeholder] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor), imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 100), imageView.heightAnchor.constraint(equalToConstant: 85),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -12)
        ])
        registerForDraggedTypes(DropShelfController.types)
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("暂存内容预览，可拖入或拖出")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
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
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { sender.draggingSource as? NSView === self ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard sequence != sender.draggingSequenceNumber else { return true }
        sequence = sender.draggingSequenceNumber
        return receive?(sender.draggingPasteboard) ?? false
    }
}
