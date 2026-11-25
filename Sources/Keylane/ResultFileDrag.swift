import AppKit
import SwiftUI

/// Access is acquired only for a deliberate drag and retained through the native session.
final class ResultFileDragPayload {
    let urls: [URL]
    private let retained: AnyObject?
    private let scopes: [URL]

    init(urls: [URL], scopes: [URL] = [], retaining: AnyObject? = nil) throws {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let acquired = scopes.filter { $0.startAccessingSecurityScopedResource() }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) && FileManager.default.isReadableFile(atPath: $0.path) }) else {
            acquired.forEach { $0.stopAccessingSecurityScopedResource() }
            throw CocoaError(.fileReadNoPermission)
        }
        self.urls = urls
        self.retained = retaining
        self.scopes = acquired
    }
    deinit { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
}

struct ResultFileDrag {
    let id: AnyHashable
    let select: () -> Void
    let prepare: (@escaping (ResultFileDragPayload?) -> Void) -> Void
}

struct ResultFileDragSurface: NSViewRepresentable {
    let source: ResultFileDrag
    let click: () -> Void
    func makeNSView(context: Context) -> ResultFileDragView { ResultFileDragView() }
    func updateNSView(_ view: ResultFileDragView, context: Context) {
        if view.source?.id != source.id { view.cancelPreparation() }
        view.source = source; view.click = click
    }
    static func dismantleNSView(_ view: ResultFileDragView, coordinator: ()) { view.cancelPreparation() }
}

/// The SwiftUI button keeps its layout, keyboard and accessibility behavior. This transparent
/// surface handles the mouse threshold so a drag never also activates the row's command.
final class ResultFileDragView: NSView, NSDraggingSource {
    private static var activeSource: ResultFileDragView?
    var source: ResultFileDrag?
    var click: (() -> Void)?
    private var press: NSPoint?
    private var latestEvent: NSEvent?
    private var dragged = false
    private var preparing = false
    private var token = UUID()
    private var payload: ResultFileDragPayload?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let type = NSApp.currentEvent?.type, [.scrollWheel, .rightMouseDown, .rightMouseUp].contains(type) { return nil }
        return super.hitTest(point)
    }
    override func mouseDown(with event: NSEvent) {
        cancelPreparation()
        press = convert(event.locationInWindow, from: nil); dragged = false
    }
    override func mouseUp(with event: NSEvent) {
        let activate = press != nil && !dragged && bounds.contains(convert(event.locationInWindow, from: nil))
        cancelPreparation()
        if activate { click?() }
    }
    override func mouseDragged(with event: NSEvent) {
        latestEvent = event
        guard let press, let source, payload == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - press.x, point.y - press.y) >= 5, !preparing, !dragged else { return }
        dragged = true; preparing = true
        let generation = token
        source.select()
        source.prepare { [weak self] payload in
            guard let self, self.token == generation else { return }
            self.preparing = false
            guard let payload, let event = self.latestEvent, let window = self.window, window.isVisible,
                  NSEvent.pressedMouseButtons & 1 != 0 else { return }
            self.payload = payload
            Self.activeSource = self // SwiftUI may dispose the row when the launcher hides.
            let point = self.convert(event.locationInWindow, from: nil)
            let items = payload.urls.map { url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
                                      contents: NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            let session = self.beginDraggingSession(with: items, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
        }
    }
    func cancelPreparation() { token = UUID(); preparing = false; press = nil; latestEvent = nil }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        payload = nil; cancelPreparation()
        if Self.activeSource === self { Self.activeSource = nil }
    }
}
