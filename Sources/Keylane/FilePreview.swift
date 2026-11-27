import AppKit
import QuickLookUI

final class FilePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = FilePreview()
    private var urls: [URL] = []
    private var fileAccess: AnyObject?
    private weak var panel: QLPreviewPanel?
    private var presenting = false
    private var owner: FilePresentationOwner?
    private var levelOverride: LevelOverride?

    struct LevelOverride {
        let original: NSWindow.Level
        let raised: NSWindow.Level

        init(original: NSWindow.Level, above other: NSWindow.Level) {
            self.original = original
            raised = NSWindow.Level(rawValue: max(original.rawValue, other.rawValue + 1))
        }

        func restore(from current: NSWindow.Level) -> NSWindow.Level? {
            guard current == raised, raised != original else { return nil }
            return original
        }
    }

    var takesLauncherFocus: Bool { presenting || (owns(panel) && panel?.isKeyWindow == true) }

    func owns(_ window: NSWindow?) -> Bool {
        guard let panel, panel.dataSource === self else { return false }
        return window === panel
    }

    func show(_ url: URL, owner: FilePresentationOwner? = nil) { show([url], owner: owner) }

    func show(_ urls: [URL], retaining access: AnyObject? = nil, owner: FilePresentationOwner? = nil) {
        guard !urls.isEmpty else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        if self.panel !== panel || !owns(panel) { dismiss() }
        presenting = true
        defer { presenting = false }
        self.urls = urls
        fileAccess = access
        self.owner = owner
        if self.panel == nil {
            self.panel = panel
            let notifications = NotificationCenter.default
            notifications.addObserver(self, selector: #selector(previewWillClose(_:)), name: NSWindow.willCloseNotification, object: panel)
            for name in [NSWindow.didResignKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
                notifications.addObserver(self, selector: #selector(previewVisibilityChanged(_:)), name: name, object: panel)
            }
        }
        panel.dataSource = self
        panel.reloadData()
        guard panel === self.panel, owns(panel) else { finishPresentation(); return }
        if levelOverride == nil {
            levelOverride = LevelOverride(original: panel.level, above: FloatingWindowVisibility.panelLevel)
        }
        if let levelOverride, panel.level.rawValue < levelOverride.raised.rawValue { panel.level = levelOverride.raised }
        panel.makeKeyAndOrderFront(nil)
        // Also handle unsuccessful ordering, which need not produce a window notification.
        checkVisibility(of: panel)
    }

    func dismiss(owner: FilePresentationOwner) {
        if self.owner == owner { dismiss() }
    }

    func dismiss() {
        if let panel, owns(panel) { panel.orderOut(nil) }
        finishPresentation()
    }

    @objc private func previewWillClose(_ notification: Notification) {
        guard let closing = notification.object as? QLPreviewPanel, closing === panel else { return }
        finishPresentation()
    }

    @objc private func previewVisibilityChanged(_ notification: Notification) {
        guard let changed = notification.object as? QLPreviewPanel, changed === panel else { return }
        checkVisibility(of: changed)
    }

    private func checkVisibility(of observed: QLPreviewPanel) {
        // Visibility may not have settled while AppKit is sending ordering notifications.
        DispatchQueue.main.async { [weak self, weak observed] in
            guard let self, let observed, observed === self.panel, !self.presenting else { return }
            if !observed.isVisible || !self.owns(observed) { self.finishPresentation() }
        }
    }

    private func finishPresentation() {
        let previousPanel = panel
        let previousLevel = levelOverride
        panel = nil
        levelOverride = nil
        owner = nil
        defer { urls = []; fileAccess = nil }
        guard let previousPanel else { return }
        NotificationCenter.default.removeObserver(self, name: nil, object: previousPanel)
        if let restored = previousLevel?.restore(from: previousPanel.level) { previousPanel.level = restored }
        if previousPanel.dataSource === self { previousPanel.dataSource = nil }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
