import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum QuickAILauncher {
    static let pageID = PageID(rawValue: "quick-ai")
    static let commandID = CommandID(rawValue: "quick-ai")

    static func page(model: Model, controller: AIConversationSession, openChat: @escaping () -> Void) -> LauncherPage {
        var page = LauncherPage(id: pageID, placeholder: "向 AI 提问…", badge: ("Quick AI", "sparkles"),
                     contentPlacement: .conversation, content: {
                         AnyView(QuickAIConversationPage(model: model, controller: controller, openChat: openChat))
                     },
                     leave: controller.leaveLauncher, submit: { [weak model] in
                         guard let model, !SearchField.isComposing else { return }
                         if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && controller.composer.attachments.isEmpty {
                             useResponse(controller, copyOnly: model.aiInteraction.primaryAction == .copy)
                         } else if controller.submit(model.query) { model.query = "" }
                     }, primaryTitle: { "发送" }, primaryEnabled: { [weak model] in
                         guard let model else { return false }
                         return controller.currentConnection != nil && !controller.running && !controller.loadingChat && !controller.composer.loadingFiles
                             && (!model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.lastAnswer != nil || !controller.composer.attachments.isEmpty)
                     }, actions: { [weak model] in
                         guard let model else { return [] }
                         return QuickAIActions.items(model: model, controller: controller, openChat: openChat)
                     }, updates: Publishers.MergeMany([
                         controller.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                         controller.composer.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                         model.aiInteraction.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                         model.aiSettings.objectWillChange.map { _ in () }.eraseToAnyPublisher()
                     ]).eraseToAnyPublisher(), actionShortcutsEnabled: true)
        page.badgeActions = {
            [.init(id: "quick-ai-file", title: "附加文件…", icon: "doc.badge.plus", enabled: !controller.composer.loadingFiles && !controller.loadingChat, perform: { AIConversationHostActions.chooseFiles(composer: controller.composer) })]
        }
        page.returnBindings = .init(primary: .plain, alternates: [
            .command: .init(perform: { useResponse(controller, copyOnly: model.aiInteraction.primaryAction == .paste) }),
            .option: .init(perform: { useResponse(controller, formatted: true) })
        ])
        page.actionContextTitle = { controller.conversationTitle }
        page.enter = controller.consumeEntry
        page.keepsStateWhenHidden = true
        page.fullBleed = true
        return page
    }
    static func useResponse(_ controller: AIConversationSession, formatted: Bool = false, copyOnly: Bool = false) {
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

private struct QuickAIConversationPage: View {
    let model: Model
    @ObservedObject var controller: AIConversationSession
    let openChat: () -> Void
    @Environment(\.conversationInputEnabled) private var inputEnabled
    @Environment(\.conversationInputFocusToken) private var inputFocusToken

    var body: some View {
        QuickAIConversationContent(model: model, controller: controller, composer: controller.composer,
                                   openChat: openChat, inputEnabled: inputEnabled, focusToken: inputFocusToken)
    }
}

private struct QuickAIConversationContent: View {
    let model: Model
    @ObservedObject var controller: AIConversationSession
    @ObservedObject var composer: AIConversationComposer
    let openChat: () -> Void
    let inputEnabled: Bool
    let focusToken: Int
    @State private var usageTarget: AIConnection?
    @State private var composerHeight: CGFloat = VisualStyle.launcherBottomInset
    private var composerInset: CGFloat { max(VisualStyle.launcherBottomInset, composerHeight + VisualStyle.launcherEdgeInset) }

    var body: some View {
        ConversationLayout(title: controller.conversationTitle,
                           subtitle: controller.quickModelIsAutomatic
                               ? "自动 · " + model.aiInteraction.modelPreference.title + " · " + (controller.currentConnection?.displayName ?? "请选择模型")
                               : controller.currentConnection?.displayName ?? "请选择模型",
                           isEmpty: controller.turns.isEmpty && controller.status.isEmpty,
                           composerInset: composerInset, back: { model.goBackInLauncher() }) {
            AIConversationTranscript(controller: controller, inLauncher: true, composerInset: composerInset)
        } composer: {
            AIConversationComposerView(controller: controller, configuration: model.aiSettings,
                interaction: model.aiInteraction, composer: composer,
                canSubmit: controller.canSendDraft,
                submit: submit, newChat: { controller.reset(); model.query = "" },
                chooseModel: { _ = controller.chooseModel($0, behavior: .forkContinuation) },
                showUsage: { usageTarget = controller.currentConnection },
                openAISettings: { model.openSettings(page: "ai") }, compact: true,
                inputEnabled: inputEnabled, focusToken: focusToken,
                emptyAction: { QuickAILauncher.useResponse(controller, copyOnly: model.aiInteraction.primaryAction == .copy) },
                emptyActionTitle: responseTitle, escape: {
                    if controller.running { controller.stop() } else { model.cancelLauncherPage() }
                }, commandReturn: {
                    QuickAILauncher.useResponse(controller, copyOnly: model.aiInteraction.primaryAction == .paste)
                }, optionReturn: { QuickAILauncher.useResponse(controller, formatted: true) })
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { composerHeight = $0 }
        } trailing: {
            NativeHoverButton(title: "在 AI Chat 中继续", action: openChat) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 18))
            }.frame(width: VisualStyle.launcherControlDiameter, height: VisualStyle.launcherControlDiameter)
        }
        .sheet(item: $usageTarget) { connection in AISubscriptionUsage(connection: connection) }
        .onAppear { if composer.text.isEmpty { composer.offer(model.query) } }
        .onChange(of: composer.text) { _, value in if model.query != value { model.query = value } }
        .onReceive(model.$query) { value in if composer.text != value { composer.text = value } }
    }

    private var responseTitle: String {
        if model.aiInteraction.primaryAction == .paste, let app = (NSApp.delegate as? Delegate)?.pasteTargetName { return "粘贴到 \(app)" }
        return "复制回复"
    }

    private func submit() {
        guard !SearchField.isComposing else { return }
        if composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composer.attachments.isEmpty {
            QuickAILauncher.useResponse(controller, copyOnly: model.aiInteraction.primaryAction == .copy)
        } else { _ = controller.submit(composer.text) }
    }
}
