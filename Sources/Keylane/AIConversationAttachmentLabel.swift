import AppKit
import ImageIO
import SwiftUI

/// One preview for draft and restored history; the encoded raster is decoded once per attachment visit.
struct AIConversationAttachmentLabel: View {
    let attachment: AIConversationAttachment
    @State private var preview: NSImage?
    @State private var presented = false
    @State private var fullPreview: NSImage?
    var body: some View {
        Button { presented = true } label: {
            HStack(spacing: 5) {
                if let preview { Image(nsImage: preview).resizable().scaledToFit().frame(width: 32, height: 24).clipShape(RoundedRectangle(cornerRadius: 3)) }
                else { Image(systemName: attachment.symbol) }
                Text(attachment.title).lineLimit(1)
            }
        }.buttonStyle(.plain).help("预览上下文")
             .task(id: attachment.id) {
                guard let payload = attachment.image, let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96] as CFDictionary) else { return }
                preview = NSImage(cgImage: image, size: .zero)
            }
            .onChange(of: presented) { _, visible in fullPreview = visible ? attachment.image.flatMap { NSImage(data: $0.data) } : nil }
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(attachment.title).font(.headline)
                    if let image = fullPreview ?? preview { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260) }
                    if let source = attachment.visualSource {
                        Text("\(source.application) · \(source.windowTitle)\n\(source.capturedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView { Text(attachment.text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                    if attachment.image != nil { Text("发送时会包含图像；OCR 与辅助功能文字仅作补充。").font(.caption).foregroundStyle(.secondary) }
                }.padding(18).frame(width: 420)
            }
    }
}
