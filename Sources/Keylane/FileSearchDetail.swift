import SwiftUI
import AppKit

struct FileSearchDetail: View {
    let url: URL?
    @State private var values: FilePreviewMetadata?
    var body: some View {
        Group {
            if let url {
                ResultDetailPane(scrollsPreview: false) { height in
                    ResultFilePreview(urls: [url]).frame(height: height)
                } information: {
                    DetailInformationSection(rows: information(url))
                }
            } else {
                ContentUnavailableView("选择文件以预览", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity).padding(.top, 70)
            }
        }.task(id: url) {
            values = nil
            guard let url else { return }
            let result = await Task.detached(priority: .utility) { FilePreviewMetadata.read(url) }.value
            guard !Task.isCancelled else { return }
            values = result
        }
    }
    private func information(_ url: URL) -> [DetailInformationValue] {
        var rows: [DetailInformationValue] = [
            .init(title: "名称", value: url.lastPathComponent),
            .init(title: "位置", value: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath),
            .init(title: "类型", value: values?.type ?? url.pathExtension.uppercased())
        ]
        if let size = values?.size { rows.append(.init(title: "大小", value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        if let modified = values?.modified { rows.append(.init(title: "修改时间", value: modified.formatted(date: .abbreviated, time: .shortened))) }
        return rows
    }
}
