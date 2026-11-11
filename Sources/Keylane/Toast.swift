import AppKit
import SwiftUI

/// A short feedback message in a floating capsule.
struct ToastBubble: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.10), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 9)
        .padding(.trailing, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: Capsule())
    }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Presents feedback independently of launcher visibility.
final class ToastPresenter {
    private var panel: ToastPanel?
    private var dismissal: DispatchWorkItem?

    func owns(_ window: NSWindow?) -> Bool {
        guard let panel else { return false }
        return window === panel
    }

    func show(_ message: String, duration: TimeInterval = 3) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        dismissal?.cancel()

        let panel = self.panel ?? ToastPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]

        let host = NSHostingView(rootView: ToastBubble(message: message, dismiss: { [weak self] in self?.hide() }))
        panel.contentView = host
        let size = host.fittingSize
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 28,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: host, notification: .announcementRequested,
                             userInfo: [.announcement: message])

        let dismissal = DispatchWorkItem { [weak self] in self?.hide() }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
    }
}
