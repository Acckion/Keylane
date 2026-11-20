import AppKit
import SwiftUI
import Vision
import ImageIO

/// Explicit context selection. No history or permission requests run at registration time.
struct AIChatContextSheet: View {
    enum Source: String, Identifiable {
        case clipboard, calendar
        var id: Self { self }
        var title: String { self == .clipboard ? "剪贴板历史" : "日历日程" }
    }
    struct Candidate: Identifiable {
        let id: String
        let title: String
        let detail: String
        let load: (@escaping (String?) -> Void) -> Void
    }
    let source: Source
    let add: (AIConversationAttachment) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var rows: [Candidate] = []
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
                load()
            }
            .onChange(of: query) { _, _ in loadState.begin() }
            .onDisappear { loadState.cancel() }
    }

    private func load() {
        guard let model = (NSApp.delegate as? Delegate)?.model else {
            loadState.cancel()
            rows = []
            message = "上下文服务不可用。"
            return
        }
        message = ""
        switch source {
        case .clipboard:
            let current = loadState.begin()
            model.clipboard.aiTextContexts(query: query) { items in
                guard loadState.complete(current) else { return }
                rows = items.map { item in
                    Candidate(id: item.id, title: item.preview, detail: item.source) { done in
                        model.clipboard.aiTextContext(id: item.id, completion: done)
                    }
                }
                if rows.isEmpty { message = "没有可用的文本记录。可在剪贴板设置中确认历史功能是否启用。" }
            }
        case .calendar:
            loadState.performSynchronously {
                guard model.calendar.enabled, model.calendar.access == .allowed else {
                    rows = []; message = "请先在日历设置中启用功能并允许读取日历。"; return
                }
                var seen = Set<String>()
                rows = (model.calendar.events + model.calendar.upcoming).filter {
                    seen.insert($0.id).inserted && (query.isEmpty || ($0.title + " " + $0.notes).localizedCaseInsensitiveContains(query))
                }.prefix(100).map { event in
                    let body = "标题：\(event.title)\n开始：\(event.start.formatted())\n结束：\(event.end.formatted())\n地点：\(event.location)\n备注：\(event.notes)"
                    return Candidate(id: event.id, title: event.title, detail: event.start.formatted()) { $0(body) }
                }
                if rows.isEmpty { message = "当前已加载的日期范围内没有匹配的日程。" }
            }
        }
    }

    private func select(_ row: Candidate) {
        let current = loadState.begin()
        row.load { text in
            guard loadState.complete(current) else { return }
            guard let text, !text.isEmpty else { message = "无法读取这项内容，请刷新后重试。"; return }
            add(.init(title: String(row.title.prefix(60)), text: text,
                      symbol: source == .clipboard ? "clipboard" : "calendar"))
            dismiss()
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
