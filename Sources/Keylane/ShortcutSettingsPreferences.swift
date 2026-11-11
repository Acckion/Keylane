import SwiftUI
import KeylaneCore

struct ShortcutSettingsPreferences: View {
    let model: Model
    @ObservedObject private var applications: ApplicationSettingsCatalog
    @StateObject private var observation: ViewObservation
    @AppStorage("hiddenShortcutSettingsGroups") private var hiddenGroupIDs = ""
    @State private var expanded: Set<String> = ["keylane.system-tools"]
    @State private var category: String?
    @State private var query = ""
    @State private var showsSearch = false
    @State private var collapsedWhileSearching: Set<String> = []

    init(model: Model) {
        self.model = model
        _applications = ObservedObject(wrappedValue: model.applicationSettingsCatalog)
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands),
            ViewObservation.changes(model.$excluded),
            ViewObservation.changes(model.$favorites),
            ViewObservation.changes(model.clipboard.$historyCommandEnabled),
            ViewObservation.changes(model.systemShortcuts.$entries),
            ViewObservation.changes(model.systemShortcuts.$disabledIDs),
            ViewObservation.changes(model.systemShortcuts.$icons)
        ]))
    }

    private let applicationsID = "keylane.applications"
    private var groups: [ShortcutCommandGroup] { model.launcherModules?.shortcutCommandGroups ?? [] }
    private var categories: [(id: String, title: String)] {
        [(applicationsID, "应用程序")] + groups.map { ($0.id.rawValue, $0.title) }
    }
    private var hiddenGroups: Set<String> { Set(hiddenGroupIDs.split(separator: "\n").map(String.init)) }
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let appRows = isVisible(applicationsID) && (!search.isEmpty || expanded.contains(applicationsID))
            ? applications.items.filter { matches(title: $0.title, aliasKey: $0.id, commandID: "app:" + $0.id) }
            : []
        let visibleGroups = groups.filter { group in
            isVisible(group.id.rawValue) && (search.isEmpty || groupMatches(group))
        }
        let showsApplications = isVisible(applicationsID) && (search.isEmpty || !appRows.isEmpty)
        SettingsPageSections {
            HStack(spacing: 8) {
                if showsSearch {
                    SettingsSearchField(text: $query, placeholder: "搜索命令、别名或快捷键…")
                        .frame(maxWidth: 240).frame(height: 28)
                }
                Spacer(minLength: 0)
                SettingsIconButton(showsSearch ? "关闭搜索" : "搜索", symbol: showsSearch ? "xmark" : "magnifyingglass") {
                    showsSearch.toggle()
                    if !showsSearch { query = "" }
                }
                Menu {
                    Picker("分类", selection: $category) {
                        Text("全部分类").tag(nil as String?)
                        ForEach(categories.filter { !hiddenGroups.contains($0.id) }, id: \.id) { item in
                            Text(item.title).tag(Optional(item.id))
                        }
                    }
                    if !hiddenGroups.isEmpty {
                        Divider()
                        Menu("恢复隐藏分组") {
                            ForEach(categories.filter { hiddenGroups.contains($0.id) }, id: \.id) { item in
                                Button(item.title) { setHidden(item.id, false) }
                            }
                            Button("恢复全部") { hiddenGroupIDs = "" }
                        }
                    }
                } label: {
                    Label(categories.first { $0.id == category }?.title ?? "全部分类", systemImage: "list.bullet")
                }.fixedSize()
            }

            if showsApplications {
                groupCard(id: applicationsID, title: "应用程序", symbol: "square.grid.2x2.fill") {
                    CommandSettingsList(items: appRows, id: \.id, emptyMessage: "没有匹配的应用", showsColumns: true, showsBackground: false) {
                        $0.commandSettingsEntry(model: model)
                    }
                }
            }
            ForEach(visibleGroups, id: \.id) { group in
                groupCard(id: group.id.rawValue, title: group.title, symbol: group.symbol) {
                    commandList(group)
                    if group.id.rawValue == "keylane.shortcuts", !model.systemShortcuts.entries.isEmpty {
                        CommandSettingsList(items: model.systemShortcuts.entries.filter {
                            matches(title: $0.name, aliasKey: $0.commandID, commandID: $0.commandID)
                        }, id: \.id, emptyMessage: "没有匹配的快捷指令", showsColumns: true, showsBackground: false) {
                            $0.commandSettingsEntry(model: model, controller: model.systemShortcuts)
                        }
                    }
                }
            }
            if categories.allSatisfy({ hiddenGroups.contains($0.id) }) {
                ContentUnavailableView("所有分组已隐藏", systemImage: "keyboard")
            } else if !search.isEmpty, visibleGroups.isEmpty, !showsApplications {
                ContentUnavailableView.search(text: search)
            }
        }
        .settingsAnchor(.hotkeys)
        .onChange(of: category) { _, id in if let id { expanded.insert(id) } }
        .onChange(of: search) { _, _ in collapsedWhileSearching.removeAll() }
    }

    private func isVisible(_ id: String) -> Bool {
        !hiddenGroups.contains(id) && (category == nil || category == id)
    }

    private func setHidden(_ id: String, _ hidden: Bool) {
        var ids = hiddenGroups
        if hidden {
            ids.insert(id)
            if category == id { category = nil }
        } else { ids.remove(id) }
        hiddenGroupIDs = ids.sorted().joined(separator: "\n")
    }

    private func matches(title: String, aliasKey: String, commandID: String) -> Bool {
        search.isEmpty || [title, model.aliases[aliasKey] ?? "", model.bindings[commandID]?.keycaps.joined() ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(search) }
    }

    private func groupMatches(_ group: ShortcutCommandGroup) -> Bool {
        if group.commands.contains(where: {
            matches(title: $0.declaration.title, aliasKey: $0.declaration.id.rawValue, commandID: $0.declaration.id.rawValue)
        }) { return true }
        switch group.id.rawValue {
        case "keylane.host":
            return matches(title: "Keylane 热键", aliasKey: "launcher", commandID: "launcher")
        case "keylane.shortcuts":
            return model.systemShortcuts.entries.contains {
                matches(title: $0.name, aliasKey: $0.commandID, commandID: $0.commandID)
            }
        default:
            return false
        }
    }

    @ViewBuilder private func commandList(_ group: ShortcutCommandGroup) -> some View {
        let items = group.commands.filter {
            matches(title: $0.declaration.title, aliasKey: $0.declaration.id.rawValue, commandID: $0.declaration.id.rawValue)
        }
        if group.id.rawValue == "keylane.host", matches(title: "Keylane 热键", aliasKey: "launcher", commandID: "launcher") {
            SettingsGroup {
                SettingsShortcutBindingRow(title: "Keylane 热键", shortcut: model.bindings["launcher"], symbol: "command") {
                    model.setShortcut("launcher", value: $0)
                }
            }
        }
        if !items.isEmpty || group.id.rawValue != "keylane.shortcuts" {
            CommandSettingsList(items: items, id: \.declaration.id, emptyMessage: "没有匹配的命令",
                                showsColumns: true, showsBackground: false) { command in
                let declaration = command.declaration
                let enabled: Binding<Bool>? = declaration.id.rawValue == "settings" ? nil :
                    command.settingsEnabled ?? Binding(
                        get: { !model.disabledCommands.contains(declaration.id.rawValue) },
                        set: { value in
                            if value { model.disabledCommands.remove(declaration.id.rawValue) }
                            else { model.disabledCommands.insert(declaration.id.rawValue) }
                        }
                    )
                return CommandSettingsEntry(title: declaration.title, model: model, commandID: declaration.id,
                                            isEnabled: enabled) { SettingsIcon(symbol: declaration.symbol) }
            }
        }
    }

    private func groupCard<Content: View>(id: String, title: String, symbol: String,
                                          @ViewBuilder content: @escaping () -> Content) -> some View {
        let isExpanded = search.isEmpty ? expanded.contains(id) : !collapsedWhileSearching.contains(id)
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
                            SettingsIcon(symbol: symbol, size: 18)
                            SettingsTitle(title)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
                    SettingsIconButton("隐藏\(title)分组", symbol: "minus", compact: true) { setHidden(id, true) }
                }.padding(.horizontal, 14).frame(minHeight: SettingsRowsLayout.rowHeight)
                if isExpanded { content() }
            }
        }
    }
}
