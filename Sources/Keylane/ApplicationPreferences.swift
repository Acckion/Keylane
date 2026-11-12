import SwiftUI
import AppKit
import Combine
import KeylaneCore

struct ApplicationPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation
    @ObservedObject private var catalog: ApplicationSettingsCatalog
    @ObservedObject private var autoQuit: ApplicationAutoQuit
    @State private var filter = ""
    @State private var filteredApplications: [ApplicationPreferenceItem]?

    init(model: Model) {
        self.model = model
        catalog = model.applicationSettingsCatalog
        autoQuit = model.applicationAutoQuit
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$applicationHotkeyAction),
            ViewObservation.changes(model.$applicationSettingsPath),
            ViewObservation.changes(model.$roots),
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$applicationsEnabled),
            ViewObservation.changes(model.$disabledCommands),
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$excluded),
            ViewObservation.changes(model.$favorites),
            ViewObservation.changes(model.$scanStatus)
        ]))
    }

    var body: some View {
        if let path = model.applicationSettingsPath {
            SettingsPageSections {
                HStack {
                    Text("命令设置").font(.headline)
                    Spacer()
                    Button("显示所有应用") { model.showAllApplicationSettings() }
                        .buttonStyle(.bordered)
                }.padding(.horizontal, 14)
                let url = URL(fileURLWithPath: path)
                if autoQuit.canConfigure(url) {
                    SettingsGroup {
                        autoQuitPicker("自动退出", detail: "应用离开前台后开始计时。应用可按正常退出流程提示保存。", url: url)
                    }.disabled(!model.applicationsEnabled)
                }
                CommandSettingsList(items: catalog.items.filter { $0.id == path }, id: \.id,
                                    emptyMessage: "应用已移走或删除") { item in
                    item.commandSettingsEntry(model: model)
                }
            }
        } else {
            allApplications
        }
    }

    private var allApplications: some View {
        let visibleApplications = filteredApplications ?? catalog.items
        return SettingsPageSections {
            SettingsGroup {
                SettingsRow("自动退出", detail: "在下方应用列表的操作菜单中为应用开启。再次切到前台会重置计时。") {
                    Text(autoQuit.rules.isEmpty ? "未开启" : "已配置 \(autoQuit.rules.count) 个应用")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(autoQuit.rules.keys.sorted(), id: \.self) { path in
                    let url = URL(fileURLWithPath: path)
                    if autoQuit.minutes(for: url) > 0 {
                        autoQuitPicker(model.appName(url), detail: path, url: url)
                    } else {
                        SettingsRow(model.appName(url), detail: "原应用已移动、删除或替换。") {
                            Button("移除规则") { autoQuit.removeRule(at: path) }
                        }
                    }
                }
            }.settingsAnchor(.applicationAutoQuit).disabled(!model.applicationsEnabled)
            SettingsGroup {
                SettingsPicker("快捷键行为", detail: "触发应用快捷键时执行的操作。",
                               selection: Binding(get: { model.applicationHotkeyAction }, set: { model.applicationHotkeyAction = $0 })) {
                    Text("激活应用").tag("activate")
                    Text("切换显示与隐藏").tag("toggle")
                }
            }.id("hotkey-action")
            SettingsSearchScopeCard(
                paths: model.roots,
                detail: "选择搜索应用程序时包含的其他文件夹。",
                anchor: .applicationScopes,
                add: model.addRoot,
                remove: { path in
                    model.roots.removeAll { $0 == path }
                    model.reloadCatalog()
                }
            ) { EmptyView() }

            SettingsSectionTitle(title: "命令")
            CommandSettingsList(items: ["manage-auto-quit", "uninstall-application"], id: \.self) { id in
                let commandID = CommandID(rawValue: id)
                let manage = id == "manage-auto-quit"
                return CommandSettingsEntry(title: manage ? "管理自动退出" : "卸载应用程序",
                                     model: model, commandID: commandID,
                                     isEnabled: Binding(get: { !model.disabledCommands.contains(id) }, set: { value in
                                         if value { model.disabledCommands.remove(id) }
                                         else { model.disabledCommands.insert(id) }
                                     }),
                                     perform: { model.runCommand(commandID, origin: .menu) },
                                     icon: { Image(systemName: manage ? "app.badge.clock" : "trash") })
            }.disabled(!model.applicationsEnabled)
            HStack {
                Text("应用程序").font(.system(size: 15, weight: .medium))
                Spacer()
                SettingsSearchField(text: $filter, placeholder: "筛选应用…").frame(width: 170, height: 24)
            }.padding(.horizontal, 14).padding(.top, 10)
            CommandSettingsList(items: visibleApplications, id: \.id, emptyMessage: "没有匹配的应用") { item in
                item.commandSettingsEntry(model: model)
            }.settingsAnchor(.applicationFavorites)
            HStack {
                Text(model.scanStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { model.discovery.refresh() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 14)
        }.font(.system(size: 15))
            .onChange(of: catalog.items) { _, _ in updateFilter(filter) }
            .onChange(of: filter) { _, value in updateFilter(value) }
    }

    private func updateFilter(_ query: String) {
        filteredApplications = query.isEmpty ? nil : catalog.items.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.filename.localizedCaseInsensitiveContains(query)
        }
    }

    private func autoQuitPicker(_ title: String, detail: String, url: URL) -> some View {
        SettingsPicker(title, detail: detail,
                       selection: Binding(get: { autoQuit.minutes(for: url) },
                                          set: { autoQuit.setMinutes($0, for: url) })) {
            Text("关闭").tag(0)
            ForEach(ApplicationAutoQuit.intervals, id: \.self) { minutes in
                Text("\(minutes) 分钟").tag(minutes)
            }
        }
    }

}

extension ApplicationPreferenceItem {
    var commandID: String { "app:" + id }

    func commandSettingsEntry(model: Model) -> CommandSettingsEntry<WorkspaceItemIcon> {
        let revision = ApplicationCommandRevision(
            title: self.title, alias: model.aliases[self.id] ?? "", shortcut: model.bindings[commandID],
            enabled: !model.excluded.contains(self.id), favorite: model.favorites.contains(self.id)
        )
        return CommandSettingsEntry(
            title: self.title, model: model, commandID: .init(rawValue: commandID), aliasKey: self.id,
            isEnabled: Binding(get: { !model.excluded.contains(self.id) }, set: { value in
                model.setApplicationEnabled(value, path: self.id)
            }),
            help: self.id,
            menu: [
                .init(title: revision.favorite ? "取消收藏" : "加入收藏") { model.toggleFavorite(self.id) },
                .init(title: "在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([self.url]) }
            ] + (model.applicationAutoQuit.canConfigure(url) ? [
                .init(title: "配置自动退出…") { model.openApplicationCommandSettings(path: self.id) }
            ] : []),
            renderRevision: revision,
            icon: { WorkspaceItemIcon(path: self.id) }
        )
    }

}

private struct ApplicationCommandRevision: Hashable {
    let title: String
    let alias: String
    let shortcut: Shortcut?
    let enabled: Bool
    let favorite: Bool
}

/// Keeps the settings list ready when switching away from and back to Applications.
final class ApplicationSettingsCatalog: ObservableObject {
    @Published private(set) var items: [ApplicationPreferenceItem] = []
    private var changes: AnyCancellable?

    init(model: Model) {
        changes = model.$apps.combineLatest(model.$excluded).sink { [weak self, weak model] apps, excluded in
            guard let self, let model else { return }
            var paths = Set(apps.map(\.path))
            for path in excluded where !paths.contains(path) && FileManager.default.fileExists(atPath: path) {
                paths.insert(path)
            }
            let updated = paths.map { path in
                let url = URL(fileURLWithPath: path)
                return ApplicationPreferenceItem(id: path, url: url, title: model.appName(url), filename: url.lastPathComponent)
            }.sorted {
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
            if items != updated { items = updated }
        }
    }
}

struct ApplicationPreferenceItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let title: String
    let filename: String
}

struct ApplicationsIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(LinearGradient(colors: [Color(white: 0.19), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.1)))
            VStack(spacing: 5) {
                HStack(spacing: 5) { tile([.cyan, .blue]); tile([.init(red: 0.6, green: 1, blue: 0.55), .green]) }
                HStack(spacing: 5) { tile([.orange, .init(red: 0.95, green: 0.35, blue: 0.12)]); VStack(spacing: 0) { Color.red; Color(white: 0.94) }.clipShape(RoundedRectangle(cornerRadius: 6)) }
            }.padding(9)
        }
    }
    private func tile(_ colors: [Color]) -> some View { RoundedRectangle(cornerRadius: 6).fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)) }
}
