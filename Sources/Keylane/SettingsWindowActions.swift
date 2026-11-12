import SwiftUI

/// Hosted in a native trailing titlebar accessory, independent of toolbar item priorities.
struct SettingsWindowActions: View {
    @ObservedObject var state: SettingsWindowState

    static func width(for page: LauncherSettingsPage?) -> CGFloat {
        if page?.trailingToolbar != nil { return 140 }
        return page?.titlebar == nil ? 0 : 64
    }

    var body: some View {
        let page = state.catalog.page(state.page)
        Group {
            if let toolbar = page?.trailingToolbar {
                toolbar()
            } else if let contribution = page?.titlebar {
                SettingsTitlebarSwitch(contribution: contribution).id(state.page)
            }
        }
        .padding(.trailing, 12)
        .frame(width: Self.width(for: page), height: 44, alignment: .trailing)
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
