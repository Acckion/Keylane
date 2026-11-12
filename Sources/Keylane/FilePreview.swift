import AppKit
import QuickLookUI

final class FilePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = FilePreview()
    private var urls: [URL] = []
    private var fileAccess: AnyObject?
    private weak var panel: QLPreviewPanel?
    private var presenting = false

    var takesLauncherFocus: Bool { presenting || (owns(panel) && panel?.isKeyWindow == true) }

    func owns(_ window: NSWindow?) -> Bool {
        guard let panel, panel.dataSource === self else { return false }
        return window === panel
    }

    func show(_ url: URL) { show([url]) }

    func show(_ urls: [URL], retaining access: AnyObject? = nil) {
        guard !urls.isEmpty else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        fileAccess = access
        self.panel = panel
        panel.dataSource = self
        panel.reloadData()
        presenting = true
        defer { presenting = false }
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        defer {
            urls = []
            fileAccess = nil
            panel = nil
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
