import SwiftUI
import AppKit

struct ApplicationPreferences: View {
    @ObservedObject var model: Model
    @State private var filter = ""
    @Environment(\.colorScheme) private var scheme
    private var applications: [URL] {
        let paths = Set(model.apps.map(\.path)).union(model.excluded.filter { FileManager.default.fileExists(atPath: $0) })
        return paths.map { URL(fileURLWithPath: $0) }.filter {
            filter.isEmpty || model.appName($0).localizedCaseInsensitiveContains(filter) || $0.lastPathComponent.localizedCaseInsensitiveContains(filter)
        }.sorted { model.appName($0).localizedStandardCompare(model.appName($1)) == .orderedAscending }
    }
    var body: some View {
        let visibleApplications = applications
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
                    ForEach(visibleApplications, id: \.path) { url in
                        ApplicationPreferenceRow(model: model, url: url)
                        if url != visibleApplications.last { Divider().opacity(0.4).padding(.horizontal, 14) }
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
private struct ApplicationPreferenceRow: View {
    @ObservedObject var model: Model
    let url: URL
    var body: some View {
        CommandSettingsRow(
            title: model.appName(url),
            alias: Binding(get: { model.aliases[url.path] ?? "" }, set: { model.setAlias(url.path, value: $0) }),
            shortcut: model.bindings["app:" + url.path],
            isEnabled: Binding(get: { !model.excluded.contains(url.path) }, set: { enabled in
                if enabled { model.excluded.remove(url.path) } else { model.excluded.insert(url.path) }
                model.reloadCatalog()
            }),
            setShortcut: { model.setShortcut("app:" + url.path, value: $0) },
            icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
        )
        .padding(.horizontal, 14)
        .help(url.path)
        .contextMenu {
            Button(model.favorites.contains(url.path) ? "取消收藏" : "加入收藏") { model.toggleFavorite(url.path) }
            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
