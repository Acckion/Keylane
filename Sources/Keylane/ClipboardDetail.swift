import SwiftUI
import AppKit
import ImageIO
import KeylaneCore

/// Clipboard supplies content and metadata; the shared pane owns all presentation geometry.
struct ClipboardDetail: View {
    let detail: ClipDetail
    let thumbnail: NSImage?
    let status: String
    let accessMessage: String
    @State private var urls: [URL] = []
    @State private var scopes: [URL] = []
    @State private var metrics: ClipboardDetailMetrics?

    var body: some View {
        ResultDetailPane { height in
            preview(height: height)
        } information: {
            DetailInformationSection(rows: information)
            if !accessMessage.isEmpty {
                Text(accessMessage).font(.caption).foregroundStyle(.orange)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !detail.ocrText.isEmpty {
                DisclosureGroup("识别出的文字") { Text(detail.ocrText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .font(.system(size: 12))
            }
            if detail.item.kind != .text, let text = detail.snapshot?.plainText, !text.isEmpty {
                DisclosureGroup("附加文字") { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .font(.system(size: 12))
            }
        }
        .task(id: detail.item.id) {
            releaseScopes()
            urls = detail.files.map { file in
                if let bookmark = file.bookmark {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        if url.startAccessingSecurityScopedResource() { scopes.append(url) }
                        return url
                    }
                }
                return URL(fileURLWithPath: file.path)
            }
            let files = urls
            let snapshot = detail
            let result = await Task.detached(priority: .utility) { ClipboardDetailMetrics.read(snapshot, urls: files) }.value
            guard !Task.isCancelled else { return }
            metrics = result
        }
        .onDisappear { releaseScopes() }
    }

    @ViewBuilder private func preview(height: CGFloat) -> some View {
        switch detail.item.kind {
        case .text:
            Text(detail.text).font(.system(size: 13)).textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                .padding(.horizontal, 9).padding(.top, 4)
        case .image:
            if let thumbnail {
                GeometryReader { geometry in
                    let ratio = max(0.01, thumbnail.size.width / max(1, thumbnail.size.height))
                    let width = min(max(1, geometry.size.width - 18), geometry.size.height * ratio)
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                        .frame(width: width, height: width / ratio)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }.frame(height: height)
            } else { ContentUnavailableView("图片无法预览", systemImage: "photo", description: Text("历史图片可能已丢失。")) }
        case .files:
            if urls.isEmpty { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ResultFilePreview(urls: urls).frame(height: height) }
        }
    }

    private var information: [DetailInformationValue] {
        let sourceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: detail.item.sourceBundle)
        let sourceIcon = sourceURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let type = detail.item.kind == .text ? "文字" : detail.item.kind == .image ? "图片" : detail.files.count == 1 ? "文件" : "多个文件"
        var rows: [DetailInformationValue] = [
            .init(title: "来源", value: detail.item.source.isEmpty ? "未知来源" : detail.item.source, icon: sourceIcon),
            .init(title: "类型", value: type)
        ]
        switch detail.item.kind {
        case .text:
            rows.append(.init(title: "字符数", value: metrics.map { String($0.characters) } ?? "…"))
            rows.append(.init(title: "词数", value: metrics.map { String($0.words) } ?? "…"))
        case .image:
            if let dimensions = metrics?.dimensions { rows.append(.init(title: "尺寸", value: dimensions)) }
            rows.append(.init(title: "大小", value: size(metrics?.imageBytes)))
        case .files:
            if detail.files.count == 1, let file = urls.first {
                rows.append(.init(title: "路径", value: (file.path as NSString).abbreviatingWithTildeInPath))
                rows.append(.init(title: "大小", value: size(metrics?.fileBytes)))
            } else { rows.append(.init(title: "数量", value: String(detail.files.count))) }
            if let unavailable = metrics?.unavailableFiles, unavailable > 0 { rows.append(.init(title: "状态", value: "\(unavailable)个文件不可用")) }
        }
        rows.append(.init(title: "复制次数", value: String(detail.item.copyCount)))
        rows.append(.init(title: "最近复制", value: detail.item.copiedAt.formatted(date: .abbreviated, time: .standard)))
        return rows
    }
    private func size(_ bytes: Int?) -> String { bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—" }
    private func releaseScopes() { scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes = [] }
}

private struct ClipboardDetailMetrics: Sendable {
    var characters = 0
    var words = 0
    var dimensions: String?
    var imageBytes: Int?
    var fileBytes: Int?
    var unavailableFiles = 0
    static func read(_ detail: ClipDetail, urls: [URL]) -> Self {
        var result = Self()
        if detail.item.kind == .text {
            result.characters = detail.text.count
            detail.text.enumerateSubstrings(in: detail.text.startIndex..<detail.text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in result.words += 1 }
        }
        if detail.item.kind == .image {
            let data = detail.snapshot?.items.flatMap(\.representations).first { ClipboardCapture.imageFormats.map(\.0).contains($0.type) }?.data
            let source = detail.assetURL.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) } ?? data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            if let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
                result.dimensions = "\(width) × \(height)"
            }
            result.imageBytes = detail.assetURL.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? data?.count
        }
        for url in urls {
            let metadata = FilePreviewMetadata.read(url)
            if let bytes = metadata.size { result.fileBytes = (result.fileBytes ?? 0) + bytes }
            if !FileManager.default.fileExists(atPath: url.path) { result.unavailableFiles += 1 }
        }
        return result
    }
}
