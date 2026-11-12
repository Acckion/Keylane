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

final class ShortcutSettingsControls: ObservableObject {
    @Published var category: String?
    @Published var query = ""
    @Published var searchPresented = false

    func dismissSearch() {
        query = ""
        searchPresented = false
    }
}

struct ShortcutSettingsToolbar: View {
    let groups: [ShortcutCommandGroup]
    let navigation: String
    @ObservedObject var selection: ShortcutSettingsControls
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if selection.searchPresented {
                SettingsSearchField(text: $selection.query, placeholder: "搜索快捷键…", floating: true,
                                    autofocus: true, endEditing: {
                                        if selection.query.isEmpty { selection.searchPresented = false }
                                    }, cancel: selection.dismissSearch)
                    .padding(.horizontal, 9)
                    .frame(width: 158, height: 36)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Button { selection.searchPresented = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("搜索快捷键")
                .help("搜索快捷键")
            }
            ShortcutSettingsCategoryFilter(groups: groups, navigation: navigation, selection: selection)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: selection.searchPresented)
        .onDisappear(perform: selection.dismissSearch)
    }
}

struct ShortcutSettingsCategoryFilter: View {
    let groups: [ShortcutCommandGroup]
    let navigation: String
    @ObservedObject var selection: ShortcutSettingsControls
    @AppStorage("hiddenShortcutSettingsGroups") private var hiddenGroupIDs = ""
    @State private var categoryFilterOpen = false
    @State private var categoryQuery = ""

    var body: some View {
        let hidden = Set(hiddenGroupIDs.split(separator: "\n").map(String.init))
        let all = ResultFilterOption(id: "all", title: "全部分类", symbol: "list.bullet")
        let options = [all] + groups.filter { !hidden.contains($0.id.rawValue) }.map {
            ResultFilterOption(id: $0.id.rawValue, title: $0.title, symbol: $0.symbol)
        }
        let current = options.first { $0.id == selection.category } ?? all
        return Button {
            categoryQuery = ""
            categoryFilterOpen.toggle()
        } label: {
            Image(systemName: current.symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("筛选：\(current.title)")
        .accessibilityLabel("筛选：\(current.title)")
        .popover(isPresented: $categoryFilterOpen, arrowEdge: .top) {
            VStack(spacing: 0) {
                ResultFilterPanel(selection: current.id,
                                  options: ResultFilterPanel.matches(options, query: categoryQuery),
                                  query: $categoryQuery, searchPlaceholder: "搜索分类…",
                                  emptyTitle: "没有匹配分类", navigation: navigation,
                                  choose: { option in
                                      selection.category = option.id == all.id ? nil : option.id
                                      categoryFilterOpen = false
                                  }, dismiss: { categoryFilterOpen = false })
                if !hidden.isEmpty {
                    Divider()
                    Menu("恢复隐藏分组") {
                        ForEach(groups.filter { hidden.contains($0.id.rawValue) }, id: \.id) { item in
                            Button(item.title) {
                                hiddenGroupIDs = hidden.subtracting([item.id.rawValue]).sorted().joined(separator: "\n")
                            }
                        }
                        Button("恢复全部") { hiddenGroupIDs = "" }
                    }
                    .padding(10)
                }
            }
        }
    }
}

struct ShortcutSettingsPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation
    @AppStorage("hiddenShortcutSettingsGroups") private var hiddenGroupIDs = ""
    @State private var expanded: Set<String> = ["keylane.system-tools"]
    @ObservedObject var selection: ShortcutSettingsControls
    @State private var collapsedWhileSearching: Set<String> = []

    init(model: Model, selection: ShortcutSettingsControls) {
        self.model = model
        self.selection = selection
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ] + (model.launcherModules?.shortcutSettingsUpdates() ?? [])))
    }

    private var groups: [ShortcutCommandGroup] { model.launcherModules?.shortcutCommandGroups ?? [] }
    private var hiddenGroups: Set<String> { Set(hiddenGroupIDs.split(separator: "\n").map(String.init)) }
    private var search: String { selection.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let searchTerm = search
        let hidden = hiddenGroups
        let visibleGroups = groups.compactMap { group -> VisibleGroup? in
            let id = group.id.rawValue
            guard !hidden.contains(id), selection.category == nil || selection.category == id else { return nil }
            let isExpanded = searchTerm.isEmpty ? expanded.contains(id) : !collapsedWhileSearching.contains(id)
            let content = isExpanded || !searchTerm.isEmpty ? matchingContent(for: group, query: searchTerm) : nil
            guard searchTerm.isEmpty || content != nil else { return nil }
            return VisibleGroup(group: group, isExpanded: isExpanded, content: content)
        }
        return SettingsPageSections {
            ForEach(visibleGroups, id: \.group.id) { visible in
                groupCard(visible)
            }
            if groups.allSatisfy({ hidden.contains($0.id.rawValue) }) {
                ContentUnavailableView("所有分组已隐藏", systemImage: "keyboard")
            } else if !searchTerm.isEmpty, visibleGroups.isEmpty {
                ContentUnavailableView.search(text: searchTerm)
            }
        }
        .background {
            Button("搜索快捷键") { selection.searchPresented = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
                .accessibilityHidden(true)
        }
        .settingsAnchor(.hotkeys)
        .onAppear { if let id = selection.category { expanded.insert(id) } }
        .onChange(of: selection.category) { _, id in if let id { expanded.insert(id) } }
        .onChange(of: search) { _, _ in collapsedWhileSearching.removeAll() }
    }

    private func setHidden(_ id: String, _ hidden: Bool) {
        var ids = hiddenGroups
        if hidden {
            ids.insert(id)
            if selection.category == id { selection.category = nil }
        } else { ids.remove(id) }
        hiddenGroupIDs = ids.sorted().joined(separator: "\n")
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
                    SettingsIconButton("隐藏\(group.title)分组", symbol: "minus", compact: true) { setHidden(id, true) }
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
        ] + commands.compactMap { command in
            command.settingsEnabled.flatMap { _ in command.permission }
        }.flatMap { permission in
            [permission.updates, permission.settingsStatus.map { _ in () }.eraseToAnyPublisher()]
        }))
    }

    var body: some View {
        CommandSettingsList(items: commands, id: \.declaration.id, showsColumns: true,
                            usesFixedRowHeights: !commands.contains { $0.settingsEnabled != nil && $0.permission != nil }) {
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
        var entry = CommandSettingsEntry(title: declaration.title, model: model, commandID: declaration.id,
                                    isEnabled: enabled) {
            SettingsIcon(symbol: declaration.symbol,
                         artwork: ModuleArtwork.command(declaration.id, settingsPage: declaration.settingsPage))
        }
        if settingsEnabled != nil { entry.permission = permission }
        return entry
    }
}
