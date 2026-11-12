import SwiftUI
import AppKit
import KeylaneCore

struct ClipboardListIcon: View {
    let item: ClipItem
    let controller: ClipboardController
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let color = item.color {
                ClipboardColorSwatch(color: color, cornerRadius: 5)
            } else if let thumbnail {
                Image(nsImage: thumbnail).renderingMode(thumbnail.isTemplate ? .template : .original)
                    .resizable().aspectRatio(contentMode: item.webURL == nil ? .fill : .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.15))
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .regular)).foregroundStyle(.primary.opacity(0.85))
                }
            }
        }.frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .bottomTrailing) {
                if item.fileCount > 1 {
                    Text(item.fileCount, format: .number)
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Color(white: 0.13), in: Capsule())
                        .overlay { Capsule().strokeBorder(.white.opacity(0.75), lineWidth: 1) }
                }
            }
            .accessibilityHidden(true)
            .task(id: item.id + (item.kind == .files ? String(item.copiedAt.timeIntervalSince1970) : "")) {
                thumbnail = nil
                guard item.fileCount <= 1 else { return }
                let image: NSImage?
                if let url = item.webURL {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                    image = await ClipboardLinkPreviews.shared.icon(for: url)
                } else {
                    image = await controller.listThumbnail(for: item)
                }
                guard !Task.isCancelled else { return }
                if image != nil || item.webURL == nil { thumbnail = image }
            }
            .onReceive(ClipboardLinkPreviews.shared.iconUpdates) { origin, icon in
                if let url = item.webURL, ClipboardLinkPreviews.origin(for: url) == origin { thumbnail = icon }
            }
    }

    private var symbol: String {
        switch item.category {
        case .link: return "link"
        case .email: return "at"
        case .image: return "photo.fill"
        case .files: return "doc.on.doc.fill"
        case .text, .color: return "doc.text.fill"
        }
    }
}
