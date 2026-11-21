import AppKit
import SwiftUI
import Vision
import ImageIO
import KeylaneCore

/// Explicit context selection. No history or permission requests run at registration time.
struct AIChatContextSheet: View {
    let source: AIContextRegistration
    let add: (AIConversationAttachment, AIResourceReader) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var rows: [AIContextCandidate] = []
    @State private var selectionTask: Task<Void, Never>?
    @StateObject private var loadState = AIContextLoadState()
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(source.title).font(.headline)
            Text("仅将你选择的内容加入草稿；发送消息时才会交给所选模型。")
                .font(.caption).foregroundStyle(.secondary)
            TextField("搜索…", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(rows) { row in
                        Button { select(row) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.title).lineLimit(2)
                                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(loadState.loading)
                    }
                    if !message.isEmpty { Text(message).foregroundStyle(.secondary).padding(20) }
                }
            }.overlay { if loadState.loading { ProgressView() } }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 500, height: 420)
            .task(id: query) {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                await load()
            }
            .onChange(of: query) { _, _ in loadState.begin(); selectionTask?.cancel(); rows = [] }
            .onDisappear { loadState.cancel(); selectionTask?.cancel() }
    }

    @MainActor private func load() async {
        let token = loadState.begin()
        do {
            guard source.available() else { throw AIActionError.unavailable }
            let values = try await source.search(query)
            try Task.checkCancellation()
            guard loadState.complete(token) else { return }
            rows = values
            message = values.isEmpty ? "当前已加载范围内没有匹配内容。" : ""
        } catch {
            guard !Task.isCancelled, loadState.complete(token) else { return }
            rows = []; message = error.localizedDescription
        }
    }

    private func select(_ row: AIContextCandidate) {
        selectionTask?.cancel()
        let token = loadState.begin()
        selectionTask = Task { @MainActor in
            do {
                guard source.available() else { throw AIActionError.unavailable }
                let reader = AIResourceReader(source: row.source, symbol: source.symbol, available: source.available)
                let attachment = try await reader.read()
                guard source.available(), !Task.isCancelled, loadState.complete(token) else { return }
                add(attachment, reader)
                dismiss()
            } catch {
                guard !Task.isCancelled, loadState.complete(token) else { return }
                message = error.localizedDescription
            }
        }
    }

}

enum AIChatImageContext {
    static func read(_ url: URL) async throws -> AIConversationAttachment {
        let work = ImageTextRecognitionWork()
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Result {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 20_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                          let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                          width.doubleValue > 0, height.doubleValue > 0,
                          width.doubleValue * height.doubleValue <= 40_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    return try ImageTextRecognition.ocr.recognize(in: VNImageRequestHandler(url: url), accurate: true, work: work)
                }
            }.value
        } onCancel: { work.cancel() }
        try Task.checkCancellation()
        let text = try result.get()
        guard !text.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return .init(title: url.lastPathComponent + "（文字）", text: text, symbol: "viewfinder")
    }
}
