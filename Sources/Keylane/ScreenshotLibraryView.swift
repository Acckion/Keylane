import SwiftUI
import QuickLookThumbnailing
import KeylaneCore

struct ScreenshotLibraryPage: View {
    @ObservedObject var library: ScreenshotLibrary
    let query: String
    let chooseFolders: () -> Void

    var body: some View {
        ResultGrid(sections: library.sections, selection: $library.selection, columnCount: library.columns,
                   contentInset: 0, caption: { caption($0.date) },
                   itemTitle: { $0.name }) { item in
            ScreenshotThumbnail(item: item)
        } emptyState: {
            VStack(spacing: 14) {
                if library.scanning || library.searchingText {
                    Text(library.scanning ? "正在查找截图…" : "正在识别图片文字…")
                } else if !ScreenshotQuery(query).text.isEmpty && !library.recognizesText {
                    Text("文字搜索需要启用图片文字识别")
                    Button("启用文字识别") {
                        library.recognizesText = true
                        library.search(query)
                    }.buttonStyle(ContentActionButtonStyle())
                } else {
                    Image(systemName: "viewfinder").font(.system(size: 30))
                    Text(library.inaccessibleFolders > 0 ? "部分搜索文件夹不可访问" : "没有匹配的截图或录屏")
                    Button("添加搜索文件夹…", action: chooseFolders).buttonStyle(ContentActionButtonStyle())
                }
            }.foregroundStyle(.secondary).padding(.top, 68)
        }
        .overlay(alignment: .bottomLeading) {
            if library.skippedOCR > 0 {
                Text("跳过了 \(library.skippedOCR) 张无法读取或尚未下载的图片")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 13).padding(.bottom, 48)
                    .allowsHitTesting(false)
            }
        }
    }

    private func caption(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 " + time }
        if calendar.isDateInYesterday(date) { return "昨天 " + time }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct ScreenshotThumbnail: View {
    private static let cache: NSCache<NSString, NSImage> = {
        let value = NSCache<NSString, NSImage>()
        value.countLimit = 100
        value.totalCostLimit = 48 * 1024 * 1024
        return value
    }()
    private struct Revision: Equatable {
        let item: ScreenshotMedia
        let scale: CGFloat
    }

    let item: ScreenshotMedia
    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: item.needsCloudAccess ? "icloud" : item.kind == .movie ? "film" : "photo")
                    .font(.system(size: 28)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if item.kind == .movie {
                Image(systemName: "play.fill").font(.system(size: 11, weight: .semibold))
                    .padding(7).background(.regularMaterial, in: Circle()).padding(8)
            }
        }
        .accessibilityHidden(true)
        .task(id: Revision(item: item, scale: scale)) {
            thumbnail = nil
            guard !item.needsCloudAccess else { return }
            let key = "\(item.url.absoluteString)|\(item.modified.timeIntervalSince1970)|\(item.size)|\(scale)" as NSString
            if let cached = Self.cache.object(forKey: key) { thumbnail = cached; return }
            let generator = QLThumbnailGenerator.shared
            let request = QLThumbnailGenerator.Request(fileAt: item.url, size: CGSize(width: 250, height: 250),
                                                       scale: scale, representationTypes: .thumbnail)
            let result = await withTaskCancellationHandler {
                try? await generator.generateBestRepresentation(for: request)
            } onCancel: {
                generator.cancel(request)
            }
            guard !Task.isCancelled, let result else { return }
            Self.cache.setObject(result.nsImage, forKey: key, cost: result.cgImage.bytesPerRow * result.cgImage.height)
            thumbnail = result.nsImage
        }
    }
}
