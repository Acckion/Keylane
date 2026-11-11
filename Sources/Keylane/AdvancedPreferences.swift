import AppKit
import SwiftUI
import KeylaneCore

enum WindowActivationBehavior: String {
    case systemDefault, activeSpace

    func apply(to window: NSWindow) {
        if self == .activeSpace {
            window.collectionBehavior.insert(.moveToActiveSpace)
        } else {
            window.collectionBehavior.remove(.moveToActiveSpace)
        }
    }
}

struct AdvancedPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$windowActivationBehavior)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("窗口激活行为",
                               detail: "再次打开设置或文件操作窗口时，可将窗口移到当前空间，或使用 macOS 的默认行为。",
                               selection: Binding(get: { model.windowActivationBehavior },
                                                  set: { model.windowActivationBehavior = $0 })) {
                    Text("系统默认").tag(WindowActivationBehavior.systemDefault)
                    Text("移到当前空间").tag(WindowActivationBehavior.activeSpace)
                }.settingsAnchor(.windowActivation)
                Divider()
                // TODO: Connect this picker when commands can fetch website icons.
                SettingsPicker("网站图标提供方", detail: "选择获取网站图标的服务，也可以关闭获取。",
                               selection: .constant("pending")) {
                    Text("待实现").tag("pending")
                }.disabled(true).settingsAnchor(.faviconProvider)
            }

            SettingsSectionTitle(title: "导出")
            SettingsGroup {
                // TODO: Add encrypted exports before accepting a passphrase.
                SettingsRow("导出口令", detail: "使用口令加密导出的设置和资料。") {
                    SecureField("待实现", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 142)
                        .accessibilityLabel("导出口令，待实现")
                }.disabled(true).settingsAnchor(.exportPassphrase)
                Divider()
                // TODO: Add scheduling once the full backup format is available.
                SettingsActionRow(title: "定时导出", detail: "按计划自动备份设置和资料。",
                                  actionTitle: "待实现") {}
                    .disabled(true).settingsAnchor(.scheduledExport)
                Divider()
                SettingsActionRow(title: "导出设置", detail: "将启动器、外观和键盘偏好保存为 JSON。",
                                  actionTitle: "导出…") {
                    model.runCommand(.init(rawValue: "export-settings"), origin: .menu)
                }.settingsAnchor(.exportPreferences)
                Divider()
                SettingsActionRow(title: "导出本地资料", detail: "将现有便笺、链接和片段记录导出为 JSON。",
                                  actionTitle: "导出…", action: model.exportData)
                    .settingsAnchor(.exportLocalRecords)
            }

            SettingsSectionTitle(title: "连接")
            SettingsGroup {
                // TODO: Apply the user's proxy selection through a shared network configuration.
                SettingsRow("使用系统代理设置", detail: "让 Keylane 的网络连接遵循 macOS 的代理配置。") {
                    HStack(spacing: 8) {
                        SettingsDescription("待实现")
                        Toggle("使用系统代理设置", isOn: .constant(false))
                            .labelsHidden().toggleStyle(SettingsSwitchStyle())
                    }
                }.disabled(true).settingsAnchor(.systemProxy)
                Divider()
                // TODO: Validate and scope additional trust anchors to Keylane connections.
                SettingsRow("额外的证书颁发机构", detail: "为 Keylane 的网络连接添加受信任的 .crt、.cer 或 .pem 证书。") {
                    HStack(spacing: 8) {
                        SettingsDescription("待实现")
                        Button("添加文件…", systemImage: "plus") {}
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }.disabled(true).settingsAnchor(.additionalCertificateAuthority)
            }

            SettingsSectionTitle(title: "资料与隐私")
            SettingsGroup {
                SettingsActionRow(title: "资料目录", detail: "Application Support/Keylane",
                                  actionTitle: "在 Finder 中显示") {
                    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    NSWorkspace.shared.open(directory.appendingPathComponent("Keylane"))
                }.settingsAnchor(.dataDirectory)
                Divider()
                SettingsRowLabel(title: "无遥测", detail: "文件 AI 仅在你主动发送时连接所配置的服务。云同步与扩展模块尚未接入。")
                    .settingsAnchor(.privacy)
            }
        }
    }
}
