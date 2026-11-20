import AppKit
import SwiftUI
import Combine
import KeylaneCore

enum AIActionLauncher {
    static let pageID = PageID(rawValue: "module-ai-action")
    static func page(model: Model) -> LauncherPage {
        let session = model.moduleAIAction
        let updates = Publishers.MergeMany([
            session.$invocationID.map { _ in () }.eraseToAnyPublisher(),
            session.$running.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.$preparing.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.$answer.map { $0.isEmpty }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.$question.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 8_000 }.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            session.$title.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
        return LauncherPage(id: pageID, placeholder: "", badge: ("AI", "sparkles"), contentPlacement: .form,
            content: { [weak model] in
                AnyView(LauncherCreationForm(back: { model?.goBackInLauncher() }, spacing: 16) {
                    Text(session.title).font(.headline)
                } fields: {
                    AIActionForm(session: session).padding(.horizontal, 26)
                })
            }, leave: session.clear, submit: { if !SearchField.isComposing { session.send() } },
            returnBindings: .init(primary: .command), actionSelectionID: { session.invocationID.uuidString }, primaryTitle: { "发送给模型" }, primaryEnabled: { session.canSend },
            actions: {
                var result = [LauncherAction(id: "copy-ai-action", title: "复制结果", icon: "doc.on.doc", enabled: !session.answer.isEmpty) {
                    AIConversationHostActions.copyText(session.answer)
                }]
                result.append(.init(id: "continue-ai-action", title: "继续到 Quick AI", icon: "bubble.left.and.bubble.right",
                                    enabled: !session.answer.isEmpty && !session.running && !session.preparing) { [weak model] in
                    guard let context = session.context else { return }
                    if model?.continueModuleAIAction?(context, session.answer) != true {
                        (NSApp.delegate as? Delegate)?.showLauncherFeedback("无法加入草稿：请等待附件处理完成，或缩小内容范围。", style: .failure)
                    }
                })
                if session.running || session.preparing { result.append(.init(id: "stop-ai-action", title: "停止", icon: "stop.fill", perform: session.cancel)) }
                return result
            }, updates: updates, badgeTitle: { session.title })
    }
}

struct AIActionForm: View {
    @ObservedObject var session: AIActionSession
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let context = session.context {
                Text(context.title).font(.headline)
                ScrollView { Text(context.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 140)
            }
            if session.acceptsQuestion {
                TextField("输入关于这条记录的问题…", text: $session.question, axis: .vertical)
                    .lineLimit(2...5).disabled(session.running || session.preparing)
                Text("问题最多 8,000 UTF-8 字节。此前的内容仅在发送后交给模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("发送至 \(session.destination)").font(.caption).foregroundStyle(.secondary)
            Text("仅在发送后处理以上所选内容，结果不会自动修改原记录。").font(.caption).foregroundStyle(.secondary)
            AIActionResultView(session: session)
        }
    }
}
