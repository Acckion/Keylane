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
                         if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                             useResponse(controller)
                         } else if controller.submit(model.query) { model.query = "" }
                     }, primaryTitle: { "发送" }, primaryEnabled: { [weak model] in
                         guard let model else { return false }
                         return controller.currentConnection != nil && !controller.running
                             && (!model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.lastAnswer != nil)
                     }, actions: { [weak model] in
                         var actions = [LauncherAction(id: "quick-ai-copy", title: "复制回复", icon: "doc.on.doc",
                                                       enabled: controller.lastAnswer != nil) {
                             AIConversationTranscript.copy(controller.lastAnswer)
                         }]
                         actions.append(.init(id: "quick-ai-paste", title: "粘贴回复", icon: "doc.on.clipboard",
                                              enabled: controller.lastAnswer != nil && !controller.running) {
                             useResponse(controller)
                         })
                         if controller.running {
                             actions.append(.init(id: "quick-ai-stop", title: "停止生成", icon: "stop.fill",
                                                  perform: controller.stop))
                         }
                         actions.append(.init(id: "quick-ai-reset", title: "新对话", icon: "plus") {
                             controller.reset()
                             model?.query = ""
                         })
                         actions.append(.init(id: "quick-ai-continue", title: "在 AI Chat 中继续",
                                              icon: "bubble.left.and.bubble.right", shortcut: .init("j", modifiers: .command),
                                              perform: openChat))
                         return actions
                     }, updates: Publishers.Merge3(
                         controller.$running.removeDuplicates().map { _ in () },
                         controller.$turns.map { $0.contains { !$0.answer.isEmpty } }.removeDuplicates().map { _ in () },
                         ViewObservation.changes(model.aiSettings.$state.map { $0.connection(for: .quick) != nil })
                     ).eraseToAnyPublisher(), actionShortcutsEnabled: true)
        page.badgeActions = { [weak model] in
            [
                .init(id: "quick-ai-new", title: "新对话", icon: "plus",
                      shortcut: .init("n", modifiers: .command)) {
                    controller.reset()
                    model?.query = ""
                },
                .init(id: "quick-ai-settings", title: "AI 设置", icon: "gearshape") {
                    model?.openSettings(page: "ai")
                }
            ]
        }
        page.enter = { query in
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return controller.submit(query) ? "" : query
        }
        page.fullBleed = true
        return page
    }
    static func useResponse(_ controller: QuickAIController) {
        guard !controller.running, let answer = controller.lastAnswer else { return }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(answer, forType: .string) else { return }
        if let delegate = NSApp.delegate as? Delegate, delegate.pasteTargetName != nil {
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
            .onReceive(controller.$turns) { _ in
                guard followsBottom else { return }
                Task { @MainActor in proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private var styledScrollView: some View {
        if inLauncher { transcript.launcherScrollInsets().launcherScrollEdgeFade() }
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
                            Text(turn.question).textSelection(.enabled)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        }
                        if !turn.answer.isEmpty {
                            ReleaseNotesBody(notes: turn.answer)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        if !turn.complete && (!controller.running || turn.id != controller.turns.last?.id) {
                            Text("回复未完成").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if controller.running {
                    HStack {
                        ProgressView().controlSize(.small).accessibilityLabel("正在生成")
                        Text("正在生成回复…").foregroundStyle(.secondary)
                        if !inLauncher {
                            Button("停止生成", action: controller.stop).buttonStyle(ContentActionButtonStyle())
                        }
                    }
                }
                if !controller.status.isEmpty {
                    Text(controller.status).foregroundStyle(.secondary)
                }
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
        ConversationLayout(title: controller.turns.first?.question ?? "新对话",
                           subtitle: controller.currentConnection?.displayName ?? "请选择模型",
                           isEmpty: controller.turns.isEmpty && controller.status.isEmpty,
                           back: { model.goBackInLauncher() }) {
            AIConversationTranscript(controller: controller, inLauncher: true)
        } composer: {
            ConversationComposer {
                Color.clear.allowsHitTesting(false)
            } input: {
                HStack(spacing: 8) {
                    SearchField(text: $input, placeholder: "向 AI 提问…", focusToken: inputFocusToken, wantsFocus: inputEnabled, compact: true,
                                submit: submit, move: { _ in },
                                escape: {
                                    if controller.running { controller.stop() }
                                    else { model.cancelLauncherPage() }
                                })
                    if controller.running {
                        NativeHoverButton(title: "停止生成", action: controller.stop) {
                            Image(systemName: "stop.fill")
                        }.frame(width: 28, height: 28)
                    } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        NativeHoverButton(title: "发送", action: submit) {
                            Image(systemName: "arrow.up")
                        }.frame(width: 28, height: 28)
                            .disabled(controller.currentConnection == nil)
                    } else if controller.lastAnswer != nil {
                        NativeHoverButton(title: responseTitle, action: paste) {
                            HStack(spacing: 6) {
                                Text(responseTitle).font(.system(size: 12))
                                Keycap(text: "↩")
                            }
                        }.fixedSize(horizontal: true, vertical: false)
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
        .onAppear { input = model.query }
        .onChange(of: input) { _, value in if model.query != value { model.query = value } }
        .onReceive(model.$query) { value in if input != value { input = value } }
    }

    private var responseTitle: String {
        if let app = (NSApp.delegate as? Delegate)?.pasteTargetName { return "粘贴到 \(app)" }
        return "复制回复"
    }

    private func submit() {
        guard !SearchField.isComposing, !controller.running else { return }
        if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { paste() }
        else if controller.submit(input) { input = "" }
    }

    private func paste() {
        QuickAILauncher.useResponse(controller)
    }
}
