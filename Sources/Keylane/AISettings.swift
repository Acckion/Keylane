import Combine
import KeylaneCore
import SwiftUI

enum AIModule {
    static let models = SettingsItem(id: "ai-models", page: "ai", title: "模型与提供方",
                                     keywords: "AI 模型 提供方 接口 API 密钥 Keychain 流式 Ollama")

    static func make(model: Model) -> LauncherModule {
        let configuration = model.aiSettings
        let runtime = model.aiRuntime
        return LauncherModule(id: .init(rawValue: "keylane.ai"), origin: .application,
                              title: "AI", symbol: "sparkles", settings: [
            .init(id: "ai", title: "AI", symbol: "sparkles", subtitle: "管理 AI 模型、连接与访问凭据。",
                  order: 8, items: [models],
                  titlebar: .init(title: "启用 AI",
                                  enabled: Binding(get: { configuration.state.enabled }, set: configuration.setEnabled),
                                  updates: configuration.$state.map(\.enabled).removeDuplicates().eraseToAnyPublisher()),
                  content: { AnyView(AISettings(configuration: configuration, runtime: runtime)) })
        ])
    }
}

private struct AISettings: View {
    @ObservedObject var configuration: AIConfiguration
    let runtime: AIRuntime
    @State private var newConnection: AIConnection?

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("当前模型连接", detail: "询问文件使用此连接。", selection: Binding<UUID?>(
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
