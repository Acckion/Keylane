import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum AIModule {
    static let models = SettingsItem(id: "ai-models", page: "ai-models", title: "模型与提供方",
                                     keywords: "AI 模型 提供方 接口 API 密钥 Keychain 流式 Ollama")

    static let textCommandsItem = SettingsItem(id: "ai-text-commands", page: "ai-text-commands", title: "AI 命令",
                                               keywords: "翻译 润色 摘要 自定义 提示词 导入 快捷键 translate polish summarize")
    static let interactions = SettingsItem(id: "ai-interactions", page: "ai", title: "Quick AI 与聊天",
                                           keywords: "Tab 回车 发送 备选命令 窗口置顶")

    static func make(model: Model) -> LauncherModule {
        let configuration = model.aiSettings
        let interaction = model.aiInteraction
        let runtime = model.aiRuntime
        let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/AI/history.sqlite")
        let quickAI = QuickAIController(configuration: configuration, runtime: runtime,
                                        history: AIChatHistory(url: historyURL))
        let chat = AIChatWindow(controller: quickAI, configuration: configuration, interaction: interaction,
                                appearance: model.$appearance.eraseToAnyPublisher())
        let openChat: (String?) -> Void = { [weak model] initialQuery in
            guard let model, configuration.state.enabled else { return }
            let fromQuickAI = model.pageID == QuickAILauncher.pageID
            chat.show(draft: initialQuery ?? (fromQuickAI ? model.query : ""), restoreLatest: !fromQuickAI && initialQuery == nil,
                      activation: model.windowActivationBehavior) {
                (NSApp.delegate as? Delegate)?.hideLauncher()
                if fromQuickAI { model.pageID = .root }
            }
        }
        let quickCommand = LauncherModule.Command(declaration: .init(
            id: QuickAILauncher.commandID, title: "Quick AI", detail: "向已配置的模型提问", symbol: "sparkles",
            keywords: ["ask", "AI", "快速问答", "询问 AI"], destination: .action, settingsPage: "ai"
        ), available: { configuration.state.connection(for: .quick) != nil }, acceptsFallbackQuery: true,
            fallbackAvailable: { interaction.rootFallback }, arguments: .init(count: 0...1) { [weak model] origin, arguments in
                if quickAI.isInChat { openChat(arguments.first) }
                else { model?.openPage(QuickAILauncher.pageID, origin: origin, initialQuery: arguments.first) }
            })
        let chatCommand = LauncherModule.Command(declaration: .init(
            id: .init(rawValue: "ai-chat"), title: "AI Chat", detail: "打开独立聊天窗口", symbol: "bubble.left.and.bubble.right",
            keywords: ["chat", "AI", "聊天", "对话"], destination: .action, settingsPage: "ai"
        ), available: { configuration.state.enabled }, execute: { _ in openChat(nil) })
        let textSession = AITextCommandSession(configuration: configuration, runtime: runtime)
        let library = CustomAICommandLibrary()
        let textCommands = AITextCommandLauncher.commands(model: model, session: textSession)
        return LauncherModule(id: .init(rawValue: "keylane.ai"), origin: .application,
                              title: "AI", symbol: "sparkles", commands: [quickCommand, chatCommand] + textCommands,
                              providers: [AITextCommandLauncher.customCommands(model: model, session: textSession, library: library)],
                              pages: [QuickAILauncher.page(model: model, controller: quickAI, openChat: { openChat(nil) }),
                                      AITextCommandLauncher.page(model: model, session: textSession, library: library)], settings: [
            .init(id: "ai", title: "AI", symbol: "sparkles", subtitle: "管理 AI 模型、连接与访问凭据。",
                  order: 8, items: [interactions],
                  titlebar: .init(title: "启用 AI",
                                  enabled: Binding(get: { configuration.state.enabled }, set: configuration.setEnabled),
                                  updates: configuration.$state.map(\.enabled).removeDuplicates().eraseToAnyPublisher()),
                  content: { [weak model] in
                      guard let model else { return AnyView(EmptyView()) }
                      return AnyView(AISettingsHome(model: model))
                  }),
            .init(id: models.page, title: models.title, symbol: "cpu",
                  subtitle: "管理模型、连接与访问凭据。", order: 9, items: [models], parentID: "ai",
                  content: { AnyView(AIModelSettings(configuration: configuration, runtime: runtime)) }),
            .init(id: textCommandsItem.page, title: textCommandsItem.title, symbol: "sparkles",
                  subtitle: "管理内置与自定义 AI 命令。", order: 9, items: [textCommandsItem], parentID: "ai",
                  content: { [weak model] in
                      guard let model else { return AnyView(EmptyView()) }
                      return AnyView(SettingsPageSections {
                          ExtensionCommandPreferences(model: model, commands: textCommands)
                          CustomAICommandSettings(model: model, library: library, configuration: configuration)
                              .settingsAnchor(textCommandsItem)
                      })
                  })
        ], searchUpdates: [
            ViewObservation.changes(configuration.$state.map(\.routeAvailability)),
            ViewObservation.changes(configuration.$state.map(\.isAvailable)),
            ViewObservation.changes(configuration.$state.map(\.enabled)),
            ViewObservation.changes(configuration.$state.map(\.availableConnectionIDs)),
            ViewObservation.changes(library.$commands),
            ViewObservation.changes(interaction.$rootFallback)
        ], dynamicCommandSettings: .init(model: model, items: { library.commands }, title: \.title,
                                        commandID: \.commandID, updates: { [ViewObservation.changes(library.$commands)] },
                                        entry: { $0.settingsEntry(model: $1) }))
    }
}

private struct AISettingsHome: View {
    let model: Model

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                link(AIModule.models)
                Divider()
                link(AIModule.textCommandsItem)
            }
            AIInteractionSettings(preferences: model.aiInteraction).settingsAnchor(AIModule.interactions)
        }
    }

    private func link(_ item: SettingsItem) -> some View {
        Button { model.settingsPage = item.page } label: {
            SettingsRow(item.title) {
                Image(systemName: "chevron.forward").imageScale(.small).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct AIInteractionSettings: View {
    @ObservedObject var preferences: AIInteractionPreferences

    var body: some View {
        SettingsGroup("Quick AI 与聊天") {
            toggle("搜索备选命令", detail: "没有匹配结果时显示 Quick AI。", value: $preferences.rootFallback)
            Divider()
            toggle("在主搜索中按 Tab 打开 Quick AI", detail: "将当前搜索文字带入输入框。", value: $preferences.rootTab)
            Divider()
            SettingsPicker("AI Chat 发送键", selection: $preferences.chatReturn) {
                Text("⌘ Return").tag(false)
                Text("Return").tag(true)
            }
            Divider()
            toggle("AI Chat 窗口置顶", value: $preferences.chatFloating)
        }
    }

    private func toggle(_ title: String, detail: String? = nil, value: Binding<Bool>) -> some View {
        SettingsRow(title, detail: detail) {
            Toggle(title, isOn: value).labelsHidden().toggleStyle(SettingsSwitchStyle())
        }
    }
}

private struct AIModelSettings: View {
    @ObservedObject var configuration: AIConfiguration
    let runtime: AIRuntime
    @State private var editingConnection: AIConnection?

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("共用模型连接", detail: "用于询问文件，以及跟随共用连接的 AI 入口。", selection: Binding<UUID?>(
                    get: { configuration.state.selectedID },
                    set: { if let id = $0 { configuration.select(id) } }
                )) {
                    if configuration.selected == nil { Text("尚未选择").tag(nil as UUID?) }
                    ForEach(configuration.state.connections.filter {
                        $0.hiddenFromPicker != true || $0.id == configuration.state.selectedID
                    }) { connection in
                        Text(connection.name.isEmpty ? connection.model : connection.name).tag(Optional(connection.id))
                    }
                }
                Divider()
                SettingsRow("模型与提供方", detail: "支持 OpenAI 兼容接口，可以添加多个连接。") {
                    HStack {
                        Button("添加 Ollama") {
                            editingConnection = AIConnection(name: "Ollama", endpoint: "http://127.0.0.1:11434/v1")
                        }
                        SettingsIconButton("添加连接", symbol: "plus") { editingConnection = AIConnection() }
                    }
                }
            }.settingsAnchor(AIModule.models)

            AIProviderSetupSettings(configuration: configuration, runtime: runtime)
            AICustomProviderSettings(configuration: configuration)
            AIModelCatalogSettings(configuration: configuration) { editingConnection = $0 }
        }
        .sheet(item: $editingConnection) { draft in
            if draft.protocolKind.isSubscription {
                AISubscriptionAdvanced(connection: draft, configuration: configuration)
            } else { ScrollView {
                let saved = configuration.state.connections.first { $0.id == draft.id }
                AIConnectionEditor(configuration: configuration, runtime: runtime, connection: saved ?? draft,
                                   isNew: saved == nil) { editingConnection = nil }
                    .id(saved != nil)
                    .padding(16)
            }.frame(width: 550, height: 560)
            }
        }
    }
}

private struct AIConnectionEditor: View {
    @ObservedObject var configuration: AIConfiguration
    let runtime: AIRuntime
    let connection: AIConnection
    let isNew: Bool
    let closeDraft: () -> Void
    @State private var draft: AIConnection
    @State private var key = ""
    @State private var hasKey = false
    @State private var status = ""
    @State private var test: Task<Void, Never>?
    @State private var discovery: Task<Void, Never>?
    @State private var discoveredModels: [String] = []
    @State private var showsModels = false
    @State private var contextTokens: String
    @State private var confirmRemoval = false
    @State private var confirmKeyDeletion = false

    init(configuration: AIConfiguration, runtime: AIRuntime, connection: AIConnection,
         isNew: Bool, closeDraft: @escaping () -> Void) {
        self.configuration = configuration
        self.runtime = runtime
        self.connection = connection
        self.isNew = isNew
        self.closeDraft = closeDraft
        _draft = State(initialValue: connection)
        _contextTokens = State(initialValue: connection.contextTokens.map(String.init) ?? "")
    }

    var body: some View {
        SettingsGroup {
            SettingsRow("连接名称") {
                TextField("例如，本机 Ollama", text: $draft.name).frame(width: 245)
            }
            Divider()
            SettingsRow("接口地址", detail: "远程服务使用 HTTPS，本机回环服务可使用 HTTP。") {
                TextField("https://example.com/v1", text: $draft.endpoint).frame(width: 245)
            }
            Divider()
            SettingsRow("模型 ID") {
                HStack {
                    TextField("提供方的模型标识", text: $draft.model).frame(width: 170)
                    if discovery != nil {
                        Button("停止", action: cancelDiscovery)
                    } else {
                        Button("同步模型", action: discoverModels)
                            .disabled(!configuration.state.enabled || draft.modelsURL == nil || test != nil)
                    }
                }
            }
            Divider()
            SettingsPicker("响应方式", detail: "流式逐段显示回复，完整响应兼容旧接口。", selection: $draft.mode) {
                Text("流式").tag(AIResponseMode.streaming)
                Text("完整响应").tag(AIResponseMode.complete)
            }
            Divider()
            SettingsRow("在默认模型选项中显示", detail: "已有默认设置及对话仍可使用此连接。") {
                Toggle("在默认模型选项中显示", isOn: Binding(get: { draft.hiddenFromPicker != true },
                    set: { draft.hiddenFromPicker = $0 ? nil : true })).labelsHidden()
            }
            Divider()
            SettingsRow("已知上下文长度", detail: "根据提供方资料填写，留空表示未知。") {
                TextField("Tokens", text: $contextTokens).frame(width: 150)
            }
            Divider()
            capability("支持图像输入", selection: $draft.supportsImages)
            Divider()
            capability("支持工具调用", selection: $draft.supportsTools)
            Divider()
            SettingsRow("连接") {
                HStack {
                    Button(isNew ? "取消" : "关闭", action: closeDraft)
                    if !isNew { Button("移除…") { confirmRemoval = true } }
                    Button("保存连接", action: saveConnection)
                }
            }
            Group {
                Divider()
                SettingsRow("API 密钥", detail: "保存在本机钥匙串。本机服务可留空。") {
                    HStack {
                        SecureField(hasKey ? "已保存，可输入新密钥" : "输入密钥", text: $key).frame(width: 150)
                        if !isNew {
                            Button("保存") { withStatus("密钥已保存。") { try AIConfiguration.saveKey(key, for: connection) } }
                                .disabled(key.isEmpty || draft != connection)
                        }
                        if hasKey { Button("删除…") { confirmKeyDeletion = true }.disabled(draft != connection) }
                    }
                }
                if !isNew {
                    Divider()
                    SettingsRow("测试连接", detail: "发送一条简短测试消息，可能计入提供方用量。") {
                        if test != nil { Button("停止") { cancelTest() } }
                        else { Button("发送测试") { startTest() }.disabled(!configuration.state.enabled || draft != connection || discovery != nil) }
                    }
                }
            }
            if !status.isEmpty {
                Divider()
                SettingsRow("状态", detail: status) { EmptyView() }
            }
        }
        .task(id: connection) { if !isNew { hasKey = AIConfiguration.hasKey(for: connection) } }
        .onChange(of: configuration.state) { _, state in
            cancelTest()
            if !state.enabled { cancelDiscovery(); showsModels = false }
        }
        .onChange(of: draft.endpoint) { _, _ in cancelDiscovery(); key = "" }
        .onChange(of: key) { _, _ in cancelDiscovery() }
        .onDisappear { cancelTest(); cancelDiscovery(); key = "" }
        .sheet(isPresented: $showsModels) {
            AIModelDiscoveryList(models: discoveredModels, choose: { draft.model = $0 },
                                 chooseAll: isNew ? nil : {
                let count = configuration.addProviderModels(discoveredModels, from: connection)
                status = "已加入 \(count) 个模型。"
            })
        }
        .confirmationDialog("移除此连接及其钥匙串密钥？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("移除连接", role: .destructive) {
                do { try configuration.remove(connection); closeDraft() }
                catch { status = error.localizedDescription }
            }
        }
        .confirmationDialog("删除此连接的钥匙串密钥？", isPresented: $confirmKeyDeletion, titleVisibility: .visible) {
            Button("删除密钥", role: .destructive) { withStatus("密钥已删除。") { try AIConfiguration.deleteKey(for: connection) } }
        }
    }

    private func saveConnection() {
        let tokens = contextTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tokens.isEmpty && Int(tokens).map({ $0 > 0 }) != true {
            status = "上下文长度须为正整数。"
            return
        }
        var edited = draft
        edited.contextTokens = Int(tokens)
        guard edited.isConfigured else { status = "请填写有效的接口地址和模型 ID。"; return }
        if isNew && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { try AIConfiguration.saveKey(key, for: edited) }
            catch { status = error.localizedDescription; return }
        }
        guard configuration.save(edited, selectAsDefault: false),
              let saved = configuration.state.connections.first(where: { $0.id == edited.id }) else {
            if isNew { try? AIConfiguration.deleteKey(for: edited) }
            status = "请填写有效的接口地址和模型 ID。"
            return
        }
        draft = saved
        key = ""
        status = "连接已保存。"
        if !isNew { closeDraft() }
    }

    private func capability(_ title: String, selection: Binding<Bool?>) -> some View {
        SettingsPicker(title, selection: selection) {
            Text("未知").tag(nil as Bool?)
            Text("是").tag(Optional(true))
            Text("否").tag(Optional(false))
        }
    }

    private func cancelDiscovery() {
        guard let discovery else { return }
        discovery.cancel()
        self.discovery = nil
        status = "同步已停止。"
    }

    private func discoverModels() {
        let target = draft
        let original = isNew ? nil : connection
        let enteredKey = key
        status = "正在同步模型…"
        discovery = Task { @MainActor in
            do {
                let models = try await runtime.listModels(connection: target) {
                    try AIConfiguration.discoveryKey(for: $0, original: original, enteredKey: enteredKey)
                }
                guard !Task.isCancelled else { return }
                discoveredModels = models
                showsModels = !models.isEmpty
                status = models.isEmpty ? "接口未返回可选模型，可手动填写模型 ID。" : "已找到 \(models.count) 个模型。"
            } catch {
                guard !Task.isCancelled else { return }
                status = "同步失败：\(error.localizedDescription)"
            }
            discovery = nil
        }
    }

    private func withStatus(_ success: String, operation: () throws -> Void) {
        cancelTest()
        do { try operation(); key = ""; status = success; hasKey = AIConfiguration.hasKey(for: connection) }
        catch { status = error.localizedDescription }
    }

    private func cancelTest() {
        guard let test else { return }
        test.cancel()
        self.test = nil
        status = "测试已停止。"
    }

    private func startTest() {
        let target = connection
        status = "正在测试连接…"
        test = Task { @MainActor in
            do {
                _ = try await runtime.generate(connection: target, readKey: { try AIConfiguration.key(for: $0) }, messages: [
                    AIMessage(role: .user, content: "Reply with OK.")
                ]) { _ in }
                guard !Task.isCancelled else { return }
                status = "模型已成功响应。"
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
            }
            test = nil
        }
    }
}
