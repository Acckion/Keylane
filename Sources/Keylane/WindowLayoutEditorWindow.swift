import AppKit
import SwiftUI

final class WindowLayoutEditorWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var openPanel: NSOpenPanel?
    private var onClose: (() -> Void)?

    func show(_ content: WindowLayoutEditor, parent: NSWindow?, onClose: @escaping () -> Void) {
        let available = parent?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let width = min(900, max(640, available.width - 60))
        let height = min(710, max(460, available.height - 80))
        // Keep the editor on the current screen even when the launcher is near an edge.
        let sheetParent = parent.flatMap { window -> NSWindow? in
            guard window.isVisible, window.attachedSheet == nil,
                  window.frame.midX - width / 2 >= available.minX,
                  window.frame.midX + width / 2 <= available.maxX else { return nil }
            return window
        }
        let editor = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        editor.contentMinSize = CGSize(width: 620, height: 440)
        editor.title = content.windowTitle
        editor.titleVisibility = .hidden
        editor.titlebarAppearsTransparent = true
        editor.isMovableByWindowBackground = true
        editor.isReleasedWhenClosed = false
        editor.appearance = parent?.appearance
        editor.delegate = self
        editor.contentView = NSHostingView(rootView: content)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            editor.standardWindowButton(button)?.isHidden = true
        }
        window = editor
        self.onClose = onClose
        if let sheetParent {
            sheetParent.beginSheet(editor) { [weak self] _ in self?.finish() }
        } else {
            editor.setFrameOrigin(NSPoint(x: available.midX - width / 2, y: available.midY - height / 2))
            editor.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func choosePath(folder: Bool, completion: @escaping (String) -> Void) {
        guard let window, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        openPanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.openPanel = nil
            if response == .OK, let url = panel.url { completion(url.path) }
        }
    }

    func dismiss() {
        guard let window else { return }
        openPanel?.cancel(nil)
        if let parent = window.sheetParent {
            parent.endSheet(window)
            window.orderOut(nil)
            finish()
        } else {
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) { finish() }

    private func finish() {
        window?.delegate = nil
        window = nil
        openPanel = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
