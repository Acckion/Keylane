import AppKit
import SwiftUI

/// Observe clicks without placing a hit-testing layer above the window's controls.
struct MenuOutsideClickDismissal: NSViewRepresentable {
    let presented: Bool
    let dismiss: () -> Void

    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }
    func updateNSView(_ view: BoundaryView, context: Context) {
        view.configure(presented: presented, dismiss: dismiss)
    }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.invalidate() }

    final class BoundaryView: NSView {
        private var presented = false
        private var dismiss: (() -> Void)?
        private var mouseMonitor: Any?
        private var resignObserver: NSObjectProtocol?
        private weak var observedWindow: NSWindow?
        var monitoring: Bool { mouseMonitor != nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }

        func configure(presented: Bool, dismiss: @escaping () -> Void) {
            self.presented = presented
            self.dismiss = dismiss
            refresh()
        }

        private func refresh() {
            guard presented, let window else { stop(); return }
            guard observedWindow !== window || mouseMonitor == nil else { return }
            stop()
            observedWindow = window
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, self.presented, event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { self.close() }
                return event
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in self?.close() }
        }

        private func close() {
            guard presented else { return }
            presented = false
            stop()
            dismiss?()
        }

        func invalidate() {
            presented = false
            dismiss = nil
            stop()
        }

        func stop() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            mouseMonitor = nil
            resignObserver = nil
            observedWindow = nil
        }
    }
}
