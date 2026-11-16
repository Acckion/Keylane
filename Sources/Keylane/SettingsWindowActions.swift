import SwiftUI
import Combine

extension PermissionFeature {
    func titlebar(_ title: String) -> SettingsTitlebarContribution {
        .init(title: title, help: guidance,
              enabled: Binding(get: { self.enabled }, set: setEnabled),
              updates: $enabled.removeDuplicates().eraseToAnyPublisher(),
              permissionStatus: settingsStatus,
              openPrivacySettings: canOpenPrivacySettings ? openPrivacySettings : nil,
              requestEnable: activate,
              recheckPermission: recheck)
    }
}

/// Hosted in a native trailing titlebar accessory, independent of toolbar item priorities.
struct SettingsWindowActions: View {
    @ObservedObject var state: SettingsWindowState

    static func width(for page: LauncherSettingsPage?, hasExtensionSwitch: Bool) -> CGFloat {
        if page?.trailingToolbar != nil { return hasExtensionSwitch ? 226 : 214 }
        if page?.guideURL != nil { return hasExtensionSwitch ? 100 : 52 }
        if hasExtensionSwitch { return 64 }
        return page?.titlebar == nil ? 0 : 64
    }

    var body: some View {
        let page = state.catalog.page(state.page)
        let hasExtensionSwitch = state.extensionEnabled(for: state.page) != nil
        let contribution = state.titlebar(for: state.page)
        HStack(spacing: 8) {
            if let toolbar = page?.trailingToolbar {
                toolbar().id(state.page)
            }
            if let guideURL = page?.guideURL {
                Link(destination: guideURL) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("使用指南")
                .help("使用指南")
            }
            if let contribution {
                SettingsTitlebarSwitch(contribution: contribution).id(state.page)
            }
        }
        .padding(.trailing, 12)
        .frame(width: Self.width(for: page, hasExtensionSwitch: hasExtensionSwitch), height: 44, alignment: .trailing)
        .preferredColorScheme(state.colorScheme)
    }
}

private struct SettingsTitlebarSwitch: View {
    let contribution: SettingsTitlebarContribution
    @State private var enabled: Bool
    @State private var permission = SettingsPermissionStatus()

    init(contribution: SettingsTitlebarContribution) {
        self.contribution = contribution
        _enabled = State(initialValue: contribution.enabled.wrappedValue)
    }

    var body: some View {
        Toggle(contribution.title, isOn: Binding(get: { enabled }, set: { contribution.enabled.wrappedValue = $0 }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
            .help(contribution.help ?? contribution.title)
            .disabled(permission.requesting)
            .onReceive(contribution.updates) { enabled = $0 }
            .onReceive(contribution.permissionStatus ?? Empty().eraseToAnyPublisher()) { permission = $0 }
    }
}

struct PermissionSettingsContent: View {
    let contribution: SettingsTitlebarContribution
    let content: () -> AnyView
    @State private var enabled: Bool
    @State private var permission = SettingsPermissionStatus()

    init(contribution: SettingsTitlebarContribution, content: @escaping () -> AnyView) {
        self.contribution = contribution
        self.content = content
        _enabled = State(initialValue: contribution.enabled.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsPermissionFeedback(status: permission, openPrivacySettings: contribution.openPrivacySettings)
            content()
                .disabled(!enabled)
                .saturation(enabled ? 1 : 0)
                .opacity(enabled ? 1 : 0.5)
        }
        .onReceive(contribution.updates) { enabled = $0 }
        .onReceive(contribution.permissionStatus ?? Empty().eraseToAnyPublisher()) { permission = $0 }
    }
}

struct SettingsPermissionFeedback: View {
    let status: SettingsPermissionStatus
    let openPrivacySettings: (() -> Void)?

    var body: some View {
        if status.requesting {
            Text("正在检查系统权限…").font(.caption).foregroundStyle(.secondary)
        } else if let message = status.message {
            HStack(alignment: .center, spacing: 12) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                if let openPrivacySettings {
                    Button("打开系统设置", action: openPrivacySettings).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}

struct SettingsPermissionToggle: View {
    let contribution: SettingsTitlebarContribution
    let detail: String?
    @State private var enabled = false
    @State private var permission = SettingsPermissionStatus()

    var body: some View {
        SettingsRow(contribution.title, detail: permission.message ?? detail) {
            if permission.message != nil, let open = contribution.openPrivacySettings {
                Button("打开系统设置", action: open).buttonStyle(.bordered).controlSize(.small)
            }
            Toggle(contribution.title, isOn: Binding(get: { enabled }, set: { contribution.enabled.wrappedValue = $0 }))
                .labelsHidden().toggleStyle(.switch).disabled(permission.requesting)
        }
        .onReceive(contribution.updates) { enabled = $0 }
        .onReceive(contribution.permissionStatus ?? Empty().eraseToAnyPublisher()) { permission = $0 }
    }
}
