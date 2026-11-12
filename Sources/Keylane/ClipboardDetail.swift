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
    @State private var fileAccess: ClipboardFiles?
    @State private var metrics: ClipboardDetailMetrics?
    @State private var linkMetadata: ClipboardLinkMetadata?
    private var urls: [URL] { fileAccess?.urls ?? [] }
    private var previewAspectRatio: CGFloat? {
        if detail.item.webURL != nil { return linkMetadata?.aspectRatio ?? 2 }
        guard let size = thumbnail?.size, size.width > 0, size.height > 0 else { return nil }
        return size.width / size.height
    }

    var body: some View {
        ResultDetailPane(scrollsPreview: detail.item.kind == .text && detail.item.color == nil && detail.item.webURL == nil,
                         previewAspectRatio: previewAspectRatio,
                         showsPreviewDivider: detail.item.webURL == nil) { height in
            preview(height: height)
        } information: {
            if let url = detail.item.webURL {
                DetailInformationRows(rows: linkInformation(url), verticalPadding: 6)
            } else {
                DetailInformationSection(rows: information)
            }
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
        .task(id: detail.item.webURL) {
            linkMetadata = nil
            guard let url = detail.item.webURL else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let metadata = await ClipboardLinkPreviews.shared.preview(for: url)
            guard !Task.isCancelled else { return }
            linkMetadata = metadata
        }
        .task(id: detail.files) {
            guard detail.item.webURL == nil else { return }
            metrics = nil
            let access = ClipboardFiles(detail.files)
            fileAccess = access
            let snapshot = detail
            let result = await Task.detached(priority: .utility) {
                withExtendedLifetime(access) { ClipboardDetailMetrics.read(snapshot, urls: access.urls) }
            }.value
            guard !Task.isCancelled else { return }
            metrics = result
        }
        .onDisappear { fileAccess = nil }
    }

    @ViewBuilder private func preview(height: CGFloat) -> some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: .infinity)
                .frame(height: height)
        } else if detail.item.kind == .text {
            if let color = detail.item.color {
                ClipboardColorPreview(color: color)
            } else if let url = detail.item.webURL {
                ClipboardLinkPreview(url: url, metadata: linkMetadata).frame(height: height)
            } else {
                Text(detail.text).font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                    .padding(.horizontal, 9).padding(.top, 4)
            }
        } else if detail.item.kind == .image {
            ContentUnavailableView("图片无法预览", systemImage: "photo", description: Text("历史图片可能已丢失。"))
        } else if urls.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ResultFilePreview(urls: urls).frame(height: height)
        }
    }

    private func linkInformation(_ url: URL) -> [DetailInformationValue] {
        var rows: [DetailInformationValue] = [.init(title: "网址", value: url.absoluteString)]
        if let title = linkMetadata?.title, !title.isEmpty {
            rows.append(.init(title: "标题", value: title))
        }
        return rows + [
            .init(title: "复制次数", value: String(detail.item.copyCount)),
            .init(title: "最近复制", value: detail.item.copiedAt.formatted(date: .abbreviated, time: .standard)),
            .init(title: "首次复制", value: detail.item.firstCopiedAt.formatted(date: .abbreviated, time: .standard))
        ]
    }

    private var information: [DetailInformationValue] {
        let sourceURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: detail.item.sourceBundle)
        let sourceIcon = sourceURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let type: String
        switch detail.item.category {
        case .text: type = "文字"
        case .image: type = "图片"
        case .files: type = detail.files.count == 1 ? "文件" : "多个文件"
        case .link: type = "链接"
        case .email: type = "邮箱"
        case .color: type = "颜色"
        }
        var rows: [DetailInformationValue] = [
            .init(title: "来源", value: detail.item.source.isEmpty ? "未知来源" : detail.item.source, icon: sourceIcon),
            .init(title: "类型", value: type)
        ]
        switch detail.item.kind {
        case .text where detail.item.color == nil:
            rows.append(.init(title: "字符数", value: metrics.map { String($0.characters) } ?? "…"))
            rows.append(.init(title: "词数", value: metrics.map { String($0.words) } ?? "…"))
        case .text: break
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
}

struct ClipboardColorPreview: View {
    let color: ClipboardColor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClipboardColorSwatch(color: color, cornerRadius: 8)
                .frame(maxHeight: .infinity)
            Text(color.hexLabel)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.black)
                .textSelection(.enabled)
                .padding(.horizontal, 5)
                .padding(.vertical, 8)
        }
        .padding(4)
        .frame(maxWidth: 210, maxHeight: 186)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ClipboardColorSwatch: View {
    let color: ClipboardColor
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            if color.alpha < 1 {
                Canvas { context, size in
                    let side = cornerRadius
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                    for row in 0..<Int(ceil(size.height / side)) {
                        for column in stride(from: row % 2, to: Int(ceil(size.width / side)), by: 2) {
                            let square = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side,
                                                width: side, height: side)
                            context.fill(Path(square), with: .color(Color(white: 0.75)))
                        }
                    }
                }
            }
            Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.20), lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
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
