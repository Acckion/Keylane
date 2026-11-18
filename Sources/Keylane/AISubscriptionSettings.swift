import AppKit
import SwiftUI

struct AISubscriptionSettings: View {
    @ObservedObject var configuration: AIConfiguration
    @State private var editing: AIConnection?
    @State private var usageTarget: AIConnection?
    @State private var status: [AIWireProtocol: String] = [:]
    @State private var checks: [AIWireProtocol: Task<Void, Never>] = [:]

    var body: some View {
        SettingsGroup("本地 AI 订阅") {
            ForEach([AIWireProtocol.codex, .claudeCode], id: \.self) { kind in
                if kind == .claudeCode { Divider() }
                let connection = configured(kind)
                SettingsRow(kind == .codex ? "ChatGPT Account" : "Claude Account",
                            detail: status[kind] ?? "通过官方 CLI 登录订阅后启用。") {
                    HStack {
                        Link("连接方法", destination: URL(string: kind == .codex
                            ? "https://developers.openai.com/codex/auth/" : "https://code.claude.com/docs/en/authentication")!)
                        Button("Advanced") { editing = connection }
                        Button("Show Usage") { usageTarget = connection }
                            .disabled(connection.subscriptionEnabled != true)
                        Toggle("启用订阅", isOn: Binding(get: { connection.subscriptionEnabled == true }, set: { enabled in
                            configuration.setSubscriptionEnabled(connection, enabled: enabled)
                            var changed = connection
                            changed.subscriptionEnabled = enabled
                            if enabled { check(changed) } else { checks[kind]?.cancel(); status[kind] = "已停用。" }
                        })).labelsHidden().toggleStyle(SettingsSwitchStyle())
                    }
                }
                if connection.subscriptionEnabled == true {
                    SettingsRow("账户状态") {
                        if checks[kind] != nil { ProgressView().controlSize(.small) }
                        else { Button("检查账户") { check(connection) } }
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            AISubscriptionAdvanced(connection: draft, configuration: configuration)
        }
        .sheet(item: $usageTarget) { connection in AISubscriptionUsage(connection: connection) }
        .onDisappear { for check in checks.values { check.cancel() }; checks = [:] }
    }

    private func configured(_ kind: AIWireProtocol) -> AIConnection {
        configuration.state.connections.first { $0.protocolKind == kind } ??
            AIConnection(name: kind == .codex ? "ChatGPT Account" : "Claude Account",
                         model: kind == .codex ? "default" : "sonnet", wireProtocol: kind)
    }

    private func check(_ connection: AIConnection) {
        let kind = connection.protocolKind
        checks[kind]?.cancel()
        checks[kind] = Task { @MainActor in
            do {
                let account = try await AISubscriptionTransport.status(connection)
                let models = try await AISubscriptionTransport.models(connection)
                guard !Task.isCancelled else { return }
                var configured = connection
                configured.subscriptionAccountID = account.accountID
                if kind == .codex && configured.model == "default" {
                    guard let model = models.first else { throw AISubscriptionError.failed }
                    configured.model = model
                }
                _ = configuration.save(configured, selectAsDefault: false)
                _ = configuration.addProviderModels(models, from: configured)
                guard !Task.isCancelled else { return }
                status[kind] = account.account
            } catch {
                guard !Task.isCancelled else { return }
                status[kind] = error.localizedDescription
            }
            checks[kind] = nil
        }
    }
}

struct AISubscriptionAdvanced: View {
    @State var connection: AIConnection
    @ObservedObject var configuration: AIConfiguration
    @Environment(\.dismiss) private var dismiss
    @State private var status = ""
    @State private var syncing: Task<Void, Never>?
    @State private var models: [String] = []
    @State private var showingModels = false

    var body: some View {
        SettingsPageSections {
            SettingsGroup("Installation and Account") {
                SettingsRow("CLI Installation", detail: "留空使用自动发现的官方 CLI。") {
                    HStack {
                        TextField("可执行文件的完整路径", text: Binding(
                            get: { connection.executablePath ?? "" }, set: { connection.executablePath = $0 }))
                        SettingsIconButton("选择 CLI", symbol: "folder") { choose(folder: false) }
                    }.frame(width: 290)
                }
                Divider()
                SettingsRow("Account Folder", detail: "留空使用该 CLI 默认账户。修改只用于本机 Keylane。") {
                    HStack {
                        TextField("账户配置目录", text: Binding(
                            get: { connection.accountFolder ?? "" }, set: { connection.accountFolder = $0 }))
                        SettingsIconButton("选择账户目录", symbol: "folder") { choose(folder: true) }
                    }.frame(width: 290)
                }
                Divider()
                SettingsRow("模型") {
                    HStack {
                        TextField("模型 ID", text: $connection.model)
                        Button("同步模型", action: sync).disabled(syncing != nil)
                    }.frame(width: 290)
                }
            }
            if !status.isEmpty { SettingsDescription(status) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    var saved = connection
            if saved.protocolKind == .codex && saved.model == "default" {
                        status = "请先同步并选择账户支持的模型。"
                        return
                    }
                    saved.executablePath = saved.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.accountFolder = saved.accountFolder?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if configuration.save(saved, selectAsDefault: false) { dismiss() }
                    else { status = "请输入有效模型并启用订阅。" }
                }
            }
        }
        .padding(18).frame(width: 620)
        .sheet(isPresented: $showingModels) { AIModelDiscoveryList(models: models) { connection.model = $0 } }
        .onChange(of: connection.executablePath) { _, _ in syncing?.cancel(); syncing = nil }
        .onChange(of: connection.accountFolder) { _, _ in syncing?.cancel(); syncing = nil }
        .onDisappear { syncing?.cancel() }
    }

    private func choose(folder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let path = panel.url?.path {
            if folder { connection.accountFolder = path } else { connection.executablePath = path }
        }
    }

    private func sync() {
        let snapshot = connection
        syncing = Task { @MainActor in
            do {
                let found = try await AISubscriptionTransport.models(snapshot)
                guard !Task.isCancelled else { return }
                models = found
                showingModels = !found.isEmpty
                status = found.isEmpty ? "未返回模型，请检查 CLI 登录状态。" : ""
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
            }
            syncing = nil
        }
    }
}

private struct AISubscriptionUsage: View {
    let connection: AIConnection
    @Environment(\.dismiss) private var dismiss
    @State private var usage: AISubscriptionStatus?
    @State private var status = ""
    @State private var task: Task<Void, Never>?
    @State private var confirmReset = false
    @State private var resetKey = UUID().uuidString

    var body: some View {
        SettingsPageSections {
            SettingsTitle("AI Usage", role: .section)
            if let usage {
                ForEach(usage.windows) { window in
                    SettingsRow(window.id, detail: window.resetsAt.map { "重置时间 " + $0.formatted() }) {
                        Text("\(Int(window.usedPercent))% used")
                    }
                    ProgressView(value: window.usedPercent, total: 100)
                }
                if let resets = usage.availableResets {
                    SettingsRow("可用额度重置", detail: "\(resets) available") {
                        Button("Use reset") { confirmReset = true }.disabled(resets == 0 || task != nil)
                    }
                }
                SettingsDescription("更新于 " + usage.updated.formatted())
            }
            if !status.isEmpty { SettingsDescription(status) }
            HStack {
                Button("刷新", action: refresh).disabled(task != nil)
                if task != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 480).frame(minHeight: 240)
        .task { refresh() }
        .onDisappear { task?.cancel() }
        .confirmationDialog("使用一个账户额度重置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("使用重置") {
                task = Task { @MainActor in
                    do {
                        try await AISubscriptionTransport.reset(connection, idempotencyKey: resetKey)
                        resetKey = UUID().uuidString
                        let updated = try await AISubscriptionTransport.status(connection, usage: true)
                        guard !Task.isCancelled else { return }
                        usage = updated
                    } catch {
                        guard !Task.isCancelled else { return }
                        status = error.localizedDescription
                    }
                    task = nil
                }
            }
        }
    }

    private func refresh() {
        if connection.protocolKind == .claudeCode {
            status = "Claude CLI 当前未提供账户总额度查询接口。可在 Claude 账户页面查看用量。"
            return
        }
        task = Task { @MainActor in
            do {
                let updated = try await AISubscriptionTransport.status(connection, usage: true)
                guard !Task.isCancelled else { return }
                usage = updated
                status = updated.windows.isEmpty ? "账户未返回额度窗口。" : ""
            } catch {
                guard !Task.isCancelled else { return }
                status = error.localizedDescription
            }
            task = nil
        }
    }
}
