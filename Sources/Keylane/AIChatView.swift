import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct AIChatView: View {
    enum Column { case sidebar, conversation, settings }
    var column: Column = .conversation
    let controller: QuickAIController
    @StateObject private var observation: ViewObservation
    @ObservedObject var configuration: AIConfiguration
    @ObservedObject var interaction: AIInteractionPreferences
    let composer: AIChatComposer
    @ObservedObject var presentation: AIChatPresentation
    @Environment(\.colorScheme) private var colorScheme
    @State private var search = ""
    @State private var showsArchive = false
    @State private var pendingDeletion: AIChatSummary?
    @State private var renaming: AIChatSummary?
    @State private var renamedTitle = ""
    @State private var pendingModel: UUID?
    @State private var attachmentError: String?
    @State private var usageTarget: AIConnection?
    @State private var editingProject: AIChatProject?
    @State private var deletingProject: AIChatProject?
    @State private var collapsedProjects = Set<UUID>()
    @State private var editingTurn: QuickAIController.Turn?
    @State private var transcriptSearch = ""
    @State private var searchIndex = 0
    @State private var searchMatches: [UUID] = []
    @FocusState private var transcriptSearchFocused: Bool

    init(column: Column = .conversation, controller: QuickAIController, configuration: AIConfiguration,
         interaction: AIInteractionPreferences, composer: AIChatComposer, presentation: AIChatPresentation) {
        self.column = column
        self.controller = controller
        self.configuration = configuration
        self.interaction = interaction
        self.composer = composer
        self.presentation = presentation
        let scope: QuickAIController.ViewScope = column == .sidebar ? .sidebar : column == .settings ? .settings : .conversation
        var inputs = controller.viewUpdates(scope)
        if column == .conversation { inputs.append(composer.objectWillChange.eraseToAnyPublisher()) }
        _observation = StateObject(wrappedValue: ViewObservation(inputs))
    }

    private var visibleChats: [AIChatSummary] {
        controller.chats.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    private var canSubmit: Bool {
        !controller.running && !controller.loadingChat && controller.matchesCurrentModel &&
        controller.currentConnection != nil && (!composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composer.attachments.isEmpty)
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
        .task { if column == .conversation { composer.focusRequested.send() } }
        .onChange(of: search) { _, value in if !value.isEmpty { showsArchive = true } }
        .onReceive((column == .conversation ? controller.$turns.eraseToAnyPublisher() : Empty<[QuickAIController.Turn], Never>().eraseToAnyPublisher()).throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)) { turns in
            if column == .conversation, !transcriptSearch.isEmpty { updateSearch(turns) }
        }
        .onChange(of: transcriptSearch) { _, _ in searchIndex = 0; updateSearch(controller.turns) }
        .onReceive(presentation.createProjectRequested) { _ in
            if column == .conversation { editingProject = AIChatProject() }
        }
        .onReceive(controller.historyOpened) { _ in
            if column == .conversation {
                composer.clear(); transcriptSearch = ""; searchIndex = 0; composer.focusRequested.send()
            }
        }
        .onReceive(controller.chatReset) { _ in
            if column == .conversation { composer.clear() }
        }
        .onExitCommand {
            if presentation.actionsVisible { presentation.actionsVisible = false }
            else if presentation.searchVisible { presentation.searchVisible = false }
            else if presentation.settingsVisible { presentation.settingsVisible = false }
            else { (NSApp.delegate as? Delegate)?.closeUtilityWindowOnEscape() }
        }
        .background {
            if column == .conversation { Group {
                Button("新对话", action: { newChat() }).keyboardShortcut("n", modifiers: .command)
                Button("搜索当前对话") { presentation.searchVisible.toggle() }.keyboardShortcut("f", modifiers: .command)
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
        .sheet(item: $editingProject) { project in
            AIChatProjectEditor(controller: controller, project: project) { saved in
                collapsedProjects.remove(saved.id)
            }
        }
        .confirmationDialog("移除项目？聊天记录会保留，并解除项目归组。", isPresented: Binding(
            get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }
        ), titleVisibility: .visible) {
            Button("移除项目", role: .destructive) {
                if let project = deletingProject { controller.removeProject(project.id) }
                deletingProject = nil
            }
        }
        .sheet(item: $usageTarget) { connection in AISubscriptionUsage(connection: connection) }
        .sheet(item: $editingTurn) { turn in
            AIChatQuestionEditor(controller: controller, turn: turn) { text in
                guard controller.resubmit(turn.id, question: text) else { return false }
                branchCreated()
                return true
            }
        }
        .alert("无法添加附件", isPresented: Binding(
            get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } }
        )) { Button("好") { attachmentError = nil } } message: { Text(attachmentError ?? "") }
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("", text: $search, prompt: Text("搜索对话").foregroundStyle(.secondary))
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .accessibilityLabel("搜索对话")
                if !search.isEmpty {
                    Button("清除搜索", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .glassEffect(.regular, in: Capsule())
            .padding(.horizontal, 12).padding(.top, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let pinned = visibleChats.filter { $0.pinned && !$0.archived }
                    if !pinned.isEmpty {
                        AIChatSidebarHeading(title: "置顶", symbol: "pin")
                        ForEach(pinned) { chatRow($0) }
                    }
                    projectSections
                    AIChatSidebarHeading(title: "最近", symbol: "bubble.left")
                    if controller.chatID == nil && controller.currentProjectID == nil {
                        AIChatSidebarRow(title: "新对话", selected: true, action: { newChat() })
                    }
                    ForEach(visibleChats.filter { !$0.pinned && !$0.archived && $0.projectID == nil }) { chatRow($0) }
                    AIChatSidebarHeading(title: "归档", symbol: "archivebox", expanded: $showsArchive)
                    if showsArchive { ForEach(visibleChats.filter(\.archived)) { chatRow($0) } }
                    if !search.isEmpty, visibleChats.isEmpty {
                        Text("没有匹配的对话").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                    }
                }.padding(.horizontal, AIChatStyle.sidebarInset).padding(.bottom, 12)
            }
            if !controller.historyError.isEmpty {
                Text(controller.historyError).font(.caption).foregroundStyle(.secondary).padding(12)
            }
        }
        .background(colorScheme == .dark ? Color(white: 0.095) : Color(nsColor: .controlBackgroundColor))
    }

    private var projectSections: some View {
        ForEach(controller.projects) { project in projectSection(project) }
    }

    private func projectSection(_ project: AIChatProject) -> some View {
        VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 0) {
                            AIChatSidebarHeading(title: project.name, symbol: project.symbol, expanded: Binding(
                                get: { !collapsedProjects.contains(project.id) },
                                set: { if $0 { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) } }))
                            Button("项目新对话", systemImage: "plus") { newChat(in: project.id) }
                                .labelStyle(.iconOnly).buttonStyle(.bordered).controlSize(.mini)
                                .padding(.top, 8).padding(.trailing, 8)
                        }.contextMenu {
                            Button("新对话", systemImage: "square.and.pencil") { newChat(in: project.id) }
                            Button("编辑项目…", systemImage: "pencil") { editingProject = project }
                            Button("移除项目…", role: .destructive) { deletingProject = project }
                        }
                        if !collapsedProjects.contains(project.id) {
                            if controller.chatID == nil && controller.currentProjectID == project.id {
                                AIChatSidebarRow(title: "新对话", selected: true) { newChat(in: project.id) }
                            }
                            ForEach(visibleChats.filter { !$0.pinned && !$0.archived && $0.projectID == project.id }) { chatRow($0) }
                        }
        }
    }

    private func chatRow(_ item: AIChatSummary) -> some View {
        AIChatSidebarRow(title: item.title, selected: controller.chatID == item.id) {
            controller.openChat(item.id)
            composer.focusRequested.send()
        }
            .contextMenu {
                Button("复制对话", systemImage: "doc.on.doc") { copyChat(item.id) }
                Button("创建分支", systemImage: "arrow.triangle.branch") { controller.duplicateChat(item.id) }
                Divider()
                Button(item.pinned ? "取消置顶" : "置顶", systemImage: "pin") {
                    controller.updateChat(item.id, change: .pin(!item.pinned))
                }
                Menu("移动到项目", systemImage: "folder") {
                    Button("不属于项目") { controller.moveChat(item.id, to: nil) }
                    ForEach(controller.projects) { project in
                        Button(project.name) { controller.moveChat(item.id, to: project.id) }
                    }
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
            if presentation.searchVisible { transcriptSearchBar }
            ZStack {
                AIConversationTranscript(controller: controller, showsEmptyHint: false,
                    editTurn: { editingTurn = $0 },
                    didBranch: branchCreated, searchTarget: searchTarget)
                    .id(controller.chatID)
                    .frame(maxWidth: presentation.fullWidth ? .infinity : AIChatStyle.contentWidth)
                if controller.turns.isEmpty, !controller.loadingChat {
                    Image(systemName: "sparkles")
                        .font(.system(size: 52, weight: .ultraLight))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                if controller.loadingChat { ProgressView("正在读取对话…") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            composerView.frame(maxWidth: presentation.fullWidth ? .infinity : AIChatStyle.contentWidth)
                .padding(.horizontal, 32).padding(.bottom, 18).padding(.top, 10)
        }
        .background(colorScheme == .dark ? Color(white: 0.065) : Color(nsColor: .textBackgroundColor))
    }

    private var composerView: some View {
        AIChatComposerView(controller: controller, configuration: configuration,
            interaction: interaction, composer: composer, canSubmit: canSubmit,
            submit: submit, newChat: { newChat() }, chooseModel: chooseChatModel,
            showUsage: { usageTarget = controller.currentConnection }, openAISettings: openAISettings)
    }

    private func chooseChatModel(_ id: UUID) {
        guard controller.currentConnection?.id != id else { return }
        if !controller.chooseChatModel(id) { pendingModel = id }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("标题").font(.subheadline).foregroundStyle(.secondary)
                        TextField("新对话", text: Binding(get: { controller.chatTitle }, set: controller.renameCurrentChat))
                            .textFieldStyle(.roundedBorder).disabled(controller.loadingChat)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("模型").font(.subheadline).foregroundStyle(.secondary)
                        AIModelPicker(configuration: configuration, selection: Binding(
                            get: { controller.currentConnection.map { .model($0.id) } ?? .inherit },
                            set: { choice in
                                guard case .model(let id) = choice, controller.currentConnection?.id != id else { return }
                                if !controller.chooseChatModel(id) { pendingModel = id }
                            }))
                            .disabled(controller.running || controller.loadingChat || !configuration.state.enabled)
                        if let connection = controller.currentConnection {
                            Text(connection.providerLabel).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("附加指令").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: Binding(get: { controller.chatInstructions }, set: { controller.chatInstructions = $0 }))
                            .font(.system(size: 13)).scrollContentBackground(.hidden)
                            .padding(8).frame(minHeight: 120)
                            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.15)) }
                            .accessibilityLabel("附加指令")
                        Text("应用于这段对话的后续消息。").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    AIChatCapabilitySection()
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
            .init(title: "创建项目…", symbol: "folder.badge.plus") { editingProject = AIChatProject() },
            .init(title: "新对话", symbol: "square.and.pencil", keys: "⌘ N", action: { newChat() }),
            .init(title: "添加文本文件…", symbol: "doc.badge.plus", action: { composer.contextRequested.send(.file) }),
            .init(title: "插入剪贴板文字", symbol: "clipboard", action: { composer.contextRequested.send(.clipboard) }),
            .init(title: "编辑最新问题…", symbol: "pencil", enabled: controller.canRevise && !controller.turns.isEmpty) {
                if let turn = controller.turns.last { editingTurn = turn }
            },
            .init(title: "重新生成最新回复", symbol: "arrow.clockwise", enabled: controller.canRevise && !controller.turns.isEmpty) {
                if let turn = controller.turns.last, controller.resubmit(turn.id) { branchCreated() }
            },
            .init(title: "从最新回复创建分支", symbol: "arrow.triangle.branch", enabled: controller.canRevise && controller.turns.last?.complete == true) {
                if let turn = controller.turns.last, controller.branch(after: turn.id) { branchCreated() }
            },
            .init(title: "复制整段对话", symbol: "doc.on.doc", enabled: controller.chatID != nil) {
                if let id = controller.chatID { copyChat(id) }
            },
            .init(title: "导出对话…", symbol: "square.and.arrow.up", enabled: !controller.turns.isEmpty, action: exportChat),
            .init(title: "在当前对话查找", symbol: "magnifyingglass", keys: "⌘ F") { presentation.searchVisible = true },
            .init(title: "AI 设置", symbol: "gearshape", action: openAISettings),
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
        if controller.currentConnection?.protocolKind.isSubscription == true {
            items.append(.init(title: "查看 AI 用量", symbol: "gauge.with.dots.needle.33percent") { usageTarget = controller.currentConnection })
        }
        if controller.running { items.append(.init(title: "停止生成", symbol: "stop", action: controller.stop)) }
        return items
    }

    private func copyChat(_ id: UUID) {
        let generation = NSPasteboard.general.changeCount
        controller.transcript(id) { text in
            guard NSPasteboard.general.changeCount == generation else { return }
            AIConversationTranscript.copy(text)
        }
    }

    private func exportChat() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Keylane Chat.md"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            let text = controller.turns.map { "## 用户\n\n" + $0.requestText + "\n\n## 助手\n\n" + $0.answer }.joined(separator: "\n\n")
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
            catch { attachmentError = "无法导出这段对话。" }
        }
    }

    private func updateSearch(_ turns: [QuickAIController.Turn]) {
        searchMatches = transcriptSearch.isEmpty ? [] : turns.filter {
            $0.question.localizedCaseInsensitiveContains(transcriptSearch) || $0.answer.localizedCaseInsensitiveContains(transcriptSearch)
        }.map(\.id)
        searchIndex = min(searchIndex, max(0, searchMatches.count - 1))
    }

    private var searchTarget: UUID? {
        let matches = searchMatches
        guard presentation.searchVisible, !transcriptSearch.isEmpty, !matches.isEmpty else { return nil }
        return matches[min(searchIndex, matches.count - 1)]
    }

    private var transcriptSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索当前对话…", text: $transcriptSearch).textFieldStyle(.plain)
                .focused($transcriptSearchFocused)
                .onSubmit { moveSearch(1) }
            Text(searchMatches.isEmpty ? "0" : "\(min(searchIndex + 1, searchMatches.count))/\(searchMatches.count)")
                .font(.caption).foregroundStyle(.secondary)
            Button("上一个", systemImage: "chevron.up") { moveSearch(-1) }.labelStyle(.iconOnly)
            Button("下一个", systemImage: "chevron.down") { moveSearch(1) }.labelStyle(.iconOnly)
            Button("关闭搜索", systemImage: "xmark") { presentation.searchVisible = false }.labelStyle(.iconOnly)
        }.buttonStyle(.bordered).padding(12)
            .onAppear { transcriptSearchFocused = true }
    }

    private func moveSearch(_ step: Int) {
        let count = searchMatches.count
        guard count > 0 else { return }
        searchIndex = (searchIndex + step + count) % count
    }

    private func branchCreated() {
        composer.clear()
        transcriptSearch = ""
        presentation.actionsVisible = false
        composer.focusRequested.send()
    }

    private func newChat() {
        controller.reset(projectID: controller.currentProjectID)
        transcriptSearch = ""
        searchMatches = []
        searchIndex = 0
        composer.clear()
        composer.focusRequested.send()
        presentation.actionsVisible = false
    }
    private func newChat(in projectID: UUID) {
        controller.reset(projectID: projectID)
        composer.clear()
        composer.focusRequested.send()
    }

    private func submit() {
        guard !SearchField.isComposing, canSubmit else { return }
        let question = composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请分析所附内容。" : composer.text
        if controller.submit(question, attachments: composer.attachments) {
            composer.clear()
        }
    }
    private func openAISettings() { (NSApp.delegate as? Delegate)?.model.openSettings(page: "ai") }

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
    @State private var scrollTarget: String?
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
                                            selected: selection == item.id, enabled: item.enabled, compact: true,
                                            activate: { dismiss(); item.action() },
                                            highlight: { selection = item.id }) {
                                Text(item.keys).font(.caption).foregroundStyle(.secondary)
                            }.id(item.id)
                        }
                        if filtered.isEmpty { Text("没有匹配的操作").foregroundStyle(.secondary).padding(20) }
                    }.padding(8)
                }
                .frame(height: min(390, CGFloat(max(1, filtered.count)) * 33 + 16))
                .onChange(of: scrollTarget) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .frame(width: 320)
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
        scrollTarget = selection
    }
}
