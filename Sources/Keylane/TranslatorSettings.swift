import ApplicationServices
import KeylaneCore
import SwiftUI

struct TranslatorSettings: View {
    let model: Model
    @ObservedObject var controller: TranslatorController
    @ObservedObject private var ai: AIConfiguration
    @State private var sourceOpen = false
    @State private var targetOpen = false
    @State private var credentials = TranslationCredentials()
    @State private var credentialMessage = ""
    @State private var editing: TranslateCommand?

    init(model: Model, controller: TranslatorController) {
        self.model = model
        self.controller = controller
        ai = model.aiSettings
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("翻译提供商", selection: $controller.preferences.provider) {
                    ForEach(TranslationProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
                if controller.preferences.provider == .ai {
                    SettingsPicker("翻译模型", selection: $controller.preferences.modelID) {
                        Text("跟随 AI 命令默认模型").tag(nil as UUID?)
                        ForEach(ai.state.connections.filter(\.isConfigured)) { item in
                            Text(item.displayName).tag(Optional(item.id))
                        }
                    }
                    if !ai.state.enabled || controller.selectedConnection == nil {
                        SettingsActionRow(title: "配置 AI", detail: "在模型与提供方中添加模型并启用 AI。", actionTitle: "打开 AI 设置") {
                            model.openSettings(page: "ai-models")
                        }
                    }
                } else {
                    credentialFields
                }
            }.settingsAnchor(TranslatorModule.optionsItem)
            SettingsGroup {
                SettingsPicker("主要操作", selection: $controller.preferences.pastePrimary) {
                    Text("复制译文").tag(false)
                    Text("粘贴到前一个应用").tag(true)
                }
                Divider()
                Toggle(isOn: $controller.preferences.useSelection) {
                    SettingsRowLabel(title: "使用选中文字作为原文", detail: "打开翻译时读取前一个应用中选中的文字，需要辅助功能权限。")
                }.toggleStyle(SettingsSwitchStyle())
                Divider()
                SettingsRow("默认源语言") {
                    TranslatorLanguagePicker(value: controller.preferences.source,
                                             title: TranslationLanguage.language(controller.preferences.source)?.title ?? "自动检测",
                                             allowsDetection: true, navigation: model.navigation, open: $sourceOpen) {
                        controller.preferences.source = $0
                    }
                }
                Divider()
                SettingsRow("默认目标语言") {
                    TranslatorLanguagePicker(value: controller.preferences.target,
                                             title: TranslationLanguage.language(controller.preferences.target)?.title ?? "简体中文",
                                             navigation: model.navigation, open: $targetOpen) {
                        controller.preferences.target = $0
                    }
                }
            }
            SettingsSectionTitle(title: "命令").settingsAnchor(TranslatorModule.commandsItem)
            CommandSettingsList(items: [TranslatorModule.commandID], id: \.rawValue) { id in
                CommandSettingsEntry(title: "翻译", model: model, commandID: id,
                                     perform: { model.runCommand(id, origin: .menu) }, icon: { SettingsIcon(symbol: "translate") })
            }
            SettingsSectionTitle(title: "自定义命令")
            SettingsGroup {
                SettingsActionRow(title: "创建翻译命令", actionTitle: "创建命令") { editing = TranslateCommand() }
            }
            if !controller.preferences.commands.isEmpty {
                CommandSettingsList(items: controller.preferences.commands, id: \.id) { item in
                    customEntry(item)
                }
            }
        }
        .onAppear(perform: loadCredentials)
        .onChange(of: controller.preferences.useSelection) { _, enabled in
            if enabled { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
        }
        .onChange(of: controller.preferences.provider) { _, _ in loadCredentials() }
        .onChange(of: credentials) { _, _ in
            if credentialMessage == "已保存到钥匙串" { credentialMessage = "" }
        }
        .sheet(item: $editing) { command in
            TranslatorCommandEditor(command: command, navigation: model.navigation, cancel: { editing = nil }) { updated in
                if let index = controller.preferences.commands.firstIndex(where: { $0.id == updated.id }) {
                    controller.preferences.commands[index] = updated
                } else { controller.preferences.commands.append(updated) }
                editing = nil
            }
        }
    }

    @ViewBuilder private var credentialFields: some View {
        if controller.preferences.provider == .youdao || controller.preferences.provider == .baidu {
            SettingsRow("应用 ID") { TextField("App ID", text: $credentials.appID).textFieldStyle(.roundedBorder).frame(width: 220) }
            Divider()
        }
        SettingsRow("API 密钥", detail: "密钥存储在 macOS 钥匙串。原文会发送给所选提供商处理。") {
            SecureField("API Key / Secret", text: $credentials.key).textFieldStyle(.roundedBorder).frame(width: 220)
        }
        if controller.preferences.provider == .microsoft {
            Divider()
            SettingsRow("资源区域", detail: "与 Azure Translator 资源的区域一致；全局资源可以留空。") {
                TextField("例如 eastasia", text: $credentials.region).textFieldStyle(.roundedBorder).frame(width: 160)
            }
        }
        Divider()
        SettingsRow(credentialMessage.isEmpty ? "保存提供商配置" : credentialMessage) {
            Button("保存") {
                do {
                    try TranslatorKeychain.save(credentials, for: controller.preferences.provider)
                    credentialMessage = "已保存到钥匙串"
                    controller.retry()
                } catch { credentialMessage = "无法保存配置，请检查钥匙串权限。" }
            }.buttonStyle(ContentActionButtonStyle())
        }
    }

    private func loadCredentials() {
        credentials = .init()
        credentialMessage = ""
        guard controller.preferences.provider != .ai else { return }
        do { credentials = try TranslatorKeychain.load(controller.preferences.provider) }
        catch { credentialMessage = "无法读取钥匙串，请重新输入密钥。" }
    }

    private func customEntry(_ item: TranslateCommand) -> CommandSettingsEntry<SettingsIcon> {
        var entry = CommandSettingsEntry(title: item.name, model: model, commandID: .init(rawValue: item.commandID),
                                         perform: { model.runCommand(.init(rawValue: item.commandID), origin: .menu) },
                                         icon: { SettingsIcon(symbol: "translate") })
        entry.menu = [
            .init(title: "编辑") { editing = item },
            .init(title: "复制为新命令") {
                var copy = item
                copy.id = UUID()
                copy.name += " 副本"
                editing = copy
            },
            .init(title: "删除") {
                controller.preferences.commands.removeAll { $0.id == item.id }
            }
        ]
        return entry
    }
}

private struct TranslatorCommandEditor: View {
    @State var command: TranslateCommand
    let navigation: String
    let cancel: () -> Void
    let save: (TranslateCommand) -> Void
    @State private var sourceOpen = false
    @State private var targetOpen = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("翻译命令", systemImage: "translate").font(.title2)
            SettingsGroup {
                SettingsRow("源语言") {
                    TranslatorLanguagePicker(value: command.source, title: TranslationLanguage.language(command.source)?.title ?? "自动检测",
                                             allowsDetection: true, navigation: navigation, open: $sourceOpen) { command.source = $0 }
                }
                Divider()
                SettingsRow("目标语言") {
                    TranslatorLanguagePicker(value: command.target, title: TranslationLanguage.language(command.target)?.title ?? "英语",
                                             navigation: navigation, open: $targetOpen) { command.target = $0 }
                }
                Divider()
                SettingsPicker("输出行为", selection: $command.replaceSelection) {
                    Text("在 Keylane 中打开").tag(false)
                    Text("替换选中文字").tag(true)
                }
            }
            SettingsGroup {
                SettingsRow("命令名称") { TextField("例如 翻译成英语", text: $command.name).textFieldStyle(.roundedBorder).frame(width: 270) }
            }
            HStack {
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("保存命令") {
                    var item = command
                    item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(item)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(command.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 540)
    }
}
