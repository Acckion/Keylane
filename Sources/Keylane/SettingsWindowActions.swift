import SwiftUI

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

    init(contribution: SettingsTitlebarContribution) {
        self.contribution = contribution
        _enabled = State(initialValue: contribution.enabled.wrappedValue)
    }

    var body: some View {
        Toggle(contribution.title, isOn: Binding(get: { enabled }, set: { contribution.enabled.wrappedValue = $0 }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
            .help(contribution.help ?? contribution.title)
            .onReceive(contribution.updates) { enabled = $0 }
    }
}
