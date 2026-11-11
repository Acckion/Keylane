import SwiftUI
import AppKit
import Combine
import KeylaneCore

struct ApplicationPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation
    @ObservedObject private var catalog: ApplicationSettingsCatalog
    @State private var filter = ""
    @State private var filteredApplications: [ApplicationPreferenceItem]?

    init(model: Model) {
        self.model = model
        catalog = model.applicationSettingsCatalog
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$applicationHotkeyAction),
            ViewObservation.changes(model.$applicationSettingsPath),
            ViewObservation.changes(model.$roots),
            ViewObservation.changes(model.$aliases),
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
                CommandSettingsList(items: catalog.items.filter { $0.id == path }, id: \.id,
                                    emptyMessage: "应用已移走或删除") { item in
                    applicationCommand(item)
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
                SettingsRow("自动退出", detail: "停止使用应用一段时间后自动退出。") {
                    HStack {
                        Text("未实现").font(.caption).foregroundStyle(.tertiary)
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }.help("自动退出将在系统工具阶段实现；当前不会自动退出任何应用。")
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
            CommandSettingsList(items: ["管理自动退出", "卸载应用程序"], id: \.self) { title in
                unavailableCommand(title, icon: title == "管理自动退出" ? "app.badge.clock" : "trash.square.fill",
                                   color: title == "管理自动退出" ? .gray : .red)
            }
            HStack {
                Text("应用程序").font(.system(size: 15, weight: .medium))
                Spacer()
                SettingsSearchField(text: $filter, placeholder: "筛选应用…").frame(width: 170, height: 24)
            }.padding(.horizontal, 14).padding(.top, 10)
            CommandSettingsList(items: visibleApplications, id: \.id, emptyMessage: "没有匹配的应用") { item in
                applicationCommand(item)
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

    private func unavailableCommand(_ title: String, icon: String, color: Color) -> CommandSettingsEntry<some View> {
        CommandSettingsEntry(title: title, alias: .constant(""), shortcut: nil,
                             isEnabled: .constant(false), setShortcut: { _ in },
                             icon: { Image(systemName: icon).font(VisualStyle.actionSymbol).foregroundStyle(color) },
                             available: false, help: "此命令尚未实现，不能启用或设置快捷键。")
    }

    private func applicationCommand(_ item: ApplicationPreferenceItem) -> CommandSettingsEntry<SettingsApplicationIcon> {
        let revision = ApplicationCommandRevision(
            title: item.title, alias: model.aliases[item.id] ?? "", shortcut: model.bindings["app:" + item.id],
            enabled: !model.excluded.contains(item.id), favorite: model.favorites.contains(item.id)
        )
        return CommandSettingsEntry(
            title: item.title, model: model, commandID: .init(rawValue: "app:" + item.id), aliasKey: item.id,
            isEnabled: Binding(get: { !model.excluded.contains(item.id) }, set: { value in
                model.setApplicationEnabled(value, path: item.id)
            }),
            help: item.id,
            menu: [
                .init(title: revision.favorite ? "取消收藏" : "加入收藏") { model.toggleFavorite(item.id) },
                .init(title: "在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            ],
            renderRevision: revision,
            icon: { SettingsApplicationIcon(path: item.id) }
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
    @Published fileprivate private(set) var items: [ApplicationPreferenceItem] = []
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

private struct ApplicationPreferenceItem: Identifiable, Equatable {
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


struct ApplicationSettingsInfo: View {
    let model: Model
    @State private var status = ""

    var body: some View {
        Group {
            Text(status)
            Text("关闭模块会停用应用搜索和应用快捷键，已保存的配置保留。自动退出和卸载命令尚未实现。")
        }.onReceive(model.$scanStatus.removeDuplicates()) { status = $0 }
    }
}
