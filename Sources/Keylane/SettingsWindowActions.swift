import SwiftUI
import Combine

extension PermissionFeature {
    func titlebar(_ title: String) -> SettingsTitlebarContribution {
        .init(title: title, help: guidance,
              enabled: Binding(get: { self.enabled }, set: setEnabled),
              updates: $enabled.removeDuplicates().eraseToAnyPublisher(),
              permissionStatus: settingsStatus)
    }
}

/// Hosted in a native trailing titlebar accessory, independent of toolbar item priorities.
struct SettingsWindowActions: View {
    @ObservedObject var state: SettingsWindowState
    @State private var showingInfo = false

    var body: some View {
        let contribution = state.catalog.page(state.page)?.titlebar
        HStack(spacing: 10) {
            Button { showingInfo.toggle() } label: {
                Image(systemName: "info.circle").font(.system(size: 16)).frame(width: 18, height: 20)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).help("页面说明")
            .popover(isPresented: $showingInfo) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Keylane 设置").font(.headline)
                    if let info = contribution?.info { info() }
                    else { Text("在侧栏选择模块，或搜索设置项后跳转。") }
                }.foregroundStyle(.primary).padding(20).frame(width: 280)
            }
            if let contribution {
                SettingsTitlebarSwitch(contribution: contribution).id(state.page)
            }
        }.padding(.trailing, 12).frame(width: 106, height: 44, alignment: .trailing)
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
            if permission.requesting {
                ProgressView("正在检查系统权限…").controlSize(.small)
            } else if let message = permission.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            content()
                .disabled(!enabled)
                .saturation(enabled ? 1 : 0)
                .opacity(enabled ? 1 : 0.5)
        }
        .onReceive(contribution.updates) { enabled = $0 }
        .onReceive(contribution.permissionStatus ?? Empty().eraseToAnyPublisher()) { permission = $0 }
    }
}

struct SettingsPermissionToggle: View {
    let contribution: SettingsTitlebarContribution
    let detail: String
    @State private var enabled = false
    @State private var permission = SettingsPermissionStatus()

    var body: some View {
        SettingsRow(contribution.title, detail: permission.message ?? detail) {
            Toggle(contribution.title, isOn: Binding(get: { enabled }, set: { contribution.enabled.wrappedValue = $0 }))
                .labelsHidden().toggleStyle(.switch).disabled(permission.requesting)
        }
        .onReceive(contribution.updates) { enabled = $0 }
        .onReceive(contribution.permissionStatus ?? Empty().eraseToAnyPublisher()) { permission = $0 }
    }
}
