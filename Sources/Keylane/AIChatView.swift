import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AIChatView: View {
    enum Column { case sidebar, conversation, settings }
    var column: Column = .conversation
    @ObservedObject var controller: QuickAIController
    @ObservedObject var configuration: AIConfiguration
    @ObservedObject var interaction: AIInteractionPreferences
    @ObservedObject var composer: AIChatComposer
    @ObservedObject var presentation: AIChatPresentation
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var editorFocused: Bool
    @State private var search = ""
    @State private var showsArchive = false
    @State private var pendingDeletion: AIChatSummary?
    @State private var renaming: AIChatSummary?
    @State private var renamedTitle = ""
    @State private var pendingModel: UUID?
    @State private var attachmentError: String?

    private var visibleChats: [AIChatSummary] {
        controller.chats.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    private var canSubmit: Bool {
        !controller.running && !controller.loadingChat && controller.matchesCurrentModel &&
        controller.currentConnection != nil && !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            switch column {
            case .sidebar: sidebar
            case .conversation: conversation
            case .settings: settings
            }
        }
        .overlay(alignment: .topTrailing) {
            if column == .conversation, presentation.actionsVisible {
                ZStack(alignment: .topTrailing) {
                    Color.primary.opacity(0.001)
                        .onTapGesture { presentation.actionsVisible = false }
                    AIChatActionMenu(actions: actions, dismiss: { presentation.actionsVisible = false })
                        .padding(18)
                }
            }
        }
        .overlay(alignment: .top) {
            if column == .conversation {
                WindowLoadingIndicator(loading: controller.$running.combineLatest(controller.$loadingChat)
                    .map { $0 || $1 }.eraseToAnyPublisher())
            }
        }
        .task { if column == .conversation { editorFocused = true } }
        .onChange(of: search) { _, value in if !value.isEmpty { showsArchive = true } }
        .onReceive(controller.historyOpened) { _ in
            if column == .conversation { composer.text = "" }
        }
        .onChange(of: controller.chatID) { old, current in
            if old != nil && current == nil { composer.text = "" }
        }
        .onExitCommand {
            if presentation.actionsVisible { presentation.actionsVisible = false }
            else if presentation.settingsVisible { presentation.settingsVisible = false }
            else { (NSApp.delegate as? Delegate)?.closeUtilityWindowOnEscape() }
        }
        .background {
            if column == .conversation { Group {
                Button("新对话", action: newChat).keyboardShortcut("n", modifiers: .command)
                Button("操作") { presentation.actionsVisible.toggle() }.keyboardShortcut("k", modifiers: .command)
                Button("聊天设置") { presentation.settingsVisible.toggle() }.keyboardShortcut(",", modifiers: [.command, .shift])
                Button("发送", action: submit).keyboardShortcut(.return, modifiers: .command).disabled(!canSubmit)
            }.hidden().accessibilityHidden(true) }
        }
        .confirmationDialog("删除这段对话？", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { item in
            Button("删除对话", role: .destructive) { controller.deleteChat(item.id); pendingDeletion = nil }
        }
        .confirmationDialog("使用所选模型开始新对话？", isPresented: Binding(
            get: { pendingModel != nil }, set: { if !$0 { pendingModel = nil } }
        ), titleVisibility: .visible) {
            Button("新建对话") {
                guard let id = pendingModel else { return }
                newChat()
                controller.chooseChatModel(id)
                pendingModel = nil
            }
        }
        .alert("重命名对话", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("对话名称", text: $renamedTitle)
            Button("保存") {
                if let renaming { controller.updateChat(renaming.id, change: .rename(renamedTitle)) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .alert("无法添加附件", isPresented: Binding(
            get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } }
        )) { Button("好") { attachmentError = nil } } message: { Text(attachmentError ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索对话", text: $search).textFieldStyle(.plain)
                    .accessibilityLabel("搜索对话")
                if !search.isEmpty {
                    Button("清除搜索", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(11)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 12).padding(.top, 12)

            List(selection: Binding<UUID?>(get: { controller.chatID }, set: { id in
                guard let id else { return }
                controller.openChat(id)
                editorFocused = true
            })) {
                let pinned = visibleChats.filter { $0.pinned && !$0.archived }
                if !pinned.isEmpty {
                    Section { ForEach(pinned) { chatRow($0) } } header: { Label("置顶", systemImage: "pin") }
                }
                Section {
                    if controller.chatID == nil {
                        Text("新对话").font(.system(size: 13, weight: .medium)).padding(.vertical, 6)
                            .listRowBackground(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.08)).padding(.horizontal, 8))
                    }
                    ForEach(visibleChats.filter { !$0.pinned && !$0.archived }) { chatRow($0) }
                } header: { Label("最近", systemImage: "bubble.left") }
                Section {
                    DisclosureGroup(isExpanded: $showsArchive) {
                        ForEach(visibleChats.filter(\.archived)) { chatRow($0) }
                    } label: { Label("归档", systemImage: "archivebox") }
                }
            }
            .listStyle(.sidebar)
            .tint(.gray)
            .scrollContentBackground(.hidden)
            .overlay {
                if !search.isEmpty, visibleChats.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            if !controller.historyError.isEmpty {
                Text(controller.historyError).font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .background(.background.secondary)
    }

    private func chatRow(_ item: AIChatSummary) -> some View {
        Text(item.title.isEmpty ? "新对话" : item.title)
            .font(.system(size: 13, weight: .medium)).lineLimit(1)
            .padding(.vertical, 7).tag(item.id)
            .contextMenu {
                Button(item.pinned ? "取消置顶" : "置顶", systemImage: "pin") {
                    controller.updateChat(item.id, change: .pin(!item.pinned))
                }
                Button("重命名…", systemImage: "pencil") { renaming = item; renamedTitle = item.title }
                Button(item.archived ? "取消归档" : "归档", systemImage: "archivebox") {
                    controller.updateChat(item.id, change: .archive(!item.archived))
                }
                Divider()
                Button("删除…", role: .destructive) { pendingDeletion = item }
            }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            ZStack {
                AIConversationTranscript(controller: controller, showsEmptyHint: false)
                    .id(controller.chatID)
                    .frame(maxWidth: presentation.fullWidth ? .infinity : 820)
                if controller.turns.isEmpty, !controller.loadingChat {
                    Image(systemName: "sparkles")
                        .font(.system(size: 52, weight: .ultraLight))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                if controller.loadingChat { ProgressView("正在读取对话…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            composerView.frame(maxWidth: presentation.fullWidth ? .infinity : 820)
                .padding(.horizontal, 22).padding(.bottom, 18).padding(.top, 10)
        }
        .background(colorScheme == .dark ? Color(white: 0.065) : Color(nsColor: .textBackgroundColor))
    }

    private var composerView: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let message = configurationMessage {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("AI 设置") { openAISettings() }.buttonStyle(ContentActionButtonStyle())
                }
            }
            HStack(alignment: .center, spacing: 8) {
                Menu {
                    Button("添加文本文件…", systemImage: "doc.badge.plus", action: addTextFile)
                    Button("插入剪贴板文字", systemImage: "clipboard", action: insertClipboard)
                } label: {
                    Image(systemName: "plus").font(.system(size: 19)).frame(width: 30, height: 34)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(controller.loadingChat)
                .help("添加上下文")

                TextField("输入问题…", text: $composer.text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .lineLimit(1...7).padding(.vertical, 7)
                    .focused($editorFocused)
                    .disabled(controller.loadingChat || !controller.matchesCurrentModel)
                    .accessibilityLabel("问题")
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard interaction.chatReturn, press.modifiers.isEmpty, !SearchField.isComposing else { return .ignored }
                        submit()
                        return .handled
                    }
                if controller.running {
                    Button("停止生成", systemImage: "stop.fill", action: controller.stop)
                        .labelStyle(.iconOnly).buttonStyle(.plain).frame(width: 34, height: 34)
                } else {
                    if let delegate = NSApp.delegate as? Delegate {
                        DictationComposerButton(controller: delegate.model.dictation, text: $composer.text)
                            .id(controller.chatID)
                    }
                    Button("发送", systemImage: "arrow.up", action: submit)
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                        .frame(width: 30, height: 30)
                        .background(.primary.opacity(0.09), in: Circle())
                        .disabled(!canSubmit)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
        }
    }

    private var configurationMessage: String? {
        if !configuration.state.enabled { return "请先启用 AI 并配置模型。" }
        if !controller.matchesCurrentModel { return "原对话模型不可用，请恢复连接或新建对话。" }
        if controller.currentConnection == nil { return "请先配置聊天模型。" }
        return nil
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("模型").font(.subheadline).foregroundStyle(.secondary)
                        Menu {
                            ForEach(configuration.state.connections.filter { $0.isConfigured && $0.hiddenFromPicker != true }) { connection in
                                Button {
                                    guard controller.currentConnection?.id != connection.id else { return }
                                    if !controller.chooseChatModel(connection.id) { pendingModel = connection.id }
                                } label: {
                                    if controller.currentConnection?.id == connection.id {
                                        Label(connection.displayName, systemImage: "checkmark")
                                    } else { Text(connection.displayName) }
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "cube")
                                Text(controller.currentConnection?.displayName ?? "选择模型").lineLimit(2)
                                Spacer()
                                Image(systemName: "chevron.down").font(.caption)
                            }
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .disabled(controller.loadingChat || !configuration.state.enabled)
                        .padding(12)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.15)) }
                        if let connection = controller.currentConnection {
                            Text(connection.providerLabel).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("附加指令").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $controller.chatInstructions)
                            .font(.system(size: 13)).scrollContentBackground(.hidden)
                            .padding(8).frame(minHeight: 120)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.15)) }
                            .accessibilityLabel("附加指令")
                        Text("应用于这段对话的后续消息。").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Toggle("回车发送", isOn: $interaction.chatReturn).toggleStyle(.switch)
                    Toggle("窗口置顶", isOn: $interaction.chatFloating).toggleStyle(.switch)
                    Toggle("全宽对话", isOn: $presentation.fullWidth).toggleStyle(.switch)
                    Button("管理模型与提供方…", action: openAISettings)
                        .buttonStyle(ContentActionButtonStyle())
                }.padding(20)
            }
        }
    }

    private var actions: [AIChatActionMenu.Item] {
        var items: [AIChatActionMenu.Item] = [
            .init(title: "新对话", symbol: "square.and.pencil", keys: "⌘ N", action: newChat),
            .init(title: "添加文本文件…", symbol: "doc.badge.plus", action: addTextFile),
            .init(title: "插入剪贴板文字", symbol: "clipboard", action: insertClipboard),
            .init(title: "复制最新回复", symbol: "doc.on.doc", enabled: controller.lastAnswer != nil) {
                AIConversationTranscript.copy(controller.lastAnswer)
            },
            .init(title: "聊天设置", symbol: "slider.horizontal.3", keys: "⇧ ⌘ ,") { presentation.settingsVisible = true },
            .init(title: presentation.fullWidth ? "使用标准宽度" : "全宽对话", symbol: "arrow.left.and.right") { presentation.fullWidth.toggle() }
        ]
        if let item = controller.chats.first(where: { $0.id == controller.chatID }) {
            items += [
                .init(title: item.pinned ? "取消置顶" : "置顶对话", symbol: "pin") { controller.updateChat(item.id, change: .pin(!item.pinned)) },
                .init(title: "重命名…", symbol: "pencil") { renaming = item; renamedTitle = item.title },
                .init(title: item.archived ? "取消归档" : "归档对话", symbol: "archivebox") { controller.updateChat(item.id, change: .archive(!item.archived)) }
            ]
        }
        if controller.running { items.append(.init(title: "停止生成", symbol: "stop", action: controller.stop)) }
        return items
    }

    private func newChat() {
        controller.reset()
        composer.text = ""
        editorFocused = true
        presentation.actionsVisible = false
    }
    private func submit() {
        guard !SearchField.isComposing, canSubmit else { return }
        if controller.submit(composer.text) { composer.text = "" }
    }
    private func openAISettings() { (NSApp.delegate as? Delegate)?.model.openSettings(page: "ai") }
    private func insertClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        appendContext(text)
    }
    private func appendContext(_ text: String) {
        guard composer.text.utf8.count + text.utf8.count + 2 <= 32_000 else {
            attachmentError = "加入后的内容超过 32,000 字节，请缩短文本后重试。"
            return
        }
        composer.text += (composer.text.isEmpty ? "" : "\n\n") + text
        editorFocused = true
    }
    private func addTextFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
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
                appendContext("\(url.lastPathComponent)\n\n\(text)")
            } catch { attachmentError = "无法读取所选文件。" }
        }
    }
}

struct AIChatActionMenu: View {
    struct Item: Identifiable {
        var id: String { title }
        let title: String
        let symbol: String
        var keys = ""
        var enabled = true
        let action: () -> Void
    }
    let actions: [Item]
    let dismiss: () -> Void
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private var filtered: [Item] {
        actions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("搜索操作…", text: $query).textFieldStyle(.plain)
                .padding(16).focused($searchFocused)
                .onSubmit {
                    guard !SearchField.isComposing,
                          let item = filtered.first(where: { $0.id == selection && $0.enabled }) else { return }
                    dismiss()
                    item.action()
                }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filtered) { item in
                            LauncherMenuRow(title: item.title, symbol: item.symbol,
                                            selected: selection == item.id, enabled: item.enabled,
                                            activate: { dismiss(); item.action() },
                                            highlight: { selection = item.id }) {
                                Text(item.keys).font(.caption).foregroundStyle(.secondary)
                            }.id(item.id)
                        }
                        if filtered.isEmpty { Text("没有匹配的操作").foregroundStyle(.secondary).padding(20) }
                    }.padding(8)
                }
                .frame(height: min(390, CGFloat(max(1, filtered.count)) * 42 + 16))
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .frame(width: 370)
        .modifier(LauncherMenuSurface(open: true))
        .shadow(color: .black.opacity(0.16), radius: 22, y: 8)
        .task { searchFocused = true; selection = filtered.first(where: \.enabled)?.id }
        .onChange(of: query) { _, _ in selection = filtered.first(where: \.enabled)?.id }
        .onExitCommand(perform: dismiss)
    }

    private func moveSelection(_ delta: Int) {
        let enabled = filtered.filter(\.enabled)
        guard !enabled.isEmpty else { selection = nil; return }
        let current = enabled.firstIndex(where: { $0.id == selection }) ?? 0
        selection = enabled[min(enabled.count - 1, max(0, current + delta))].id
    }
}
