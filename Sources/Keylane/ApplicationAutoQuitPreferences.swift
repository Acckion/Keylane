import SwiftUI
import KeylaneCore

struct ApplicationAutoQuitPreferences: View {
    static let summary = "停止使用应用一段时间后自动退出。"

    let model: Model
    @ObservedObject private var autoQuit: ApplicationAutoQuit
    @ObservedObject private var catalog: ApplicationSettingsCatalog

    init(model: Model) {
        self.model = model
        autoQuit = model.applicationAutoQuit
        catalog = model.applicationSettingsCatalog
    }

    var body: some View {
        let names = Dictionary(uniqueKeysWithValues: catalog.items.map { ($0.id, $0.title) })
        let rules = autoQuit.rules.keys.map { path in
            let url = URL(fileURLWithPath: path)
            return ApplicationPreferenceItem(id: path, url: url, title: names[path] ?? model.appName(url), filename: url.lastPathComponent)
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        let duplicateNames = Dictionary(grouping: rules, by: \.title)
        SettingsPageSections {
            SettingsGroup {
                SettingsRow("默认自动退出时长") {
                    AutoQuitDurationPicker(label: "默认自动退出时长", minutes: autoQuit.defaultMinutes,
                                           defaultMinutes: nil, navigation: model.navigation, select: autoQuit.setDefaultMinutes)
                }
            }.settingsAnchor(.applicationAutoQuit)

            if rules.isEmpty {
                SettingsGroup {
                    SettingsRow("尚未添加应用", detail: "点右上角的加号，选择要自动退出的应用。") { EmptyView() }
                }
            } else {
                SettingsGroup {
                    ForEach(rules) { item in
                        if item.id != rules.first?.id { Divider().opacity(0.4) }
                        let minutes = autoQuit.minutes(for: item.url)
                        let duplicateName = duplicateNames[item.title, default: []].count > 1
                        let detail = minutes == 0 ? "原应用已移动、删除或替换。" : (duplicateName ? item.id : nil)
                        SettingsRow {
                            HStack(spacing: 9) {
                                WorkspaceItemIcon(path: item.id).frame(width: 18, height: 18).accessibilityHidden(true)
                                SettingsRowLabel(title: item.title, detail: detail)
                            }.help(item.id)
                        } control: {
                            HStack(spacing: 12) {
                                if minutes != 0 {
                                    AutoQuitDurationPicker(label: "\(item.title)的自动退出时长", minutes: minutes,
                                                           defaultMinutes: autoQuit.defaultMinutes, navigation: model.navigation) { value in
                                        guard autoQuit.minutes(for: item.url) != 0 else { return }
                                        autoQuit.setMinutes(value, for: item.url)
                                    }
                                }
                                SettingsRemoveItemButton(label: "移除 \(item.title)", help: "关闭此应用的自动退出") {
                                    autoQuit.removeRule(at: item.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ApplicationAutoQuitAddButton: View {
    let model: Model
    @ObservedObject private var catalog: ApplicationSettingsCatalog
    @ObservedObject private var autoQuit: ApplicationAutoQuit
    @State private var open = false
    @State private var query = ""
    @State private var options: [ResultFilterOption] = []
    @State private var error: String?

    init(model: Model) {
        self.model = model
        catalog = model.applicationSettingsCatalog
        autoQuit = model.applicationAutoQuit
    }

    var body: some View {
        Button {
            if open {
                open = false
            } else {
                query = ""
                error = nil
                refreshOptions()
                open = true
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 17)).frame(width: 24, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .accessibilityLabel("添加自动退出应用")
        .help("添加自动退出应用")
        .disabled(!model.applicationsEnabled)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                ResultFilterPanel(selection: "", options: ResultFilterPanel.matches(options, query: query.trimmingCharacters(in: .whitespacesAndNewlines)),
                                  query: $query, searchPlaceholder: "搜索应用…",
                                  emptyTitle: options.isEmpty ? "没有可添加的应用" : "没有匹配的应用",
                                  navigation: model.navigation, width: 360, maximumVisibleRows: 6,
                                  choose: add, dismiss: { open = false })
                if let error {
                    Divider()
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(10)
                }
            }
        }
        .onChange(of: catalog.items) { _, _ in if open { refreshOptions() } }
        .onChange(of: autoQuit.rules.keys.sorted()) { _, _ in if open { refreshOptions() } }
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
        open = false
    }
}

private struct AutoQuitDurationPicker: View {
    let label: String
    let minutes: Int
    let defaultMinutes: Int?
    let navigation: String
    let select: (Int) -> Void
    @State private var open = false
    @State private var query = ""

    var body: some View {
        Button {
            query = ""
            open.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                Text(title(for: minutes, compact: true))
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(label)
        .accessibilityValue(title(for: minutes))
        .popover(isPresented: $open, arrowEdge: .bottom) {
            let values = (defaultMinutes == nil ? [] : [ApplicationAutoQuit.useDefault]) + ApplicationAutoQuit.intervals
            let options = values.map { ResultFilterOption(id: String($0), title: title(for: $0), symbol: "") }
            ResultFilterPanel(selection: String(minutes), options: ResultFilterPanel.matches(options, query: query),
                              query: $query, searchPlaceholder: "搜索时长…", emptyTitle: "没有匹配时长",
                              navigation: navigation, maximumVisibleRows: 5, choose: { option in
                guard let value = Int(option.id) else { return }
                open = false
                select(value)
            }, dismiss: { open = false })
        }
    }

    private func title(for duration: Int, compact: Bool = false) -> String {
        if duration == ApplicationAutoQuit.useDefault, let defaultMinutes {
            let title = compact ? "默认" : "使用默认时长"
            return "\(title)（\(defaultMinutes) 分钟）"
        }
        return "\(duration) 分钟"
    }
}
