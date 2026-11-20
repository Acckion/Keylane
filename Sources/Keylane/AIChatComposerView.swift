import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The complete composer is reused as a unit: input, attachments, completion and context lifecycle.
struct AIChatComposerView: View {
    @ObservedObject var controller: QuickAIController
    @ObservedObject var configuration: AIConfiguration
    @ObservedObject var interaction: AIInteractionPreferences
    @ObservedObject var composer: AIChatComposer
    let canSubmit: Bool
    let submit: () -> Void
    let newChat: () -> Void
    let chooseModel: (UUID) -> Void
    let showUsage: () -> Void
    let openAISettings: () -> Void
    @State private var attachmentError: String?
    @State private var inputHeight: CGFloat = 36
    @State private var contextMenuOpen = false
    @State private var menuQuery = ""
    @State private var menuSelection: String?
    @State private var menuScrollTarget: String?
    @State private var suppressedCompletion: AIChatCompletionToken?
    @State private var contextSource: AIChatContextSheet.Source?
    @State private var contextReadTask: Task<Void, Never>?
    @State private var capability: AIChatCapabilityInfo?

    var body: some View {
        content
            .onDisappear { contextReadTask?.cancel() }
            .onChange(of: composer.draftID) { _, _ in contextReadTask?.cancel(); dismissComposerMenu() }
            .onReceive(composer.contextRequested) { request in
                switch request {
                case .file: addTextFile()
                case .clipboard: insertClipboard()
                }
            }
            .sheet(item: $capability) { AIChatCapabilityInfoView(feature: $0) }
            .sheet(item: $contextSource) { source in
                AIChatContextSheet(source: source) { attachment in addAttachment(attachment) }
            }
            .alert("无法添加上下文", isPresented: Binding(
                get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } }
            )) { Button("好") { attachmentError = nil } } message: { Text(attachmentError ?? "") }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let project = controller.currentProject {
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
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    contextMenuOpen.toggle()
                    menuQuery = ""
                    menuSelection = nil
                } label: {
                    Image(systemName: "plus").font(.system(size: 22, weight: .regular))
                        .frame(width: 34, height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain).help("添加上下文（@）")
                    .accessibilityLabel("添加上下文").disabled(controller.loadingChat)

                ZStack(alignment: .leading) {
                    if composer.text.isEmpty {
                        Text("输入问题，@ 添加上下文，/ 选择命令或模型…")
                            .font(.system(size: 14)).foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                    AIChatTextInput(composer: composer, height: $inputHeight,
                        enabled: !controller.loadingChat && controller.matchesCurrentModel,
                        sendWithReturn: interaction.chatReturn, menuVisible: composerMenuVisible,
                        submit: submit, moveMenu: moveComposerMenu, chooseMenu: chooseComposerMenu,
                        dismissMenu: dismissComposerMenu)
                        .frame(height: inputHeight)
                }
                if controller.running {
                    Button("停止生成", systemImage: "stop.fill", action: controller.stop)
                        .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 34, height: 34)
                } else if composer.text.isEmpty && composer.attachments.isEmpty {
                    Button("语音输入（尚未接入）", systemImage: "mic") { capability = .voice }
                        .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 30, height: 34)
                        .foregroundStyle(.secondary).help("语音输入：基础入口，尚未接入")
                } else {
                    Button("发送", systemImage: "arrow.up", action: submit)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .frame(width: 30, height: 30)
                        .background(.primary.opacity(0.09), in: Circle())
                        .disabled(!canSubmit)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        }
        .overlay(alignment: .topLeading) {
            if composerMenuVisible {
                AIChatComposerMenu(items: composerMenuItems, query: $menuQuery,
                    selection: $menuSelection, scrollTarget: $menuScrollTarget, searchable: contextMenuOpen,
                    activate: activateComposerItem, dismiss: dismissComposerMenu)
                    .offset(y: -AIChatComposerMenu.height(items: composerMenuItems, searchable: contextMenuOpen) - 8)
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

    private var composerMenuItems: [AIChatComposerMenu.Item] {
        typealias Item = AIChatComposerMenu.Item
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
            items += AITextCommand.allCases.map { command in
                Item(id: command.id, section: "AI 命令", title: command.title, symbol: command.icon) {
                    appendContext(command.instructions(language: .chinese))
                }
            }
            items += controller.projects.map { project in
                Item(id: "project-" + project.id.uuidString, section: "项目", title: project.name, symbol: project.symbol) {
                    controller.setProject(project.id)
                }
            }
            items += configuration.state.connections.filter { $0.isConfigured && $0.hiddenFromPicker != true }.map { connection in
                Item(id: connection.id.uuidString, section: "模型", title: connection.model,
                     symbol: "sparkles", detail: connection.providerLabel) {
                    chooseModel(connection.id)
                }
            }
        } else {
            items = [
                Item(id: "file", section: "上下文", title: "添加文本文件…", symbol: "doc", action: addTextFile),
                Item(id: "clipboard-history", section: "上下文", title: "剪贴板历史…", symbol: "clipboard") { contextSource = .clipboard },
                Item(id: "clipboard", section: "上下文", title: "当前剪贴板文字", symbol: "doc.on.clipboard", action: insertClipboard),
                Item(id: "screenshot", section: "上下文", title: "截图文字…", symbol: "viewfinder", action: addImageText),
                Item(id: "calendar", section: "上下文", title: "日历日程…", symbol: "calendar") { contextSource = .calendar },
                Item(id: "selection", section: "上下文", title: "选中文字", symbol: "text.cursor", action: insertSelectedText)
            ]
            if !contextMenuOpen {
                items += [
                    Item(id: "tools", section: "基础入口", title: "扩展工具…", symbol: "puzzlepiece.extension", detail: "待接入") { capability = .tools },
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

    private func activateComposerItem(_ item: AIChatComposerMenu.Item) {
        if !contextMenuOpen { composer.consumeCompletion() }
        dismissComposerMenu()
        item.action()
        composer.focusRequested.send()
    }

    private func dismissComposerMenu() {
        suppressedCompletion = composer.completion
        contextMenuOpen = false
        menuSelection = nil
        composer.focusRequested.send()
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
    private func addAttachment(_ attachment: AIChatAttachment) {
        let text = AIChatAttachment.requestText(question: composer.text, attachments: composer.attachments + [attachment])
        guard text.utf8.count <= 32_000 else {
            attachmentError = "问题与上下文合计不能超过 32,000 字节，请缩短内容后重试。"
            return
        }
        composer.attachments.append(attachment)
        composer.focusRequested.send()
    }

    private func addImageText() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.directoryURL = controller.currentProject?.directoryURL
        panel.allowedContentTypes = [.image]
        panel.prompt = "提取文字并添加"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            contextReadTask?.cancel()
            let draft = composer.draftID
            contextReadTask = Task { @MainActor in
                do {
                    let attachment = try await AIChatImageContext.read(url)
                    guard !Task.isCancelled, composer.draftID == draft else { return }
                    addAttachment(attachment)
                } catch is CancellationError { }
                catch { if composer.draftID == draft { attachmentError = error.localizedDescription } }
            }
        }
    }

    private func addTextFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.directoryURL = controller.currentProject?.directoryURL
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.text, .sourceCode, .json, .xml, .yaml]
        panel.prompt = "添加"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                let info = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = info.fileSize, size <= 32_000 else {
                    attachmentError = "请选择不超过 32,000 字节的文本文件。"
                    return
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 32_001) ?? Data()
                guard data.count <= 32_000, let text = String(data: data, encoding: .utf8) else {
                    attachmentError = "文件需要是 UTF-8 文本，且不超过 32,000 字节。"
                    return
                }
                addAttachment(.init(title: url.lastPathComponent, text: text))
            } catch { attachmentError = "无法读取所选文件。" }
        }
    }
}
