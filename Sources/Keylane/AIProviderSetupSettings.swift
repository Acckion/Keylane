import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AIProviderSetupSettings: View {
    @ObservedObject var configuration: AIConfiguration
    let runtime: AIRuntime
    @State private var addingKey = false
    @AppStorage("ai.ollama.host") private var ollamaHost = "http://127.0.0.1:11434"
    @State private var syncing: Task<Void, Never>?
    @State private var models: [String] = []
    @State private var syncedEndpoint = ""
    @State private var showingModels = false
    @State private var status = ""

    var body: some View {
        SettingsPageSections {
            AISubscriptionSettings(configuration: configuration)
            SettingsGroup("API Keys") {
                SettingsRow("模型提供商", detail: "选择提供商并输入 Key。请求直接发送到该提供商。") {
                    SettingsIconButton("添加 API Key", symbol: "plus") { addingKey = true }
                }
                let connections = providerConnections
                ForEach(connections) { connection in
                    Divider()
                    SettingsRow(connection.providerLabel, detail: catalogDetail(connection)) {
                        Button("同步模型") { configuration.refreshModelCatalogs(runtime: runtime, connection: connection) }
                    }
                }
            }
            SettingsGroup("本地模型") {
                SettingsRow("Ollama", detail: "连接已运行的 Ollama，选择它提供的模型。") {
                    Link("安装 Ollama", destination: URL(string: "https://ollama.com/download/mac")!)
                }
                Divider()
                SettingsRow("Ollama Host", detail: "本机支持 HTTP，远程地址使用 HTTPS。") {
                    TextField("http://127.0.0.1:11434", text: $ollamaHost).frame(width: 250)
                }
                Divider()
                SettingsRow("模型同步", detail: status.isEmpty ? "同步后选择模型加入目录。" : status) {
                    if syncing != nil { Button("停止", action: cancelSync) }
                    else { Button("同步模型", action: syncOllama) }
                }
            }
        }
        .sheet(isPresented: $addingKey) {
            AIAPIKeyEditor(configuration: configuration, runtime: runtime)
        }
        .sheet(isPresented: $showingModels) {
            AIModelDiscoveryList(models: models) { model in
                let saved = configuration.state.connections.first {
                    $0.providerID == "ollama" && $0.endpoint == syncedEndpoint && $0.model == model
                }
                let connection = saved ?? AIConnection(name: "Ollama · " + model, endpoint: syncedEndpoint,
                                                       model: model, providerID: "ollama")
                status = configuration.save(connection, selectAsDefault: false) ? "已添加 \(model)。" : "无法保存模型。"
            }
        }
        .onChange(of: ollamaHost) { _, _ in cancelSync(); showingModels = false }
        .onDisappear { cancelSync() }
    }

    private var providerConnections: [AIConnection] {
        var seen = Set<String>()
        return configuration.state.connections.filter {
            $0.providerID != nil && !$0.protocolKind.isSubscription && $0.providerID != "ollama"
                && seen.insert($0.catalogIdentity).inserted
        }
    }

    private func catalogDetail(_ connection: AIConnection) -> String {
        let count = configuration.state.connections.filter { $0.catalogIdentity == connection.catalogIdentity && $0.isConfigured }.count
        if let status = configuration.catalogSyncStatus[connection.catalogIdentity] {
            return "\(count) 个模型 · " + status
        }
        if let cache = configuration.state.providerCatalogs?[connection.catalogIdentity] {
            return "\(count) 个模型 · 更新于 \(cache.updatedAt.formatted(date: .omitted, time: .shortened))"
        }
        return "\(count) 个已配置模型 · 自动同步目录；未成功时可手动重试。"
    }

    private func cancelSync() {
        syncing?.cancel()
        syncing = nil
    }

    private func syncOllama() {
        let raw = ollamaHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = raw.contains("://") ? raw : "http://" + raw
        guard let base = URL(string: host), base.query == nil, base.fragment == nil else {
            status = "请输入有效 Host。"; return
        }
        let endpoint = base.path.hasSuffix("/v1") ? base.absoluteString : base.appendingPathComponent("v1").absoluteString
        let target = AIConnection(endpoint: endpoint)
        guard target.modelsURL != nil else { status = "请输入有效的本机地址或远程 HTTPS 地址。"; return }
        status = "正在同步…"
        syncing = Task { @MainActor in
            do {
                let found = try await runtime.listModels(connection: target) { _ in nil }
                guard !Task.isCancelled else { return }
                models = found
                syncedEndpoint = endpoint
                showingModels = !found.isEmpty
                status = found.isEmpty ? "Ollama 未返回模型，请先在 Ollama 中下载。" : "找到 \(found.count) 个模型。"
            } catch {
                guard !Task.isCancelled else { return }
                status = "无法连接 Ollama，请检查安装、运行状态及 Host。"
            }
            syncing = nil
        }
    }
}

private struct AIAPIKeyEditor: View {
    @ObservedObject var configuration: AIConfiguration
    let runtime: AIRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var providerID = AIProviderPreset.all[0].id
    @State private var key = ""
    @State private var showKey = false
    @State private var model = ""
    @State private var status = ""
    @State private var verification: Task<Void, Never>?
    @State private var verifiedKey = ""
    @State private var verifiedModel = ""

    private var provider: AIProviderPreset { AIProviderPreset.all.first { $0.id == providerID }! }
    private var target: AIConnection {
        var result = provider.connection
        if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.model = model.trimmingCharacters(in: .whitespacesAndNewlines) }
        return result
    }
    private var isVerified: Bool { !key.isEmpty && key == verifiedKey && target.model == verifiedModel }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("Provider", selection: $providerID) {
                    ForEach(AIProviderPreset.all) { Text($0.name).tag($0.id) }
                }
                Divider()
                SettingsRow("API Key") {
                    HStack {
                        Group {
                            if showKey { TextField("输入 Key", text: $key) }
                            else { SecureField("输入 Key", text: $key) }
                        }.frame(width: 240)
                        SettingsIconButton(showKey ? "隐藏 Key" : "显示 Key", symbol: showKey ? "eye.slash" : "eye") { showKey.toggle() }
                    }
                }
                Divider()
                SettingsRow("模型", detail: "留空使用 \(provider.model)。可在模型目录中切换。") {
                    TextField("自动选择默认模型", text: $model).frame(width: 240)
                }
                Divider()
                SettingsRow("验证", detail: verificationDetail) {
                    if verification != nil { Button("停止") { stopVerification() } }
                    else { Button("验证 Key", action: verify).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
                Divider()
                SettingsRow("管理") { Link("打开提供方文档", destination: URL(string: provider.documentation)!) }
            }
            if !status.isEmpty { SettingsDescription(status) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存 API Key", action: save).disabled(!isVerified)
            }
        }
        .padding(18)
        .frame(width: 550)
        .onChange(of: providerID) { _, _ in stopVerification(); verifiedKey = ""; key = ""; model = ""; status = "" }
        .onChange(of: key) { _, _ in stopVerification(); verifiedKey = "" }
        .onChange(of: model) { _, _ in stopVerification(); verifiedKey = "" }
        .onDisappear { stopVerification(); key = ""; verifiedKey = "" }
    }

    private var verificationDetail: String {
        if let url = target.keyVerificationURL {
            return "仅验证 Key 身份，不发送模型消息、不产生生成用量。模型权限和额度在使用时另行检查。目标为 \(url.absoluteString)"
        }
        if target.taskKind != .text {
            return "检查提供方连接（ElevenLabs 使用账户接口）；语音识别与模型权限需在听写中实测。目标为 \(target.destinationLabel)"
        }
        return "发送一条简短测试消息，可能计入提供方用量。目标为 \(target.destinationLabel)"
    }

    private func stopVerification() { verification?.cancel(); verification = nil }

    private func verify() {
        let connection = target
        let credential = key
        status = "正在验证…"
        verification = Task { @MainActor in
            do {
                try await runtime.verifyAPIKey(connection: connection, readKey: { _ in credential })
                guard !Task.isCancelled else { return }
                verifiedKey = credential
                verifiedModel = connection.model
                status = connection.taskKind == .text ? "验证成功。" : "提供方连接已验证；真实语音识别与模型权限仍需在听写中实测。"
            } catch {
                guard !Task.isCancelled else { return }
                status = "验证失败：\(error.localizedDescription)"
            }
            verification = nil
        }
    }

    private func save() {
        guard isVerified else { return }
        let connection = target
        do {
            try AIConfiguration.saveKey(key, for: connection)
            guard configuration.save(connection, selectAsDefault: false) else {
                try AIConfiguration.deleteKey(for: connection)
                return
            }
            configuration.refreshModelCatalogs(runtime: runtime, connection: connection)
            dismiss()
        } catch { status = error.localizedDescription }
    }
}
