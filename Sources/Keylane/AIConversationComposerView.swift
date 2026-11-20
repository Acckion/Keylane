import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared editing and menus; the shell reserves host controls in Launcher and owns them in Chat.
struct AIConversationComposerView: View {
    @ObservedObject var controller: AIConversationSession
    @ObservedObject var configuration: AIConfiguration
    @ObservedObject var interaction: AIInteractionPreferences
    @ObservedObject var composer: AIConversationComposer
    let canSubmit: Bool
    let submit: () -> Void
    let newChat: () -> Void
    let chooseModel: (UUID) -> Void
    let showUsage: () -> Void
    let openAISettings: () -> Void
    var dictation: DictationController? = nil
    var compact = false
    var inputEnabled = true
    var focusToken = 0
    var emptyAction: (() -> Void)? = nil
    var emptyActionTitle = "复制回复"
    var escape: (() -> Void)? = nil
    var commandReturn: (() -> Void)? = nil
    var optionReturn: (() -> Void)? = nil
    @State private var attachmentError: String?
    @State private var inputHeight: CGFloat = 0
    private var style: ConversationComposerStyle { compact ? .launcher : .chat }
    @State private var contextMenuOpen = false
    @State private var menuQuery = ""
    @State private var menuSelection: String?
    @State private var menuScrollTarget: String?
    @State private var suppressedCompletion: AIChatCompletionToken?
    @State private var contextRequest: AIConversationDraftContextRequest<AIContextRegistration>?
    @State private var toolsPresented = false
    @State private var capability: AIChatCapabilityInfo?

    var body: some View {
        content
            .onAppear { if compact && inputEnabled { composer.focusRequested.send() } }
            .onChange(of: focusToken) { _, _ in if inputEnabled { composer.focusRequested.send() } }
            .onChange(of: inputEnabled) { _, enabled in if enabled { composer.focusRequested.send() } }
            .alert("无法读取附件", isPresented: Binding(get: { !composer.fileError.isEmpty }, set: { if !$0 { composer.fileError = "" } })) {
                Button("好") { composer.fileError = "" }
            } message: { Text(composer.fileError) }
            .onChange(of: composer.draftID) { _, _ in contextRequest = nil; dismissComposerMenu() }
            .onReceive(configuration.$state.map(\.enabled).removeDuplicates()) { enabled in
                if !enabled { contextRequest = nil; dismissComposerMenu() }
            }
            .onReceive(composer.contextRequested) { request in
                switch request {
                case .file: addTextFile()
                case .clipboard: insertClipboard()
                }
            }
            .sheet(isPresented: $toolsPresented) {
                AIToolSettingsSheet(controller: controller, interaction: interaction)
            }
            .sheet(item: $capability) { AIChatCapabilityInfoView(feature: $0) }
            .sheet(item: $contextRequest) { request in
                AIChatContextSheet(source: request.source) { attachment in
                    guard configuration.state.enabled, contextRequest?.id == request.id else { return }
                    if composer.appendAttachment(attachment, from: request) {
                        composer.focusRequested.send()
                    } else if composer.draftID == request.draftID {
                        attachmentError = "问题与上下文合计不能超过 32,000 字节，且最多 5 项。"
                    }
                }
            }
            .alert("无法添加上下文", isPresented: Binding(
                get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } }
            )) { Button("好") { attachmentError = nil } } message: { Text(attachmentError ?? "") }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !compact, let project = controller.currentProject {
                HStack(spacing: 6) {
                    Label(project.name, systemImage: project.symbol).lineLimit(1)
                    Button("移出项目", systemImage: "xmark") { controller.setProject(nil) }.labelStyle(.iconOnly).buttonStyle(.plain)
                }.font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 6)
                    .background(.primary.opacity(0.06), in: Capsule())
            }
            if !composer.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(composer.attachments) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: attachment.symbol)
                                Text(attachment.title).lineLimit(1)
                                Button("移除上下文", systemImage: "xmark") {
                                    composer.attachments.removeAll { $0.id == attachment.id }
                                }.labelStyle(.iconOnly).buttonStyle(.plain)
                            }.font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 6)
                                .background(.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
            if let message = configurationMessage {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("AI 设置") { openAISettings() }.buttonStyle(ContentActionButtonStyle())
                }
            }
            ConversationComposer(style: style) {
                AIConversationTextInput(composer: composer, height: $inputHeight,
                    enabled: inputEnabled && !controller.loadingChat && controller.matchesCurrentModel,
                    sendWithReturn: compact || interaction.chatReturn, menuVisible: composerMenuVisible,
                    submit: submit, moveMenu: moveComposerMenu, chooseMenu: chooseComposerMenu,
                    dismissMenu: dismissComposerMenu, placeholder: compact ? "向 AI 提问…" : "输入问题…",
                    minimumHeight: style.editorMinimumHeight,
                    escape: escape, commandReturn: commandReturn, optionReturn: optionReturn)
                    .frame(height: max(style.editorMinimumHeight, inputHeight))
            } actions: {
                HStack(spacing: 8) {
                    if let dictation, !controller.running, !controller.loadingChat, inputEnabled {
                        DictationComposerButton(controller: dictation, composer: composer, controlSide: style.actionControlSide)
                    }
                    if composer.loadingFiles {
                        ProgressView().controlSize(.small).frame(width: style.actionControlSide, height: style.actionControlSide)
                    } else if controller.running {
                        Button("停止生成", systemImage: "stop.fill", action: controller.stop)
                            .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: style.actionControlSide, height: style.actionControlSide)
                    } else if compact && composer.text.isEmpty && composer.attachments.isEmpty, let emptyAction, controller.lastAnswer != nil {
                        Button(emptyActionTitle, action: emptyAction).buttonStyle(.plain).font(.system(size: 12))
                    } else if dictation == nil && composer.text.isEmpty && composer.attachments.isEmpty {
                        Button("语音输入（尚未接入）", systemImage: "mic") { capability = .voice }
                            .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: style.actionControlSide, height: style.actionControlSide)
                            .foregroundStyle(.secondary).help("语音输入：基础入口，尚未接入")
                    } else if !composer.text.isEmpty || !composer.attachments.isEmpty {
                        Button("发送", systemImage: "arrow.up", action: submit)
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                            .frame(width: style.actionControlSide, height: style.actionControlSide)
                            .background(.primary.opacity(0.09), in: Circle())
                            .disabled(!canSubmit)
                    }
                }
            } addButton: {
                LauncherExpandingMenu(open: contextMenuOpen,
                    closedSize: CGSize(width: style.controlDiameter, height: style.controlDiameter),
                    menuSize: CGSize(width: 345, height: AIConversationComposerMenu.height(items: composerMenuItems, searchable: true)),
                    dismiss: closeComposerMenu) {
                    ConversationFooterButton(title: "添加上下文（@）", symbol: "plus", diameter: style.controlDiameter) {
                        contextMenuOpen.toggle()
                        menuQuery = ""
                        menuSelection = nil
                    }
                    .disabled(controller.loadingChat || composer.loadingFiles)
                } menu: {
                    AIConversationComposerMenu(items: composerMenuItems, query: $menuQuery,
                        selection: $menuSelection, scrollTarget: $menuScrollTarget, searchable: true,
                        menuTitle: "AI Chat", embedded: true,
                        activate: activateComposerItem, dismiss: dismissComposerMenu)
                }
                .frame(width: style.controlDiameter, height: style.controlDiameter, alignment: .bottomLeading)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if composerMenuVisible && !contextMenuOpen {
                AIConversationComposerMenu(items: composerMenuItems, query: $menuQuery,
                    selection: $menuSelection, scrollTarget: $menuScrollTarget,
                    activate: activateComposerItem, dismiss: dismissComposerMenu)
                    .offset(x: style.reservedControlWidth,
                            y: -(max(style.fieldMinimumHeight, inputHeight + 12) + 8))
                    .zIndex(10)
            }
        }
        .onChange(of: composer.completion) { _, token in
            if token != suppressedCompletion { suppressedCompletion = nil; contextMenuOpen = false; menuSelection = nil }
        }
    }

    private var composerMenuVisible: Bool {
        contextMenuOpen || (composer.completion != nil && composer.completion != suppressedCompletion)
    }

    private var composerMenuItems: [AIConversationComposerMenu.Item] {
        typealias Item = AIConversationComposerMenu.Item
        let token = composer.completion
        let commands = !contextMenuOpen && token?.kind == .command
        var items: [Item]
        if commands {
            items = [
                Item(id: "settings", section: "命令", title: "AI 设置", symbol: "gearshape", action: openAISettings),
                Item(id: "new", section: "命令", title: "新对话", symbol: "square.and.pencil", action: newChat)
            ]
            if controller.currentConnection?.protocolKind.isSubscription == true {
                items.insert(Item(id: "usage", section: "命令", title: "/usage", symbol: "gauge.with.dots.needle.33percent", detail: "账户用量", action: showUsage), at: 0)
            }
            let registry = (NSApp.delegate as? Delegate)?.model.launcherModules
            items += (registry?.aiCommandEntries() ?? []).map { command in
                Item(id: command.id, section: "AI 命令", title: command.name, symbol: command.symbol) {
                    guard let delegate = NSApp.delegate as? Delegate else { return }
                    controller.preservingLauncherConversationDuring {
                        _ = delegate.model.runCommand(command.commandID, origin: .menu)
                    }
                }
            }
            items += controller.projects.map { project in
                Item(id: "project-" + project.id.uuidString, section: "项目", title: project.name, symbol: project.symbol) {
                    controller.setProject(project.id)
                }
            }
            let catalog = AIModelMenuCatalog(connections: configuration.state.connections,
                selection: controller.currentConnection.map { .model($0.id) } ?? .inherit, query: "")
            items += catalog.groups.flatMap(\.models).filter(\.isConfigured).map { connection in
                Item(id: connection.id.uuidString, section: "模型", title: connection.model,
                     symbol: "sparkles", detail: connection.providerLabel) {
                    chooseModel(connection.id)
                }
            }
        } else {
            items = [
                Item(id: "file", section: "上下文", title: "附加文件…", symbol: "doc.badge.plus", action: addTextFile),
                Item(id: "clipboard", section: "上下文", title: "当前剪贴板文字", symbol: "doc.on.clipboard", action: insertClipboard),
                Item(id: "screenshot", section: "上下文", title: "从图片文件提取文字…", symbol: "viewfinder", action: addImageText),
                Item(id: "selection", section: "上下文", title: "选中文字", symbol: "text.cursor", action: insertSelectedText)
            ]
            let registry = (NSApp.delegate as? Delegate)?.model.launcherModules
            items += (registry?.availableAIContexts ?? []).map { source in
                Item(id: source.id, section: "上下文", title: source.title + "…", symbol: source.symbol) {
                    contextRequest = composer.contextRequest(source)
                }
            }
            if !contextMenuOpen {
                items += [
                    Item(id: "tools", section: "基础入口", title: "扩展工具…", symbol: "puzzlepiece.extension", detail: interaction.toolsEnabled ? "已开启" : "已关闭") { toolsPresented = true },
                    Item(id: "skills", section: "基础入口", title: "技能…", symbol: "square.stack.3d.up", detail: "待接入") { capability = .skills }
                ]
            }
        }
        let query = contextMenuOpen ? menuQuery : token?.query ?? ""
        return items.filter { query.isEmpty || ($0.title + " " + $0.detail + " " + $0.id).localizedCaseInsensitiveContains(query) }
    }

    private func moveComposerMenu(_ delta: Int) {
        let items = composerMenuItems
        guard !items.isEmpty else { return }
        let index = menuSelection.flatMap { id in items.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : items.count)
        menuSelection = items[min(items.count - 1, max(0, index + delta))].id
        menuScrollTarget = menuSelection
    }

    private func chooseComposerMenu() {
        guard let item = composerMenuItems.first(where: { $0.id == menuSelection }) ?? composerMenuItems.first else { return }
        activateComposerItem(item)
    }

    private func activateComposerItem(_ item: AIConversationComposerMenu.Item) {
        if !contextMenuOpen { composer.consumeCompletion() }
        dismissComposerMenu()
        item.action()
        composer.focusRequested.send()
    }

    private func dismissComposerMenu() {
        closeComposerMenu()
        composer.focusRequested.send()
    }

    private func closeComposerMenu() {
        suppressedCompletion = composer.completion
        contextMenuOpen = false
        menuSelection = nil
    }

    private func insertSelectedText() {
        guard let text = AITextCommandLauncher.selectedText(), !text.isEmpty else {
            attachmentError = "未能读取选中文字，请先在其他应用中选择文本，并确认已授予辅助功能权限。"
            return
        }
        addAttachment(.init(title: "选中文字", text: text, symbol: "text.cursor"))
    }

    private var configurationMessage: String? {
        if !configuration.state.enabled { return "请先启用 AI 并配置模型。" }
        if !controller.matchesCurrentModel { return "原对话模型不可用，请恢复连接或新建对话。" }
        if controller.currentConnection == nil { return "请先配置聊天模型。" }
        return nil
    }

    private func insertClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        addAttachment(.init(title: "剪贴板文字", text: text, symbol: "clipboard"))
    }
    private func appendContext(_ text: String) {
        guard composer.text.utf8.count + text.utf8.count + 2 <= 32_000 else {
            attachmentError = "加入后的内容超过 32,000 字节，请缩短文本后重试。"
            return
        }
        composer.text += (composer.text.isEmpty ? "" : "\n\n") + text
        composer.selection = NSRange(location: composer.text.utf16.count, length: 0)
        composer.focusRequested.send()
    }
    private func addAttachment(_ attachment: AIConversationAttachment, for draft: UUID? = nil) {
        let expectedDraft = draft ?? composer.draftID
        guard composer.appendAttachment(attachment, for: expectedDraft) else {
            if composer.draftID == expectedDraft {
                attachmentError = "问题与上下文合计不能超过 32,000 字节，请缩短内容后重试。"
            }
            return
        }
        composer.focusRequested.send()
    }

    private func addImageText() {
        AIConversationHostActions.chooseImage(composer: composer, directory: controller.currentProject?.directoryURL) {
            try await AIChatImageContext.read($0)
        }
    }

    private func addTextFile() {
        AIConversationHostActions.chooseFiles(composer: composer, directory: controller.currentProject?.directoryURL)
    }
}
