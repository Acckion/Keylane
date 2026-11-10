import SwiftUI
import AppKit
import QuickLookUI

/// Native embedded Quick Look handles supported files without loading full images into SwiftUI.
private struct EmbeddedFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

private struct FileMetadata: Sendable {
    let localizedTypeDescription: String?
    let fileSize: Int?
    let contentModificationDate: Date?
}

struct FileSearchDetail: View {
    let url: URL?
    @State private var values: FileMetadata?
    var body: some View {
        ScrollView {
            if let url {
                VStack(alignment: .leading, spacing: 16) {
                    EmbeddedFilePreview(url: url).frame(height: 220).id(url)
                    Text("元数据").font(VisualStyle.sectionText).foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        metadata("名称", url.lastPathComponent)
                        metadata("位置", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        metadata("类型", values?.localizedTypeDescription ?? url.pathExtension.uppercased())
                        if let size = values?.fileSize { metadata("大小", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) }
                        if let date = values?.contentModificationDate { metadata("修改时间", date.formatted(date: .abbreviated, time: .shortened)) }
                    }
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }.padding(18)
            } else {
                ContentUnavailableView("选择文件以预览", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity).padding(.top, 70)
            }
        }
        .scrollIndicators(.visible, axes: .vertical)
        .task(id: url) {
            values = nil
            guard let url else { return }
            let result = await Task.detached(priority: .utility) {
                let value = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey])
                return FileMetadata(localizedTypeDescription: value?.localizedTypeDescription,
                                    fileSize: value?.fileSize, contentModificationDate: value?.contentModificationDate)
            }.value
            guard !Task.isCancelled else { return }
            values = result
        }
    }
    private func metadata(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 12)).padding(9)
    }
}
