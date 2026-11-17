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
    @State private var drag: FallbackCommandDrag?

    init(model: Model) {
        self.model = model
        var changes = [ViewObservation.changes(model.$fallbackCommandIDs),
                       ViewObservation.changes(model.$disabledCommands)]
        if let registry = model.launcherModules { changes.append(registry.searchUpdates) }
        _observation = StateObject(wrappedValue: ViewObservation(changes))
    }

    var body: some View {
        let registry = model.launcherModules
        let catalog = registry?.fallbackCatalog() ?? []
        let entries = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let configured = model.fallbackCommandIDs
        let moduleTitles = Dictionary(uniqueKeysWithValues: (registry?.shortcutCommandGroups ?? []).map { ($0.id, $0.title) })

        VStack(alignment: .leading, spacing: 5) {
            SettingsSectionTitle(title: "备选命令")
                .padding(.bottom, 8)
                .settingsAnchor(.launcherFallbackCommands)
            SettingsGroup {
                Button {
                    query = ""
                    adding.toggle()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus.square")
                            .foregroundStyle(.secondary)
                        SettingsTitle("添加备选命令")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    let options = catalog.filter { !configured.contains($0.id) }
                        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                        .map { entry in
                            let source = registry?.moduleOwningCommand(entry.commandID).flatMap { moduleTitles[$0] }
                            return ResultFilterOption(id: entry.id, title: entry.name, symbol: entry.symbol,
                                                      subtitle: source ?? entry.detail, keywords: entry.aliases + [source ?? ""])
                        }
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
            }
            if !configured.isEmpty {
                SettingsGroup {
                    ForEach(configured, id: \.self) { id in
                        if id != configured.first { Divider().opacity(0.4) }
                        let commandID = CommandID(rawValue: id)
                        let entry = entries[id]
                        let declaration = registry?.declaration(commandID)
                        let owner = registry?.moduleOwningCommand(commandID)
                        let source = owner.flatMap { moduleTitles[$0] }
                        FallbackCommandSettingsRow(
                            title: entry?.name ?? declaration?.title ?? unavailableTitle(id),
                            source: entry == nil ? "当前不可用" : source ?? entry?.detail ?? "",
                            symbol: entry?.symbol ?? declaration?.symbol ?? "exclamationmark.circle",
                            artwork: entry.flatMap { registry?.artwork(for: $0) },
                            dropEdge: dropEdge(for: id, in: configured),
                            beginDrag: { beginDrag(id) },
                            receiveDrop: { receiveDrop($0, onto: id) },
                            remove: { model.fallbackCommandIDs.removeAll { $0 == id } }
                        )
                        .accessibilityAction(named: Text("上移")) { move(id, by: -1) }
                        .accessibilityAction(named: Text("下移")) { move(id, by: 1) }
                    }
                }
            }
        }
    }

    private func dropEdge(for id: String, in order: [String]) -> VerticalEdge? {
        guard let drag, let from = order.firstIndex(of: drag.id), let to = order.firstIndex(of: id),
              from != to else { return nil }
        return from < to ? .bottom : .top
    }

    private func beginDrag(_ id: String) -> NSItemProvider {
        let newDrag = FallbackCommandDrag(id: id)
        drag = newDrag
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: FallbackCommandDrag.type,
                                            visibility: .ownProcess) { completion in
            completion(newDrag.token, nil)
            return nil
        }
        return provider
    }

    private func receiveDrop(_ providers: [NSItemProvider], onto id: String) -> Bool {
        guard let drag, drag.id != id, let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: FallbackCommandDrag.type) { data, _ in
            DispatchQueue.main.async {
                guard data == drag.token, self.drag?.token == drag.token else { return }
                self.drag = nil
                var order = model.fallbackCommandIDs
                guard let from = order.firstIndex(of: drag.id), let to = order.firstIndex(of: id) else { return }
                let command = order.remove(at: from)
                order.insert(command, at: to)
                model.fallbackCommandIDs = order
            }
        }
        return true
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

private struct FallbackCommandDrag {
    static let type = "org.keylane.fallback-command-order"
    let id: String
    let token = Data(UUID().uuidString.utf8)
}

private struct FallbackCommandSettingsRow: View {
    let title: String
    let source: String
    let symbol: String
    let artwork: AnyView?
    let dropEdge: VerticalEdge?
    let beginDrag: () -> NSItemProvider
    let receiveDrop: ([NSItemProvider]) -> Bool
    let remove: () -> Void
    @State private var hovering = false
    @State private var targeted = false

    var body: some View {
        SettingsRow {
            HStack(spacing: 9) {
                ZStack {
                    Group {
                        if let artwork { artwork }
                        else { SettingsIcon(symbol: symbol, size: 18) }
                    }
                    .opacity(hovering ? 0 : 1)
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .opacity(hovering ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .onDrag(beginDrag)
                .help("拖拽排序")
                .accessibilityHidden(true)
                SettingsTitle(title).lineLimit(1)
            }
        } control: {
            Text(source)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.trailing, 4)
                .opacity(hovering ? 0 : 1)
                .overlay(alignment: .trailing) {
                    if hovering {
                        Button(action: remove) {
                            Image(systemName: "minus")
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除备选命令")
                        .help("移除备选命令")
                    }
                }
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay(alignment: dropEdge == .top ? .topLeading : .bottomLeading) {
            if targeted && dropEdge != nil {
                Capsule().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
            }
        }
        .onHover { hovering = $0 }
        .onDrop(of: [FallbackCommandDrag.type], isTargeted: $targeted, perform: receiveDrop)
        .accessibilityAction(named: Text("移除备选命令")) { remove() }
    }
}
