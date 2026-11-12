import SwiftUI
import AppKit
import QuickLookUI

/// Results stay on the left; the preview and information on the right scroll independently.
struct ResultDetailPane<Preview: View, Information: View>: View {
    var scrollsPreview = true
    var previewAspectRatio: CGFloat? = nil
    @ViewBuilder let preview: (CGFloat) -> Preview
    @ViewBuilder let information: () -> Information

    var body: some View {
        GeometryReader { geometry in
            let previewHeight = max(0, (geometry.size.height - VisualStyle.launcherTopInset - VisualStyle.launcherBottomInset - 1) / 2)
            VStack(spacing: 0) {
                if let aspectRatio = previewAspectRatio {
                    let width = max(0, geometry.size.width - 2 * VisualStyle.launcherEdgeInset)
                    let height = min(width / aspectRatio, previewHeight * 1.34)
                    preview(height)
                        .frame(width: width, height: height)
                        .padding(.top, VisualStyle.launcherTopInset + 5)
                        .padding(.bottom, 8)
                } else {
                    previewRegion(height: previewHeight)
                        .frame(height: previewHeight + VisualStyle.launcherTopInset)
                    Divider()
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 18, content: information)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, previewAspectRatio == nil ? 18 : VisualStyle.launcherEdgeInset)
                        .padding(.vertical, previewAspectRatio == nil ? 18 : 0)
                }
                .launcherScrollInsets(top: false)
            }
        }
    }

    @ViewBuilder private func previewRegion(height: CGFloat) -> some View {
        let contentHeight = max(0, height - 36)
        if scrollsPreview {
            ScrollView {
                preview(contentHeight)
                    .frame(maxWidth: .infinity, minHeight: contentHeight)
                    .padding(18)
            }
            .launcherScrollInsets(bottom: false)
        } else {
            // Quick Look handles its own scrolling. Images fit the same viewport.
            preview(contentHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)
                .padding(.top, VisualStyle.launcherTopInset)
                .clipped()
        }
    }
}

struct DetailInformationValue: Identifiable {
    let title: String
    let value: String
    var icon: NSImage? = nil
    var id: String { title }
}

struct DetailInformationSection: View {
    let rows: [DetailInformationValue]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("信息").font(VisualStyle.sectionText).foregroundStyle(.secondary).padding(.horizontal, 9)
            DetailInformationRows(rows: rows)
        }
    }
}

struct DetailInformationRows: View {
    let rows: [DetailInformationValue]
    var verticalPadding: CGFloat = 9

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.title).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if let icon = row.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 15, height: 15) }
                    Text(row.value).multilineTextAlignment(.trailing).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(row.value)
                }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, verticalPadding).frame(maxWidth: .infinity, alignment: .leading)
                    .background(index.isMultiple(of: 2) ? Color.primary.opacity(0.035) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// Both modules use the same embedded system preview and fallback.
struct ResultFilePreview: View {
    let urls: [URL]
    var body: some View {
        if urls.count == 1, let url = urls.first {
            if FileManager.default.fileExists(atPath: url.path) { EmbeddedFilePreview(url: url) }
            else { ContentUnavailableView("原文件不可用", systemImage: "doc.badge.ellipsis", description: Text("文件可能已移动、删除，或需要重新授权。")) }
        } else if urls.count > 1 {
            ZStack {
                ForEach((0..<min(urls.count, 3)).reversed(), id: \.self) { index in
                    Image(nsImage: NSWorkspace.shared.icon(forFile: urls[index].path))
                        .resizable().scaledToFit().frame(width: 156, height: 180)
                        .rotationEffect(.degrees(Double(index) * 4))
                        .offset(x: CGFloat(index) * 5, y: -CGFloat(index) * 4)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("\(urls.count)个文件")
        }
    }
}

private struct EmbeddedFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // The launcher panel is reused and can be hidden without closing.
        view.previewItem = nil
        view.close()
    }
}

struct FilePreviewMetadata: Sendable {
    let type: String?
    let size: Int?
    let modified: Date?
    static func read(_ url: URL) -> Self {
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .contentModificationDateKey])
        return Self(type: values?.localizedTypeDescription, size: values?.fileSize, modified: values?.contentModificationDate)
    }
}
