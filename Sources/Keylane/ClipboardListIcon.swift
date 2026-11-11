import SwiftUI
import AppKit
import KeylaneCore

struct ClipboardListIcon: View {
    let item: ClipItem
    let controller: ClipboardController
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.15))
                    Image(systemName: item.kind == .text ? "doc.text.fill" : item.kind == .image ? "photo.fill" : "doc.on.doc.fill")
                        .font(.system(size: 17, weight: .regular)).foregroundStyle(.primary.opacity(0.85))
                }
            }
        }.frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            .task(id: item.id + (item.kind == .files ? String(item.copiedAt.timeIntervalSince1970) : "")) {
                thumbnail = nil
                let image = await controller.listThumbnail(for: item)
                guard !Task.isCancelled else { return }
                thumbnail = image
            }
    }
}
