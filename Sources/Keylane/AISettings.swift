import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum AIModule {
    static let models = SettingsItem(id: "ai-models", page: "ai", title: "模型与提供方",
                                     keywords: "AI 模型 提供方 接口 API 密钥 Keychain 流式 Ollama")

    static let textCommandsItem = SettingsItem(id: "ai-text-commands", page: "ai", title: "AI 命令",
                                               keywords: "翻译 润色 摘要 快捷键 translate polish summarize")

    static func make(model: Model) -> LauncherModule {
        let configuration = model.aiSettings
        let runtime = model.aiRuntime
        let historyURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/AI/history.sqlite")
        let quickAI = QuickAIController(configuration: configuration, runtime: runtime,
                                        history: AIChatHistory(url: historyURL))
        let chat = AIChatWindow(controller: quickAI, configuration: configuration,
                                appearance: model.$appearance.eraseToAnyPublisher())
        let openChat: () -> Void = { [weak model] in
            guard let model, configuration.isAvailable else { return }
            let fromQuickAI = model.pageID == QuickAILauncher.pageID
            chat.show(draft: fromQuickAI ? model.query : "", restoreLatest: !fromQuickAI,
                      activation: model.windowActivationBehavior) {
                (NSApp.delegate as? Delegate)?.hideLauncher()
                if fromQuickAI { model.pageID = .root }
            }
        }
        let quickCommand = LauncherModule.Command(declaration: .init(
            id: QuickAILauncher.commandID, title: "Quick AI", detail: "向已配置的模型提问", symbol: "sparkles",
            keywords: ["ask", "AI", "快速问答", "询问 AI"], destination: .action, settingsPage: "ai"
        ), available: { configuration.isAvailable }, execute: { [weak model] origin in
            if quickAI.isInChat { openChat() }
            else { model?.openPage(QuickAILauncher.pageID, origin: origin) }
        })
        let chatCommand = LauncherModule.Command(declaration: .init(
            id: .init(rawValue: "ai-chat"), title: "AI Chat", detail: "打开独立聊天窗口", symbol: "bubble.left.and.bubble.right",
            keywords: ["chat", "AI", "聊天", "对话"], destination: .action, settingsPage: "ai"
        ), available: { configuration.isAvailable }, execute: { _ in openChat() })
        let textSession = AITextCommandSession(configuration: configuration, runtime: runtime)
        let textCommands = AITextCommandLauncher.commands(model: model, session: textSession)
        return LauncherModule(id: .init(rawValue: "keylane.ai"), origin: .application,
                              title: "AI", symbol: "sparkles", commands: [quickCommand, chatCommand] + textCommands,
                              pages: [QuickAILauncher.page(model: model, controller: quickAI, openChat: openChat),
                                      AITextCommandLauncher.page(model: model, session: textSession)], settings: [
            .init(id: "ai", title: "AI", symbol: "sparkles", subtitle: "管理 AI 模型、连接与访问凭据。",
                  order: 8, items: [models, textCommandsItem],
                  titlebar: .init(title: "启用 AI",
                                  enabled: Binding(get: { configuration.state.enabled }, set: configuration.setEnabled),
                                  updates: configuration.$state.map(\.enabled).removeDuplicates().eraseToAnyPublisher()),
                  content: { [weak model] in
                      guard let model else { return AnyView(EmptyView()) }
                      return AnyView(AISettings(configuration: configuration, runtime: runtime,
                                                model: model, textCommands: textCommands))
                  })
        ], searchUpdates: [configuration.$state.map(\.isAvailable).removeDuplicates().map { _ in () }.eraseToAnyPublisher()])
    }
}

private struct AISettings: View {
    @ObservedObject var configuration: AIConfiguration
    let runtime: AIRuntime
    let model: Model
    let textCommands: [LauncherModule.Command]
    @State private var newConnection: AIConnection?

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("当前模型连接", detail: "Quick AI、AI Chat、询问文件和 AI 命令使用此连接。", selection: Binding<UUID?>(
                    get: { configuration.state.selectedID },
                    set: { if let id = $0 { configuration.select(id); newConnection = nil } }
                )) {
                    if configuration.state.connections.isEmpty { Text("尚未配置").tag(nil as UUID?) }
                    ForEach(configuration.state.connections) { connection in
                        Text(connection.name.isEmpty ? connection.model : connection.name).tag(Optional(connection.id))
                    }
                }
                Divider()
                SettingsRow("模型与提供方", detail: "支持 OpenAI 兼容接口，可以添加多个连接。") {
                    Button("添加连接", systemImage: "plus") { newConnection = AIConnection() }
                }
            }.settingsAnchor(AIModule.models)

            if let connection = newConnection ?? configuration.selected {
                AIConnectionEditor(configuration: configuration, runtime: runtime, connection: connection,
                                   isNew: newConnection != nil) { newConnection = nil }
                    .id(connection.id)
            }
            ExtensionCommandPreferences(model: model, commands: textCommands)
                .settingsAnchor(AIModule.textCommandsItem)
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
                TextField("提供方的模型标识", text: $draft.model).frame(width: 245)
            }
            Divider()
            SettingsPicker("响应方式", detail: "流式逐段显示回复，完整响应兼容旧接口。", selection: $draft.mode) {
                Text("流式").tag(AIResponseMode.streaming)
                Text("完整响应").tag(AIResponseMode.complete)
            }
            Divider()
            SettingsRow("连接") {
                HStack {
                    if isNew { Button("取消", action: closeDraft) }
                    else { Button("移除…") { confirmRemoval = true } }
                    Button("保存连接", action: saveConnection)
                }
            }
            if !isNew {
                Divider()
                SettingsRow("API 密钥", detail: "保存在本机钥匙串。本机服务可留空。") {
                    HStack {
                        SecureField(hasKey ? "已保存，可输入新密钥" : "输入密钥", text: $key).frame(width: 150)
                        Button("保存") { withStatus("密钥已保存。") { try AIConfiguration.saveKey(key, for: connection) } }
                            .disabled(key.isEmpty || draft != connection)
                        if hasKey { Button("删除…") { confirmKeyDeletion = true }.disabled(draft != connection) }
                    }
                }
                Divider()
                SettingsRow("测试连接", detail: "发送一条简短测试消息，可能计入提供方用量。") {
                    if test != nil { Button("停止") { cancelTest() } }
                    else { Button("发送测试") { startTest() }.disabled(!configuration.isAvailable || draft != connection) }
                }
            }
            if !status.isEmpty {
                Divider()
                SettingsRow("状态", detail: status) { EmptyView() }
            }
        }
        .task(id: connection) { if !isNew { hasKey = AIConfiguration.hasKey(for: connection) } }
        .onChange(of: configuration.state) { _, _ in cancelTest() }
        .onDisappear { cancelTest(); key = "" }
        .confirmationDialog("移除此连接及其钥匙串密钥？", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("移除连接", role: .destructive) { withStatus("连接已移除。") { try configuration.remove(connection) } }
        }
        .confirmationDialog("删除此连接的钥匙串密钥？", isPresented: $confirmKeyDeletion, titleVisibility: .visible) {
            Button("删除密钥", role: .destructive) { withStatus("密钥已删除。") { try AIConfiguration.deleteKey(for: connection) } }
        }
    }

    private func saveConnection() {
        guard configuration.save(draft), let saved = configuration.selected else {
            status = "请填写有效的接口地址和模型 ID。"
            return
        }
        draft = saved
        key = ""
        status = "连接已保存。"
        closeDraft()
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
