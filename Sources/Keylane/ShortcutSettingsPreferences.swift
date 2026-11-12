import Combine
import SwiftUI
import KeylaneCore

extension DynamicCommandSettings {
    init<Item: Identifiable, Icon: View>(
        model: Model,
        items: @escaping () -> [Item],
        title: KeyPath<Item, String>,
        commandID: KeyPath<Item, String>,
        aliasKey: KeyPath<Item, String>? = nil,
        updates: @escaping () -> [AnyPublisher<Void, Never>],
        entry: @escaping (Item, Model) -> CommandSettingsEntry<Icon>
    ) {
        self.init(updates: updates, matchingList: { [weak model] matches in
            let allItems = items()
            let visible = matches.map { predicate in
                allItems.filter { item in
                    predicate(item[keyPath: title], item[keyPath: commandID], aliasKey.map { item[keyPath: $0] })
                }
            } ?? allItems
            guard !visible.isEmpty else { return nil }
            return { showsColumns in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(CommandSettingsList(items: visible, id: \.id, showsColumns: showsColumns, showsBackground: false) {
                    entry($0, model)
                })
            }
        })
    }
}

final class ShortcutSettingsFilters: ObservableObject {
    @Published var query = ""
    @Published var category: String?
    @Published private(set) var hiddenGroups = Set(
        (UserDefaults.standard.string(forKey: "hiddenShortcutSettingsGroups") ?? "")
            .split(separator: "\n").map(String.init)
    )

    func setHidden(_ id: String, _ hidden: Bool) {
        var ids = hiddenGroups
        if hidden {
            ids.insert(id)
            if category == id { category = nil }
        } else {
            ids.remove(id)
        }
        saveHiddenGroups(ids)
    }

    func restoreAll() { saveHiddenGroups([]) }

    private func saveHiddenGroups(_ ids: Set<String>) {
        hiddenGroups = ids
        UserDefaults.standard.set(ids.sorted().joined(separator: "\n"), forKey: "hiddenShortcutSettingsGroups")
    }
}

struct ShortcutSettingsToolbar: View {
    let groups: [ShortcutCommandGroup]
    @ObservedObject var filters: ShortcutSettingsFilters

    var body: some View {
        HStack(spacing: 8) {
            SettingsSearchField(text: $filters.query, placeholder: "搜索快捷键…")
                .frame(width: 128, height: 28)
                .help("搜索命令、别名或快捷键")
            Menu {
                Picker("分类", selection: $filters.category) {
                    Text("全部分类").tag(nil as String?)
                    ForEach(groups.filter { !filters.hiddenGroups.contains($0.id.rawValue) }, id: \.id) { item in
                        Text(item.title).tag(Optional(item.id.rawValue))
                    }
                }
                if !filters.hiddenGroups.isEmpty {
                    Divider()
                    Menu("恢复隐藏分组") {
                        ForEach(groups.filter { filters.hiddenGroups.contains($0.id.rawValue) }, id: \.id) { item in
                            Button(item.title) { filters.setHidden(item.id.rawValue, false) }
                        }
                        Button("恢复全部", action: filters.restoreAll)
                    }
                }
            } label: {
                Label(groups.first { $0.id.rawValue == filters.category }?.title ?? "全部分类", systemImage: "list.bullet")
                    .lineLimit(1)
            }
            .help("筛选快捷键分类")
        }
    }
}

struct ShortcutSettingsPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation
    @ObservedObject var filters: ShortcutSettingsFilters
    @State private var expanded: Set<String> = ["keylane.system-tools"]
    @State private var collapsedWhileSearching: Set<String> = []

    init(model: Model, filters: ShortcutSettingsFilters) {
        self.model = model
        self.filters = filters
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ] + (model.launcherModules?.shortcutSettingsUpdates() ?? [])))
    }

    private var groups: [ShortcutCommandGroup] { model.launcherModules?.shortcutCommandGroups ?? [] }
    private var search: String { filters.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let searchTerm = search
        let hidden = filters.hiddenGroups
        let visibleGroups = groups.compactMap { group -> VisibleGroup? in
            let id = group.id.rawValue
            guard !hidden.contains(id), filters.category == nil || filters.category == id else { return nil }
            let isExpanded = searchTerm.isEmpty ? expanded.contains(id) : !collapsedWhileSearching.contains(id)
            let content = isExpanded || !searchTerm.isEmpty ? matchingContent(for: group, query: searchTerm) : nil
            guard searchTerm.isEmpty || content != nil else { return nil }
            return VisibleGroup(group: group, isExpanded: isExpanded, content: content)
        }
        SettingsPageSections {
            ForEach(visibleGroups, id: \.group.id) { visible in
                groupCard(visible)
            }
            if groups.allSatisfy({ hidden.contains($0.id.rawValue) }) {
                ContentUnavailableView("所有分组已隐藏", systemImage: "keyboard")
            } else if !searchTerm.isEmpty, visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchTerm)
            }
        }
        .settingsAnchor(.hotkeys)
        .onAppear { if let id = filters.category { expanded.insert(id) } }
        .onChange(of: filters.category) { _, id in if let id { expanded.insert(id) } }
        .onChange(of: search) { _, _ in collapsedWhileSearching.removeAll() }
    }

    private struct VisibleGroup {
        let group: ShortcutCommandGroup
        let isExpanded: Bool
        let content: GroupContent?
    }

    private struct GroupContent {
        let binding: ShortcutSettingsBinding?
        let commands: [LauncherModule.Command]
        let dynamicList: ((Bool) -> AnyView)?
    }

    private func matchingContent(for group: ShortcutCommandGroup, query: String) -> GroupContent? {
        func matches(_ title: String, _ commandID: String, _ aliasKey: String?) -> Bool {
            query.isEmpty || title.localizedCaseInsensitiveContains(query)
                || model.aliases[aliasKey ?? commandID]?.localizedCaseInsensitiveContains(query) == true
                || model.bindings[commandID]?.keycaps.joined().localizedCaseInsensitiveContains(query) == true
        }
        let binding = group.binding.flatMap { matches($0.title, $0.id, nil) ? $0 : nil }
        let commands = group.commands.filter {
            matches($0.declaration.title, $0.declaration.id.rawValue, nil)
        }
        let dynamicList = group.dynamicCommands?.matchingList(query.isEmpty ? nil : matches)
        guard binding != nil || !commands.isEmpty || dynamicList != nil else { return nil }
        return GroupContent(binding: binding, commands: commands, dynamicList: dynamicList)
    }

    @ViewBuilder private func commandList(_ content: GroupContent) -> some View {
        if let binding = content.binding {
            SettingsGroup {
                SettingsShortcutBindingRow(title: binding.title, shortcut: model.bindings[binding.id], symbol: binding.symbol) {
                    model.setShortcut(binding.id, value: $0)
                }
            }
        }
        if !content.commands.isEmpty {
            CommandSettingsList(items: content.commands, id: \.declaration.id, showsColumns: true, showsBackground: false) {
                $0.commandSettingsEntry(model: model)
            }
        }
        if let dynamicList = content.dynamicList {
            if !content.commands.isEmpty { CommandSettingsListDivider() }
            dynamicList(content.commands.isEmpty)
        }
    }

    private func groupCard(_ visible: VisibleGroup) -> some View {
        let group = visible.group
        let id = group.id.rawValue
        let isExpanded = visible.isExpanded
        return SettingsCard(layout: .flush) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button {
                        if search.isEmpty {
                            if isExpanded { expanded.remove(id) } else { expanded.insert(id) }
                        } else {
                            if isExpanded { collapsedWhileSearching.insert(id) }
                            else { collapsedWhileSearching.remove(id) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            SettingsIcon(symbol: group.symbol, size: 18)
                            SettingsTitle(group.title)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                    SettingsIconButton("隐藏\(group.title)分组", symbol: "minus", compact: true) { filters.setHidden(id, true) }
                }.padding(.horizontal, 14).frame(minHeight: SettingsRowsLayout.rowHeight)
                if isExpanded {
                    if let content = visible.content { commandList(content) }
                    else { CommandSettingsEmptyState(message: "暂无命令") }
                }
            }
        }
    }
}


/// Generic settings for extensions that only need command configuration.
struct ExtensionCommandPreferences: View {
    let model: Model
    let commands: [LauncherModule.Command]
    @StateObject private var observation: ViewObservation

    init(model: Model, commands: [LauncherModule.Command]) {
        self.model = model
        self.commands = commands
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ]))
    }

    var body: some View {
        CommandSettingsList(items: commands, id: \.declaration.id, showsColumns: true) {
            $0.commandSettingsEntry(model: model)
        }
    }
}

private extension LauncherModule.Command {
    func commandSettingsEntry(model: Model) -> CommandSettingsEntry<SettingsIcon> {
        let id = declaration.id.rawValue
        let enabled: Binding<Bool>? = id == "settings" ? nil :
            settingsEnabled ?? Binding(
                get: { !model.disabledCommands.contains(id) },
                set: { value in
                    if value { model.disabledCommands.remove(id) }
                    else { model.disabledCommands.insert(id) }
                }
            )
        return CommandSettingsEntry(title: declaration.title, model: model, commandID: declaration.id,
                                    isEnabled: enabled) {
            SettingsIcon(symbol: declaration.symbol,
                         artwork: ModuleArtwork.command(declaration.id, settingsPage: declaration.settingsPage))
        }
    }
}
