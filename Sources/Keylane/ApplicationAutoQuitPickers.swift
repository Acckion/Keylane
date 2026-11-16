import SwiftUI
import KeylaneCore

/// Keep the toolbar item's state independent of edits inside its popover.
/// Updating toolbar-owned search state rebuilds the AppKit toolbar item and dismisses its popover.
struct ApplicationAutoQuitAddButton: View {
    let model: Model
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("添加自动退出应用", systemImage: "plus").labelStyle(.iconOnly)
        }
        .help("添加自动退出应用")
        .disabled(!model.applicationsEnabled)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ApplicationAutoQuitPicker(model: model, dismiss: { open = false })
        }
    }
}

private struct ApplicationAutoQuitPicker: View {
    let model: Model
    let dismiss: () -> Void
    @ObservedObject private var catalog: ApplicationSettingsCatalog
    @ObservedObject private var autoQuit: ApplicationAutoQuit
    @State private var query = ""
    @State private var options: [ResultFilterOption] = []
    @State private var error: String?

    init(model: Model, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
        catalog = model.applicationSettingsCatalog
        autoQuit = model.applicationAutoQuit
    }

    var body: some View {
        VStack(spacing: 0) {
            ResultFilterPanel(selection: "", options: ResultFilterPanel.matches(options, query: query.trimmingCharacters(in: .whitespacesAndNewlines)),
                              query: $query, searchPlaceholder: "搜索应用…",
                              emptyTitle: options.isEmpty ? "没有可添加的应用" : "没有匹配的应用",
                              navigation: model.navigation, width: 360, maximumVisibleRows: 6,
                              choose: add, dismiss: dismiss)
            if let error {
                Divider()
                Text(error).font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .onAppear(perform: refreshOptions)
        .onChange(of: catalog.items) { _, _ in refreshOptions() }
        .onChange(of: autoQuit.rules.keys.sorted()) { _, _ in refreshOptions() }
    }

    private func refreshOptions() {
        let available = catalog.items.filter { autoQuit.minutes(for: $0.url) == 0 && autoQuit.canConfigure($0.url) }
        let names = Dictionary(grouping: available, by: \.title)
        options = available.map { item in
            let path = (item.id as NSString).abbreviatingWithTildeInPath
            return ResultFilterOption(id: item.id, title: item.title, symbol: "app", iconPath: item.id,
                                      subtitle: names[item.title, default: []].count > 1 ? path : nil)
        }
    }

    private func add(_ option: ResultFilterOption) {
        let url = URL(fileURLWithPath: option.id)
        guard catalog.items.contains(where: { $0.id == option.id }), autoQuit.canConfigure(url) else {
            error = "应用已移动或不可用。"
            refreshOptions()
            return
        }
        if autoQuit.minutes(for: url) == 0 {
            autoQuit.setMinutes(ApplicationAutoQuit.useDefault, for: url)
        }
        dismiss()
    }
}

struct AutoQuitDurationPicker: View {
    let label: String
    let minutes: Int
    let defaultMinutes: Int?
    let navigation: String
    let select: (Int) -> Void
    @State private var open = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                if minutes != ApplicationAutoQuit.useDefault {
                    Text(title(for: minutes))
                }
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(label)
        .accessibilityValue(title(for: minutes))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AutoQuitDurationOptions(minutes: minutes, defaultMinutes: defaultMinutes, navigation: navigation, title: title) { value in
                open = false
                select(value)
            } dismiss: { open = false }
        }
    }

    private func title(for duration: Int) -> String {
        if duration == ApplicationAutoQuit.useDefault, let defaultMinutes {
            return "使用默认时长（\(defaultMinutes) 分钟）"
        }
        return "\(duration) 分钟"
    }
}

private struct AutoQuitDurationOptions: View {
    let minutes: Int
    let defaultMinutes: Int?
    let navigation: String
    let title: (Int) -> String
    let select: (Int) -> Void
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        let values = (defaultMinutes == nil ? [] : [ApplicationAutoQuit.useDefault]) + ApplicationAutoQuit.intervals
        let options = values.map { ResultFilterOption(id: String($0), title: title($0), symbol: "") }
        ResultFilterPanel(selection: String(minutes), options: ResultFilterPanel.matches(options, query: query),
                          query: $query, searchPlaceholder: "搜索时长…", emptyTitle: "没有匹配时长",
                          navigation: navigation, maximumVisibleRows: 5, choose: { option in
            if let value = Int(option.id) { select(value) }
        }, dismiss: dismiss)
    }
}
