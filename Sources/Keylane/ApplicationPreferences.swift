import SwiftUI
import AppKit
import Combine
import KeylaneCore

struct ApplicationPreferences: View {
    @ObservedObject var model: Model
    @State private var filter = ""
    @State private var catalog: [ApplicationPreferenceItem] = []
    @State private var visibleApplications: [ApplicationPreferenceItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            surface {
                HStack {
                    caption("自动退出", "停止使用应用一段时间后自动退出。")
                    Spacer(); Text("未实现").font(.caption).foregroundStyle(.tertiary)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }.padding(14)
            }.help("自动退出将在系统工具阶段实现；当前不会自动退出任何应用。")
            surface {
                HStack(alignment: .top) {
                    caption("快捷键行为", "触发应用快捷键时执行的操作。")
                    Spacer(minLength: 8)
                    Picker("快捷键行为", selection: $model.applicationHotkeyAction) {
                        Text("激活应用").tag("activate")
                        Text("切换显示与隐藏").tag("toggle")
                    }.pickerStyle(.menu).buttonStyle(.borderless).labelsHidden().fixedSize().padding(.top, 1)
                }.padding(14)
            }.id("hotkey-action")
            surface {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        caption("搜索范围", "选择搜索应用程序时包含的其他文件夹。")
                        Spacer(minLength: 8)
                        Button { model.addRoot() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .medium)) }
                            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.small).help("添加搜索文件夹")
                    }.padding(.bottom, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(model.roots.enumerated()), id: \.element) { index, path in
                            ScopeRow(path: path) { model.roots.removeAll { $0 == path }; model.reloadCatalog() }
                            if index < model.roots.count - 1 { Divider().opacity(0.4) }
                        }
                        if model.roots.isEmpty { Text("尚未添加搜索范围").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14) }
                    }
                }.padding(14)
            }.id("scopes")

            Text("命令").font(.system(size: 15, weight: .medium)).padding(.leading, 14).padding(.top, 10)
            surface {
                VStack(spacing: 0) {
                    unavailableCommand("管理自动退出", icon: "app.badge.clock", color: .gray)
                    Divider().opacity(0.4)
                    unavailableCommand("卸载应用程序", icon: "trash.square.fill", color: .red)
                }.padding(.horizontal, 14)
            }
            HStack {
                Text("应用程序").font(.system(size: 15, weight: .medium))
                Spacer()
                SettingsSearchField(text: $filter, placeholder: "筛选应用…").frame(width: 170, height: 24)
            }.padding(.horizontal, 14).padding(.top, 10)
            surface {
                LazyVStack(spacing: 0) {
                    ForEach(visibleApplications) { item in
                        ApplicationPreferenceRow(
                            model: model, item: item,
                            alias: model.aliases[item.id] ?? "",
                            shortcut: model.bindings["app:" + item.id],
                            enabled: !model.excluded.contains(item.id),
                            favorite: model.favorites.contains(item.id),
                            showsDivider: item.id != visibleApplications.last?.id
                        ).equatable()
                    }
                    if visibleApplications.isEmpty { Text("没有匹配的应用").foregroundStyle(.secondary).padding(24) }
                }
            }.id("favorites")
            HStack {
                Text(model.scanStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新", systemImage: "arrow.clockwise") { model.discovery.refresh() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 14)
        }.font(.system(size: 15))
            .onReceive(model.$apps.combineLatest(model.$excluded)) { apps, excluded in
                rebuildCatalog(apps: apps, excluded: excluded)
            }
            .onChange(of: filter) { _, value in updateFilter(value) }
    }

    private func rebuildCatalog(apps: [URL], excluded: Set<String>) {
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
        guard updated != catalog else { return }
        catalog = updated
        updateFilter(filter)
    }

    private func updateFilter(_ query: String) {
        visibleApplications = query.isEmpty ? catalog : catalog.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.filename.localizedCaseInsensitiveContains(query)
        }
    }

    private func caption(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.medium)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func surface<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading)
            .modifier(SettingsSurface())
    }
    private func unavailableCommand(_ name: String, icon: String, color: Color) -> some View {
        CommandSettingsRow(title: name, alias: .constant(""), shortcut: nil,
                           isEnabled: .constant(false), setShortcut: { _ in },
                           icon: { Image(systemName: icon).font(VisualStyle.actionSymbol).foregroundStyle(color) },
                           available: false)
            .help("此命令尚未实现，不能启用或设置快捷键。")
    }
}

private struct ScopeRow: View {
    let path: String
    let remove: () -> Void
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder").font(VisualStyle.actionSymbol).frame(width: 18)
            Text((path as NSString).abbreviatingWithTildeInPath).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: remove) { Image(systemName: "minus.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain).opacity(hovering ? 1 : 0).help("移除此搜索范围").accessibilityLabel("移除 \(path)")
        }.frame(height: 35).contentShape(Rectangle()).onHover { hovering = $0 }.help(path)
    }
}
private struct ApplicationPreferenceItem: Identifiable, Equatable {
    let id: String
    let url: URL
    let title: String
    let filename: String
}

private struct ApplicationPreferenceRow: View, Equatable {
    let model: Model
    let item: ApplicationPreferenceItem
    let alias: String
    let shortcut: Shortcut?
    let enabled: Bool
    let favorite: Bool
    let showsDivider: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.item == rhs.item && lhs.alias == rhs.alias
            && lhs.shortcut == rhs.shortcut && lhs.enabled == rhs.enabled
            && lhs.favorite == rhs.favorite && lhs.showsDivider == rhs.showsDivider
    }

    var body: some View {
        VStack(spacing: 0) {
            CommandSettingsRow(
                title: item.title,
                alias: Binding(get: { model.aliases[item.id] ?? "" }, set: { model.setAlias(item.id, value: $0) }),
                shortcut: shortcut,
                isEnabled: Binding(get: { !model.excluded.contains(item.id) }, set: { value in
                    if value { model.excluded.remove(item.id) } else { model.excluded.insert(item.id) }
                    model.reloadCatalog()
                }),
                setShortcut: { model.setShortcut("app:" + item.id, value: $0) },
                icon: { SettingsApplicationIcon(path: item.id) }
            )
            .padding(.horizontal, 14)
            .help(item.id)
            .contextMenu {
                Button(favorite ? "取消收藏" : "加入收藏") { model.toggleFavorite(item.id) }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            }
            if showsDivider { Divider().opacity(0.4).padding(.horizontal, 14) }
        }
    }
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
