import SwiftUI
import KeylaneCore

struct LauncherBehaviorPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$placement),
            ViewObservation.changes(model.$launcherReturnDelay),
            ViewObservation.changes(model.$rootSearchSensitivity),
            ViewObservation.changes(model.$rootFileContentSearch),
            ViewObservation.changes(model.fileSearch.$options.map { [$0.enabled, $0.searchFromLauncher, $0.contentSearch] })
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("显示 Keylane 的位置",
                               selection: Binding(get: { model.placement }, set: { model.placement = $0 })) {
                    Text("鼠标所在屏幕").tag("activeScreen")
                    Text("主显示器").tag("primaryDisplay")
                    Text("记住上次位置").tag("remember")
                }.settingsAnchor(.windowPosition)
                Divider()
                SettingsPicker("返回主搜索", detail: "隐藏窗口达到指定时间后，再次唤起时清空查询并返回主搜索。",
                               selection: Binding(get: { model.launcherReturnDelay }, set: { model.launcherReturnDelay = $0 })) {
                    ForEach(LauncherReturnDelay.allCases, id: \.self) { delay in
                        Text(returnDelayTitle(delay)).tag(delay)
                    }
                }.settingsAnchor(.launcherReturnDelay)
                Divider()
                SettingsPicker("主搜索灵敏度", detail: "较低灵敏度包含更多模糊匹配，较高灵敏度优先显示名称或别名前缀匹配。",
                               selection: Binding(get: { model.rootSearchSensitivity }, set: { model.rootSearchSensitivity = $0 })) {
                    Text("低").tag(LauncherSearchRanking.Sensitivity.low)
                    Text("中").tag(LauncherSearchRanking.Sensitivity.medium)
                    Text("高").tag(LauncherSearchRanking.Sensitivity.high)
                }.settingsAnchor(.rootSearchSensitivity)
                Divider()
                // TODO: Add a local query history and restore it with Up in root search.
                SettingsActionRow(title: "搜索历史", detail: "通过方向键恢复近期搜索和清除历史的功能待实现。",
                                  actionTitle: "重置") {}.disabled(true).settingsAnchor(.launcherSearchHistory)
            }

            SettingsSectionTitle(title: "自定义搜索")
            SettingsGroup {
                SettingsRow("在主搜索中显示文件", detail: model.fileSearch.options.enabled
                            ? "在启动器中直接搜索文件名。" : "请先启用文件搜索扩展。") {
                    Toggle("在主搜索中显示文件", isOn: Binding(
                        get: { model.fileSearch.options.searchFromLauncher },
                        set: { model.fileSearch.options.searchFromLauncher = $0 }
                    )).labelsHidden().toggleStyle(SettingsSwitchStyle())
                        .disabled(!model.fileSearch.options.enabled)
                }.settingsAnchor(.fileSearchInline)
                Divider()
                SettingsRow("在主搜索中匹配文件内容", detail: "需要在文件搜索中开启内容搜索。") {
                    Toggle("在主搜索中匹配文件内容", isOn: Binding(
                        get: { model.rootFileContentSearch },
                        set: { model.rootFileContentSearch = $0 }
                    )).labelsHidden().toggleStyle(SettingsSwitchStyle())
                        .disabled(!model.fileSearch.options.enabled || !model.fileSearch.options.searchFromLauncher ||
                                  !model.fileSearch.options.contentSearch)
                }.settingsAnchor(.rootFileContentSearch)
                Divider()
                // TODO: Add an opt-in Contacts result provider for root search.
                SettingsRow("在主搜索中显示联系人", detail: "待实现") {
                    Toggle("在主搜索中显示联系人", isOn: .constant(false))
                        .labelsHidden().toggleStyle(SettingsSwitchStyle()).disabled(true)
                }.settingsAnchor(.rootContactsSearch)
            }

            FallbackCommandPreferences(model: model)
        }
    }

    private func returnDelayTitle(_ delay: LauncherReturnDelay) -> String {
        switch delay {
        case .immediately: "立即"
        case .after30Seconds: "30 秒后"
        case .after90Seconds: "90 秒后"
        case .after5Minutes: "5 分钟后"
        case .never: "从不"
        }
    }
}

private struct FallbackCommandPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation
    @State private var adding = false
    @State private var query = ""

    init(model: Model) {
        self.model = model
        var changes = [ViewObservation.changes(model.$fallbackCommandIDs),
                       ViewObservation.changes(model.$disabledCommands)]
        if let registry = model.launcherModules { changes.append(registry.searchUpdates) }
        _observation = StateObject(wrappedValue: ViewObservation(changes))
    }

    var body: some View {
        let catalog = model.launcherModules?.fallbackCatalog() ?? []
        let entries = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let configured = model.fallbackCommandIDs
        SettingsListCard(title: "备选命令", detail: "主搜索没有匹配结果时，按这里的顺序显示。选择命令后，它会接收当前搜索内容。",
                         anchor: .launcherFallbackCommands) {
            SettingsIconButton("添加备选命令", symbol: "plus") {
                query = ""
                adding.toggle()
            }
            .popover(isPresented: $adding, arrowEdge: .bottom) {
                let options = catalog.filter { !configured.contains($0.id) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    .map { ResultFilterOption(id: $0.id, title: $0.name, symbol: $0.symbol,
                                              subtitle: $0.detail, keywords: $0.aliases) }
                ResultFilterPanel(selection: "", options: ResultFilterPanel.matches(
                    options, query: query.trimmingCharacters(in: .whitespacesAndNewlines)
                ), query: $query, searchPlaceholder: "搜索命令…",
                   emptyTitle: options.isEmpty ? "没有可添加的命令" : "没有匹配的命令",
                   navigation: model.navigation, width: 330, maximumVisibleRows: 7,
                   choose: { option in
                       if !model.fallbackCommandIDs.contains(option.id) { model.fallbackCommandIDs.append(option.id) }
                       adding = false
                   }, dismiss: { adding = false })
            }
        } content: {
            if configured.isEmpty {
                SettingsListEmptyState(title: "尚未添加备选命令")
            } else {
                SettingsCompactList(items: configured, id: \.self) { id in
                    let entry = entries[id]
                    let declaration = model.launcherModules?.declaration(.init(rawValue: id))
                    SettingsCompactItemRow(title: entry?.name ?? declaration?.title ?? unavailableTitle(id),
                                           symbol: entry?.symbol ?? declaration?.symbol ?? "exclamationmark.circle",
                                           detail: entry?.detail ?? "当前不可用") {
                        SettingsIconButton("上移", symbol: "arrow.up", compact: true) { move(id, by: -1) }
                            .disabled(id == configured.first)
                        SettingsIconButton("下移", symbol: "arrow.down", compact: true) { move(id, by: 1) }
                            .disabled(id == configured.last)
                        SettingsIconButton("移除备选命令", symbol: "minus", compact: true) {
                            model.fallbackCommandIDs.removeAll { $0 == id }
                        }
                    }
                }
            }
        }
    }

    private func move(_ id: String, by offset: Int) {
        var order = model.fallbackCommandIDs
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        model.fallbackCommandIDs = order
    }

    private func unavailableTitle(_ id: String) -> String {
        if id.hasPrefix(ScriptCommand.namespace) {
            return URL(fileURLWithPath: String(id.dropFirst(ScriptCommand.namespace.count))).lastPathComponent
        }
        return "命令已停用或移除"
    }
}
