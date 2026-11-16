import AppKit
import QuickLookUI

final class FilePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = FilePreview()
    private var urls: [URL] = []
    private var fileAccess: AnyObject?
    private weak var panel: QLPreviewPanel?
    private var presenting = false
    private var owner: FilePresentationOwner?

    var takesLauncherFocus: Bool { presenting || (owns(panel) && panel?.isKeyWindow == true) }

    func owns(_ window: NSWindow?) -> Bool {
        guard let panel, panel.dataSource === self else { return false }
        return window === panel
    }

    func show(_ url: URL, owner: FilePresentationOwner? = nil) { show([url], owner: owner) }

    func show(_ urls: [URL], retaining access: AnyObject? = nil, owner: FilePresentationOwner? = nil) {
        guard !urls.isEmpty else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        fileAccess = access
        self.owner = owner
        self.panel = panel
        panel.dataSource = self
        panel.reloadData()
        presenting = true
        defer { presenting = false }
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss(owner: FilePresentationOwner) {
        if self.owner == owner { dismiss() }
    }

    func dismiss() {
        defer {
            urls = []
            fileAccess = nil
            panel = nil
            owner = nil
        }
        guard let panel, panel.dataSource === self else { return }
        panel.orderOut(nil)
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }
}
