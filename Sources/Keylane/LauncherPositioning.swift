import AppKit

/// A shared top anchor independent of compact/expanded height or interface scale.
enum LauncherPositioning {
    static func target(size: NSSize, in area: NSRect) -> NSRect {
        let top = area.maxY - area.height * 0.18
        return NSRect(x: area.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
    }
}

private final class AlignmentGuidesView: NSView {
    var target = NSRect.zero
    var matchX = false
    var matchY = false
    override func draw(_ dirtyRect: NSRect) {
        for x in [target.minX, target.maxX] {
            drawLine(from: NSPoint(x: x, y: bounds.minY), to: NSPoint(x: x, y: bounds.maxY), matched: matchX)
        }
        drawLine(from: NSPoint(x: bounds.minX, y: target.maxY), to: NSPoint(x: bounds.maxX, y: target.maxY), matched: matchY)
    }
    private func drawLine(from: NSPoint, to: NSPoint, matched: Bool) {
        (matched ? NSColor.systemBlue : NSColor.white.withAlphaComponent(0.7)).setStroke()
        let line = NSBezierPath()
        line.lineWidth = matched ? 2 : 1
        line.setLineDash([6, 5], count: 2, phase: 0)
        line.move(to: from); line.line(to: to); line.stroke()
    }
}

/// A noninteractive overlay exists only while dragging the launcher, on the active display.
final class LauncherDragGuides {
    private weak var launcher: NSWindow?
    private var overlay: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private var willMoveObserver: NSObjectProtocol?
    private var trackingTimer: Timer?
    private var initialFrame = NSRect.zero
    private var initialMouse = NSPoint.zero
    private var applyingSnap = false
    private var ownsDrag = false
    private let guidesView = AlignmentGuidesView()
    private var localUp: Any?
    private var globalUp: Any?
    private var dragging = false
    private var matchX = false
    private var matchY = false
    private let threshold: CGFloat = 12
    private let releaseThreshold: CGFloat = 24

    init(window: NSWindow) {
        launcher = window
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in self?.moved() }
        willMoveObserver = NotificationCenter.default.addObserver(forName: NSWindow.willMoveNotification, object: window, queue: .main) { [weak self] _ in self?.beginTracking() }
        localUp = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, event.window === launcher { beginTracking() }
            if event.type == .leftMouseDragged, ownsDrag {
                moved()
                return nil
            }
            if event.type == .leftMouseUp {
                let consumed = ownsDrag
                finish()
                if consumed { return nil }
            }
            return event
        }
        globalUp = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.finish() }
    }
    /// Own movement during the drag: native movement must not paint an unsnapped
    /// position before we correct it, which causes visible fighting/flicker.
    func performDrag(with event: NSEvent) {
        guard let launcher else { return }
        cancel()
        beginTracking()
        initialMouse = launcher.convertPoint(toScreen: event.locationInWindow)
        ownsDrag = true
    }
    private func beginTracking() {
        guard !ownsDrag, trackingTimer == nil, let launcher else { return }
        initialFrame = launcher.frame
        initialMouse = NSEvent.mouseLocation
        matchX = false; matchY = false
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, let launcher = self.launcher else { return }
            if !launcher.isVisible { self.cancel(); return }
            if NSEvent.pressedMouseButtons & 1 == 0 { self.finish(); return }
            if self.dragging || launcher.frame.origin != self.initialFrame.origin ||
                (self.ownsDrag && NSEvent.mouseLocation != self.initialMouse) {
                self.moved()
            }
        }
        trackingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }
    private func moved() {
        guard !applyingSnap, let launcher, launcher.isVisible, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        if !ownsDrag && trackingTimer == nil { beginTracking() }
        dragging = true
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? launcher.screen
        guard let screen else { return }
        let destination = LauncherPositioning.target(size: launcher.frame.size, in: screen.visibleFrame)
        // Derive intent from pointer movement, not the snapped frame, so pulling away
        // can release an axis without native dragging fighting the correction.
        let mouse = NSEvent.mouseLocation
        var proposed = NSRect(origin: NSPoint(x: initialFrame.minX + mouse.x - initialMouse.x,
                                              y: initialFrame.minY + mouse.y - initialMouse.y),
                              size: launcher.frame.size)
        matchX = abs(proposed.midX - destination.midX) <= (matchX ? releaseThreshold : threshold)
        matchY = abs(proposed.maxY - destination.maxY) <= (matchY ? releaseThreshold : threshold)
        if matchX { proposed.origin.x = destination.minX }
        if matchY { proposed.origin.y = destination.maxY - proposed.height }
        if launcher.frame.origin != proposed.origin {
            applyingSnap = true
            launcher.setFrameOrigin(proposed.origin)
            applyingSnap = false
        }
        if overlay == nil {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true; panel.level = NSWindow.Level(rawValue: launcher.level.rawValue + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            overlay = panel
        }
        overlay?.setFrame(screen.frame, display: false)
        guidesView.frame = NSRect(origin: .zero, size: screen.frame.size)
        guidesView.target = destination.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        guidesView.matchX = matchX; guidesView.matchY = matchY
        if overlay?.contentView !== guidesView { overlay?.contentView = guidesView }
        guidesView.needsDisplay = true
        guidesView.displayIfNeeded()
        overlay?.orderFrontRegardless()
    }
    private func finish() {
        // Alignment has already happened during dragging; releasing only hides guides.
        cancel()
    }
    func cancel() {
        trackingTimer?.invalidate(); trackingTimer = nil
        dragging = false
        ownsDrag = false
        overlay?.orderOut(nil)
    }
    deinit {
        trackingTimer?.invalidate()
        if let willMoveObserver { NotificationCenter.default.removeObserver(willMoveObserver) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let localUp { NSEvent.removeMonitor(localUp) }
        if let globalUp { NSEvent.removeMonitor(globalUp) }
        overlay?.orderOut(nil)
    }
}
