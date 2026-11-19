import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum QuickAILauncher {
    static let pageID = PageID(rawValue: "quick-ai")
    static let commandID = CommandID(rawValue: "quick-ai")

    static func page(model: Model, controller: QuickAIController, openChat: @escaping () -> Void) -> LauncherPage {
        var page = LauncherPage(id: pageID, placeholder: "向 AI 提问…", badge: ("Quick AI", "sparkles"),
                     contentPlacement: .conversation, content: {
                         AnyView(QuickAIConversationPage(model: model, controller: controller, openChat: openChat))
                     },
                     leave: controller.leaveLauncher, submit: { [weak model] in
                         guard let model, !SearchField.isComposing else { return }
                         if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && controller.pendingFiles.isEmpty {
                             useResponse(controller, copyOnly: model.aiInteraction.primaryAction == .copy)
                         } else if controller.submit(model.query) { model.query = "" }
                     }, primaryTitle: { "发送" }, primaryEnabled: { [weak model] in
                         guard let model else { return false }
                         return controller.currentConnection != nil && !controller.running && !controller.loadingChat && !controller.loadingFiles
                             && (!model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.lastAnswer != nil || !controller.pendingFiles.isEmpty)
                     }, actions: { [weak model] in
                         guard let model else { return [] }
                         return QuickAIActions.items(model: model, controller: controller, openChat: openChat)
                     }, updates: Publishers.MergeMany([
                         controller.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                         model.aiInteraction.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                         model.aiSettings.objectWillChange.map { _ in () }.eraseToAnyPublisher()
                     ]).eraseToAnyPublisher(), actionShortcutsEnabled: true)
        page.badgeActions = {
            [.init(id: "quick-ai-file", title: "附加文件…", icon: "doc.badge.plus", enabled: !controller.loadingFiles && !controller.loadingChat, perform: controller.chooseFiles)]
        }
        page.returnBindings = .init(primary: .plain, alternates: [
            .command: .init(perform: { useResponse(controller, copyOnly: model.aiInteraction.primaryAction == .paste) }),
            .option: .init(perform: { useResponse(controller, formatted: true) })
        ])
        page.actionContextTitle = { controller.conversationTitle }
        page.enter = controller.consumeEntry
        page.fullBleed = true
        return page
    }
    static func useResponse(_ controller: QuickAIController, formatted: Bool = false, copyOnly: Bool = false) {
        guard !controller.running, let answer = controller.lastAnswer else { return }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(answer, forType: .string) else { return }
        if formatted, let data = AIResponseFormatting.rtf(answer) { board.setData(data, forType: .rtf) }
        if !copyOnly, let delegate = NSApp.delegate as? Delegate, delegate.pasteTargetName != nil {
            delegate.pasteIntoPreviousApplication(clipboardGeneration: board.changeCount)
        }
    }

}

struct AIConversationTranscript: View {
    @ObservedObject var controller: QuickAIController
    var inLauncher = false
    var showsEmptyHint = true
    @State private var followsBottom = true
    private let bottomID = "quick-ai-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            styledScrollView
            .onScrollPhaseChange { _, phase, context in
                if phase == .idle {
                    followsBottom = context.geometry.contentSize.height + context.geometry.contentInsets.bottom
                        - context.geometry.visibleRect.maxY < 48
                }
            }
            .onReceive(controller.revealMessage) { id in
                followsBottom = false
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
            }
            .onChange(of: controller.chatID) { _, _ in followsBottom = true }
            .onChange(of: controller.turns.last?.id) { _, id in
                guard let id else { return }
                followsBottom = true
                Task { @MainActor in proxy.scrollTo(id, anchor: .top) }
            }
            .onReceive(controller.$turns) { _ in
                guard followsBottom else { return }
                Task { @MainActor in proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var styledScrollView: some View {
        if inLauncher {
            let extra: CGFloat = controller.pendingFiles.isEmpty ? 0 : 26
            transcript.launcherScrollInsets()
                .contentMargins(.bottom, VisualStyle.launcherBottomInset + extra, for: .scrollContent)
                .contentMargins(.bottom, VisualStyle.launcherBottomInset + extra, for: .scrollIndicators)
                .launcherScrollEdgeFade(bottom: VisualStyle.launcherBottomInset + 22 + extra)
        }
        else { transcript }
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if controller.turns.isEmpty && showsEmptyHint {
                    Text(inLauncher ? "输入问题，按回车发送。" : "输入问题开始对话。").foregroundStyle(.secondary)
                }
                ForEach(controller.turns) { turn in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Spacer(minLength: 50)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(turn.question).textSelection(.enabled).font(.system(size: 14 * controller.textScale))
                                ForEach(turn.files ?? []) { file in Label(file.name, systemImage: "doc").font(.caption).foregroundStyle(.secondary) }
                            }
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if let progress = turn.progress,
                           progress.active || !progress.activities.isEmpty || progress.phase == .failed || progress.phase == .cancelled {
                            AIResponseProgressView(progress: progress).padding(.top, 8)
                        }
                        if !turn.answer.isEmpty {
                            ReleaseNotesBody(notes: turn.answer, textScale: controller.textScale).font(.system(size: 14 * controller.textScale))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        if turn.progress == nil && !turn.complete && (!controller.running || turn.id != controller.turns.last?.id) {
                            Text("回复未完成").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(turn.id)
                }
                if controller.running && controller.turns.last?.progress == nil {
                    HStack {
                        ProgressView().controlSize(.small).accessibilityLabel("正在生成")
                        Text("正在生成回复…").foregroundStyle(.secondary)
                        if !inLauncher {
                            Button("停止生成", action: controller.stop).buttonStyle(ContentActionButtonStyle())
                        }
                    }
                }
                if !controller.status.isEmpty && (controller.status != "已停止。" || controller.turns.last?.progress == nil) {
                    Text(controller.status).foregroundStyle(.secondary)
                }
                if !controller.historyError.isEmpty { Text(controller.historyError).foregroundStyle(.secondary) }
                Color.clear.frame(height: 1).id(bottomID).accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, VisualStyle.launcherEdgeInset)
        }
    }

    static func copy(_ text: String?) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct QuickAIConversationPage: View {
    let model: Model
    @ObservedObject var controller: QuickAIController
    let openChat: () -> Void
    @State private var input = ""
    @Environment(\.conversationInputEnabled) private var inputEnabled
    @Environment(\.conversationInputFocusToken) private var inputFocusToken

    var body: some View {
        ConversationLayout(title: controller.conversationTitle,
                           subtitle: controller.quickModelIsAutomatic
                               ? "自动 · " + model.aiInteraction.modelPreference.title + " · " + (controller.currentConnection?.displayName ?? "请选择模型")
                               : controller.currentConnection?.displayName ?? "请选择模型",
                           isEmpty: controller.turns.isEmpty && controller.status.isEmpty,
                           contextPreview: controller.turns.count > 1 ? controller.turns.dropLast().last?.answer.components(separatedBy: .newlines).first : nil,
                           back: { model.goBackInLauncher() }) {
            AIConversationTranscript(controller: controller, inLauncher: true)
        } composer: {
            ConversationComposer(inputHeight: controller.pendingFiles.isEmpty ? VisualStyle.launcherControlDiameter : 62) {
                Color.clear.allowsHitTesting(false)
            } input: {
                VStack(alignment: .leading, spacing: 4) {
                    if !controller.pendingFiles.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(controller.pendingFiles) { file in
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc")
                                        Text(file.name).lineLimit(1)
                                        Button { controller.pendingFiles.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle.fill") }
                                            .buttonStyle(.plain).accessibilityLabel("移除 " + file.name)
                                    }.font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.primary.opacity(0.06), in: Capsule())
                                }
                            }
                        }.scrollIndicators(.hidden).frame(height: 18)
                    }
                    HStack(spacing: 8) {
                    SearchField(text: $input, placeholder: "提问，或附加文件…", focusToken: inputFocusToken, wantsFocus: inputEnabled, compact: true,
                                submit: submit, move: { _ in },
                                escape: {
                                    if controller.running { controller.stop() }
                                    else { model.cancelLauncherPage() }
                                })
                    if controller.loadingFiles {
                        ProgressView().controlSize(.small).accessibilityLabel("正在读取附件")
                    } else if controller.running {
                        NativeHoverButton(title: "停止生成", action: controller.stop) {
                            Image(systemName: "stop.fill")
                        }.frame(width: 28, height: 28)
                    } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !controller.pendingFiles.isEmpty {
                        NativeHoverButton(title: "发送", action: submit) {
                            Image(systemName: "arrow.up")
                        }.frame(width: 28, height: 28)
                            .disabled(controller.currentConnection == nil || controller.loadingFiles)
                    } else if controller.lastAnswer != nil {
                        NativeHoverButton(title: responseTitle, action: paste) {
                            HStack(spacing: 6) {
                                Text(responseTitle).font(.system(size: 12))
                                Keycap(text: "↩")
                            }
                        }.fixedSize(horizontal: true, vertical: false)
                    }
                    }
                }
            } trailing: {
                Color.clear.allowsHitTesting(false)
            }
        } trailing: {
            NativeHoverButton(title: "在 AI Chat 中继续", action: openChat) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 18))
            }.frame(width: VisualStyle.launcherControlDiameter, height: VisualStyle.launcherControlDiameter)
        }
        .overlay {
            if controller.loadingChat { ProgressView("正在读取对话…").padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
        .onAppear { input = model.query }
        .alert("无法附加文件", isPresented: Binding(get: { !controller.fileError.isEmpty }, set: { if !$0 { controller.fileError = "" } })) {
            Button("好") { controller.fileError = "" }
        } message: { Text(controller.fileError) }
        .onChange(of: input) { _, value in if model.query != value { model.query = value } }
        .onReceive(model.$query) { value in if input != value { input = value } }
    }

    private var responseTitle: String {
        if model.aiInteraction.primaryAction == .paste, let app = (NSApp.delegate as? Delegate)?.pasteTargetName { return "粘贴到 \(app)" }
        return "复制回复"
    }

    private func submit() {
        guard !SearchField.isComposing, !controller.running, !controller.loadingFiles, !controller.loadingChat else { return }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && controller.pendingFiles.isEmpty { paste() }
        else if controller.submit(input) { input = "" }
    }

    private func paste() {
        QuickAILauncher.useResponse(controller, copyOnly: model.aiInteraction.primaryAction == .copy)
    }
}
