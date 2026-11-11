import AppKit
import QuickLookUI

final class FilePreview: NSObject, QLPreviewPanelDataSource {
    static let shared = FilePreview()
    private var url: URL?
    private weak var panel: QLPreviewPanel?

    func show(_ url: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.url = url
        self.panel = panel
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        url = nil
        defer { panel = nil }
        guard let panel, panel.dataSource === self else { return }
        panel.orderOut(nil)
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { url as NSURL? }
}
