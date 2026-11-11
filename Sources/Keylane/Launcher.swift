import SwiftUI
import AppKit
import KeylaneCore

private final class IconCache {
    static let shared = IconCache()
    private let icons = NSCache<NSString, NSImage>()
    private init() { icons.countLimit = 512 }

    func image(_ path: String) -> NSImage {
        let key = path as NSString
        if let image = icons.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(image, forKey: key)
        return image
    }
}
struct Launcher: View {
    @ObservedObject var model: Model
    @StateObject private var modifiers = LauncherModifiers()
    @State private var selection = 0
    @State private var selectedResultID: String?
    @State private var actions = false
    @State private var appMenu = false
    @State private var actionQuery = ""
    @State private var actionSelection = 0
    @State private var focusToken = 0
    @State private var submenu = false
    @State private var argumentTarget: Entry?
    @State private var argumentText = ""
    @FocusState private var argumentsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var rows: [Entry] {
        if model.tab == "Files" { return model.fileResults.map { file in Entry(id: file.url.path, name: file.name, detail: "File", symbol: "doc", action: { model.openFile(file.url) }) } }
        return model.commands
    }
    var body: some View {
        let results = model.tab == "Commands" || model.tab == "Files" ? rows : []
        ZStack {
            if let target = argumentTarget { argumentEditor(target).padding(.bottom, 52) }
            else if model.isCompact { Color.clear }
            else {
                if model.tab == "Files" {
                    ResultDetailLayout {
                        commandList(results)
                    } detail: {
                        FileSearchDetail(url: results.indices.contains(selection) ? URL(fileURLWithPath: results[selection].id) : nil)
                            .padding(.top, 61).padding(.bottom, 52)
                    }
                } else if model.tab == "Clipboard" { ClipboardHistoryView(controller:model.clipboard,query:model.query) }
                else if model.tab == "Commands" { commandList(results) }
                else { moduleContent.padding(.top, 61).padding(.bottom, 52) }
            }
            if !model.isCompact { VStack(spacing: 0) {
                if argumentTarget == nil {
                    ChromeBlur().frame(height: 88)
                        .mask(LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.7), location: 0.48), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                }
                Spacer(minLength: 0)
                if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red).padding(8).background(.regularMaterial) }
                ChromeBlur().frame(height: 78)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.5), .init(color: .black.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom))
            }.allowsHitTesting(false) }
            // Keep the search field interactive while the blur's full-window spacer is inert.
            if argumentTarget == nil { VStack(spacing: 0) {
                searchBar
                if model.isCompact && model.compactFavorites && !model.favorites.isEmpty { compactFavoritesBar }
                Spacer(minLength: 0)
            } }
            if actions || appMenu { Color.clear.contentShape(Rectangle()).onTapGesture { closeMenus() } }
            if !model.isCompact { footer.frame(maxHeight: .infinity, alignment: .bottom) }
        }
        .frame(width: 760, height: model.launcherHeight)
        .scaleEffect(model.interfaceScale)
        .frame(width: 760 * model.interfaceScale, height: model.launcherHeight * model.interfaceScale)
        .scrollIndicators(.visible, axes: .vertical)

        .background { if reduceTransparency { Color(nsColor: .windowBackgroundColor) } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: actions)
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: appMenu)
        .background {
            Button("") { toggleMenu(application: false) }.keyboardShortcut("k", modifiers: .command).hidden().accessibilityHidden(true)
            Button("") { closeMenus(); model.openSettings() }.keyboardShortcut(",", modifiers: .command).hidden().accessibilityHidden(true)
            Button("") { if model.tab == "Clipboard" { (NSApp.delegate as? Delegate)?.pasteClipboard() } }.keyboardShortcut(.return, modifiers: .command).hidden().accessibilityHidden(true)
            ForEach(0..<min(10, results.count), id: \.self) { index in
                Button("") {
                    guard model.tab == "Commands" || model.tab == "Files" else { return }
                    let currentResults = rows
                    guard currentResults.indices.contains(index) else { return }
                    selection = index
                    selectedResultID = currentResults[index].id
                    model.perform(currentResults[index])
                }.keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: .command).hidden().accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .preferredColorScheme(model.colorScheme)
        .onAppear { focusToken += 1; modifiers.start() }
        .onChange(of: model.windowMode) { _, _ in focusToken += 1 }
        .onDisappear { modifiers.stop() }
        .onExitCommand { if !SearchField.isComposing { escape() } }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShown)) { _ in modifiers.start(); closeMenus(); if model.searchesFilesHere { model.searchFiles() } }
        .onReceive(NotificationCenter.default.publisher(for: .launcherHidden)) { _ in modifiers.stop(); actions = false; appMenu = false; actionQuery = ""; model.fileSearch.cancel() }
        .onChange(of: model.query) { _, _ in selection = 0; selectedResultID = nil; if model.searchesFilesHere { model.searchFiles() }; if model.tab == "Clipboard" { model.clipboard.search(model.query) } }
        .onChange(of: model.fileSearch.options.enabled) { _, _ in
            if model.searchesFilesHere { model.searchFiles() } else { model.fileSearch.cancel(); model.fileResults = [] }
        }
        .onChange(of: model.fileSearch.options.searchFromLauncher) { _, _ in
            if model.tab == "Commands" { if model.searchesFilesHere { model.searchFiles() } else { model.fileSearch.cancel(); model.fileResults = [] } }
        }
        .onChange(of: model.fileResults) { previous, current in
            guard model.tab == "Files" || model.tab == "Commands" else { return }
            let oldID = selectedResultID ?? (model.tab == "Files" && previous.indices.contains(selection) ? previous[selection].id : nil)
            let results = rows
            if let oldID, let index = results.firstIndex(where: { $0.id == oldID }) { selection = index }
            else { selection = min(selection,max(0,results.count-1)) }
        }
        .onChange(of: model.tab) { _, _ in model.fileSearch.cancel(); model.query = ""; selection = 0; selectedResultID = nil; focusToken += 1; if model.searchesFilesHere { model.searchFiles() }; if model.tab == "Clipboard" { model.clipboard.search("") } }
    }
    private func moveSelection(_ delta: Int) {
        if model.isCompact { model.compactExpanded = true; return }
        if actions || appMenu { actionSelection = NavigationBounds.move(actionSelection, by: delta, count: filteredMenu(applicationMenu: appMenu).count) }
        else if model.tab == "Clipboard" { model.clipboard.move(delta) }
        else if model.tab == "Commands" || model.tab == "Files" {
            let results = rows
            selection = NavigationBounds.move(selection, by: delta, count: results.count)
            selectedResultID = results.indices.contains(selection) ? results[selection].id : nil
        }
    }
    private func escape() {
        if submenu { submenu = false; actionQuery = ""; actionSelection = 0; focusToken += 1; return }
        if argumentTarget != nil { argumentTarget = nil; focusToken += 1; return }
        if actions || appMenu { closeMenus() }
        else if model.tab != "Commands" { model.tab = "Commands" }
        else { (NSApp.delegate as? Delegate)?.hideLauncher() }
    }

    private var compactFavoritesBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(model.commands.filter { model.favorites.contains($0.id) }) { row in
                    Button { model.perform(row) } label: {
                        Group {
                            if row.id.hasSuffix(".app") { Image(nsImage: IconCache.shared.image(row.id)).resizable() }
                            else { Image(systemName: row.symbol).resizable().scaledToFit() }
                        }.frame(width: 26, height: 26)
                    }.buttonStyle(.plain).help(row.name).accessibilityLabel(row.name)
                }
            }.padding(.horizontal, 19).frame(height: 42)
        }.scrollIndicators(.hidden)
    }
    private var searchBar: some View {
        HStack(spacing: 12) {
            if model.tab != "Commands" { backButton { model.tab = "Commands" } }
            if model.tab == "Commands" { Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .regular)).foregroundStyle(.secondary) }
            SearchField(text: $model.query, placeholder: model.tab == "Commands" ? "搜索应用、文件和命令…" : moduleTitle, focusToken: focusToken, wantsFocus: !actions && !appMenu, navigation: model.navigation, submit: { run() }, move: moveSelection, escape: escape).frame(height: 30)
        }.padding(.horizontal, model.tab == "Commands" ? 19 : 8).frame(height: 61)
    }
    private func commandList(_ results: [Entry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if results.isEmpty {
                        VStack(spacing: 10) { Image(systemName: "magnifyingglass").font(.system(size: 26)); Text(model.tab == "Files" && model.query.isEmpty ? "搜索文件" : "没有匹配结果").font(.system(size: 14)); Text(model.tab == "Files" ? model.fileSearchStatus : "试试应用名称、拼音或计算表达式").font(.caption); if model.tab == "Files" { Button("选择搜索文件夹…", systemImage: "folder") { model.chooseFileSearchFolder(returnToLauncher: true) }.buttonStyle(.glass).padding(.top, 8) } }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                        if index == 0 { sectionHeader(model.tab == "Files" ? model.fileSearchStatus : (model.query.isEmpty ? "建议" : "搜索结果")) }
                        if index == 5 && model.query.isEmpty && model.tab == "Commands" { sectionHeader("其他") }
                        Button { selection = index; selectedResultID = row.id; if model.tab != "Files" { model.perform(row) } } label: { if model.tab == "Files" { fileResultRow(row, index: index) } else { resultRow(row, index: index) } }.buttonStyle(.plain).id(row.id)
                    }
                }.padding(.horizontal, 8).padding(.bottom, 6)
            }.scrollIndicators(.visible, axes: .vertical)
            .contentMargins(.top, 61, for: .scrollContent)
            .contentMargins(.bottom, 52, for: .scrollContent)
            .contentMargins(.bottom, 52, for: .scrollIndicators)
            .contentMargins(.top, 61, for: .scrollIndicators)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black.opacity(0.2), location: 0.08),
                .init(color: .black, location: 0.19), .init(color: .black, location: 0.80),
                .init(color: .black.opacity(0.2), location: 0.96), .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
            .onChange(of: selection) { _, value in let results = rows; if results.indices.contains(value) { proxy.scrollTo(results[value].id) } }
            .onChange(of: model.query) { _, _ in if let first = rows.first { proxy.scrollTo(first.id, anchor: .top) } }
        }
    }
    private func sectionHeader(_ title: String) -> some View { Text(title).font(VisualStyle.sectionText).foregroundStyle(.secondary).padding(.leading, 14).padding(.top, 5).padding(.bottom, 5).frame(height: 26) }
    private func fileResultRow(_ row: Entry, index: Int) -> some View {
        let url = URL(fileURLWithPath: row.id)
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return HStack(spacing: 10) {
            Image(nsImage: IconCache.shared.image(row.id)).resizable()
                .interpolation(.high).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                HighlightedResultText(text: row.name, query: model.query)
                    .font(VisualStyle.rowText).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isFolder {
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).frame(height: isFolder ? 48 : 40)
        .background(index == selection ? Color.primary.opacity(contrast == .increased ? 0.22 : 0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle()).help(url.path)
    }
    private func resultRow(_ row: Entry, index: Int) -> some View {
        HStack(spacing: 13) {
            Group {
                if row.id.hasSuffix(".app") || row.detail == "File" { Image(nsImage: IconCache.shared.image(row.id)).resizable().interpolation(.high) }
                else { Image(systemName: row.symbol).font(.system(size: 21, weight: .regular)).foregroundStyle(iconColor(row.id)).frame(width: 26, height: 26) }
            }.frame(width: 26, height: 26)
                .overlay(alignment: .bottomLeading) { if model.runningPaths.contains(row.id) { Circle().fill(.green).frame(width: 5, height: 5).offset(x: -1, y: 3).accessibilityLabel("正在运行") } }
            HighlightedResultText(text: row.name, query: model.query).font(VisualStyle.rowText).lineLimit(1).truncationMode(.middle)
            if row.detail == "File" && model.tab != "Files" { Text(URL(fileURLWithPath: row.id).deletingLastPathComponent().path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if row.detail == "AI" { Text("AI").font(.system(size:12)).foregroundStyle(.secondary) }
            if let alias = model.aliases[row.id], !alias.isEmpty { Text(alias).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: RoundedRectangle(cornerRadius: 4)) }
            Spacer(minLength: 8)
            resultAttributeBadge(row, index: index)
        }.padding(.horizontal, 13).frame(height: 40)
        .background(index == selection ? Color.primary.opacity(contrast == .increased ? 0.22 : 0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }
    private func resultAttributeBadge(_ row: Entry, index: Int) -> some View {
        let showingShortcut = modifiers.commandHeld && index < 10
        return Text(resultAttribute(row))
            .font(.system(size:14,weight:.regular)).foregroundStyle(.secondary).lineLimit(1)
            .frame(width:84,alignment:.trailing)
            // Keep the original attribute in the hierarchy underneath the hint.
            .blur(radius:showingShortcut && !reduceTransparency ? 1.2 : 0)
            .overlay(alignment:.trailing) {
                if showingShortcut {
                    Keycap(text:String((index+1) % 10))
                        .accessibilityElement(children:.ignore).accessibilityLabel("Command + \((index+1) % 10)")
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration:0.16),value:showingShortcut)
    }
    private func resultAttribute(_ row: Entry) -> String {
        if row.detail == "Application" || row.id.hasSuffix(".app") { return "应用" }
        if row.detail == "File" { return "文件" }
        if row.id == "calculator" { return "计算结果" }
        return "命令"
    }
    private func iconColor(_ id: String) -> Color { switch id { case "notes": return .yellow; case "clipboard": return .orange; case "screenshot": return .purple; case "quicklink": return .blue; default: return .primary.opacity(0.8) } }
    private var footer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if model.tab == "Files" || model.tab == "Clipboard" {
                    SecondaryPageBadge(title:model.tab == "Files" ? "文件搜索" : "剪贴板历史",symbol:model.tab == "Files" ? "doc.text.magnifyingglass" : "list.clipboard")
                } else {
                    expandingControl(application: true)
                }
                Spacer(minLength: 8)
                expandingControl(application: false)
            }
        }.padding(.horizontal, 8).padding(.bottom, 6)
    }
    private func expandingControl(application: Bool) -> some View {
        let open = application ? appMenu : actions
        let alignment: Alignment = application ? .bottomLeading : .bottomTrailing
        let count = filteredMenu(applicationMenu: application).count
        let menuHeight = CGFloat(87 + (count == 0 ? 48 : count * 39))
        return ZStack(alignment: alignment) {
            if open {
                menuPanel(applicationMenu: application)
                    .frame(width: 345, height: menuHeight, alignment: .bottom)
                    .transition(.opacity)
            } else if application {
                NativeHoverButton(title: "Keylane 菜单", action: { toggleMenu(application: true) }) {
                    Image(systemName: "text.menu").font(.system(size: 16)).frame(width: 36, height: 36)
                }.frame(width: 36, height: 36).clipShape(Circle()).transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    NativeHoverButton(title: primaryTitle, action: { run() }) { HStack(spacing: 7) { Text(primaryTitle); Keycap(text: "↩") } }.frame(maxWidth: .infinity).frame(height: 28)
                    NativeHoverButton(title: "操作", action: { toggleMenu(application: false) }) { HStack(spacing: 7) { Text("操作"); HStack(spacing: 3) { Keycap(text: "⌘"); Keycap(text: "K") } } }.frame(maxWidth: .infinity).frame(height: 28)
                }.font(.system(size: 13, weight: .medium)).padding(4).frame(width: 196, height: 36).transition(.opacity)
            }
        }
        // The container remains in the same hierarchy. Only its size changes; its bottom
        // corner stays fixed. No matched-position or automatic glass transition can slide it.
        .frame(width: open ? 345 : (application ? 36 : 196), height: open ? menuHeight : 36, alignment: alignment)
        .clipShape(RoundedRectangle(cornerRadius: open ? 21 : 18))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: open ? 21 : 18))
        .glassEffectTransition(.identity)
    }
    private struct MenuAction: Identifiable {
        let id: String
        let title: String
        let icon: String
        var keys: [String] = []
        let perform: () -> Void
    }
    private var selectedEntry: Entry? {
        let results = rows
        return results.indices.contains(selection) ? results[selection] : nil
    }
    private func menuItems(applicationMenu: Bool) -> [MenuAction] {
        if applicationMenu {
            return [
                MenuAction(id: "about", title: "关于 Keylane", icon: "app.badge", perform: { model.openSettings(page: "about") }),
                MenuAction(id: "settings", title: "设置…", icon: "gearshape", keys: ["⌘", ","], perform: { model.openSettings() }),
                MenuAction(id: "clipboard", title: "剪贴板历史", icon: "list.clipboard", perform: { navigate("Clipboard") }),
                MenuAction(id: "notes", title: "便笺", icon: "note", perform: { navigate("Notes") }),
                MenuAction(id: "hide", title: "隐藏 Keylane", icon: "rectangle.compress.vertical", keys: ["esc"], perform: { (NSApp.delegate as? Delegate)?.hideLauncher() }),
                MenuAction(id: "quit", title: "退出 Keylane", icon: "rectangle.portrait.and.arrow.right", perform: { NSApp.terminate(nil) })
            ]
        }
        if model.tab == "Clipboard" {
            guard let item = model.clipboard.items.first(where: { $0.id == model.clipboard.selectedID }) else { return [] }
            var items = [MenuAction(id: "copy-clip", title: "复制", icon: "doc.on.doc", keys: ["↩"], perform: { model.clipboard.copySelected() }),
                MenuAction(id: "copy-plain-clip", title: "复制为纯文本", icon: "text.alignleft", perform: { model.clipboard.copySelected(plainText:true) }),
                MenuAction(id: "paste-plain-clip", title: "粘贴为纯文本", icon: "text.insert", perform: { (NSApp.delegate as? Delegate)?.pasteClipboard(plainText:true) }),
                MenuAction(id: "paste-clip", title: "粘贴到上个应用", icon: "doc.on.clipboard", keys: ["⌘", "↩"], perform: { (NSApp.delegate as? Delegate)?.pasteClipboard() }),
                MenuAction(id: "pin-clip", title: item.pinned ? "取消置顶" : "置顶", icon: "pin", perform: { model.clipboard.pinSelected() })]
            if item.kind == .image { items.append(MenuAction(id: "ocr-clip", title: "识别图片文字", icon: "text.viewfinder", perform: { model.clipboard.recognizeSelected() })) }
            items.append(MenuAction(id: "delete-clip", title: "删除记录", icon: "trash", perform: { model.clipboard.removeSelected() }))
            return items
        }
        guard let row = selectedEntry else { return [] }
        var result = [MenuAction(id: "open", title: row.detail == "File" ? "打开文件" : (row.id.hasSuffix(".app") ? "打开应用程序" : "执行命令"), icon: "return", keys: ["↩"], perform: { model.perform(row) })]
        if row.id.hasSuffix(".app") {
            let url = URL(fileURLWithPath: row.id)
            if submenu {
                return [MenuAction(id: "back", title: "返回", icon: "chevron.left", perform: { actions = true; submenu = false; focusToken += 1 }),
                    MenuAction(id: "reveal", title: "在 Finder 中显示", icon: "folder", perform: { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                    MenuAction(id: "contents", title: "显示包内容", icon: "shippingbox", perform: { NSWorkspace.shared.open(url.appendingPathComponent("Contents")) }),
                    MenuAction(id: "path", title: "复制路径", icon: "doc.on.doc", perform: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) })]
            }
            result += [
                MenuAction(id: "finder", title: "Finder 操作", icon: "folder", keys: ["›"], perform: { actions = true; appMenu = false; submenu = true; actionQuery = ""; actionSelection = 0; focusToken += 1 }),
                MenuAction(id: "arguments", title: "使用参数启动…", icon: "terminal", perform: { argumentTarget = row; argumentText = "" }),
                MenuAction(id: "configure", title: "配置别名和快捷键…", icon: "keyboard", perform: { model.openSettings(page: "applications") })
            ]
        }
        if row.detail == "File" {
            let url = URL(fileURLWithPath: row.id)
            result += [
                MenuAction(id: "preview", title: "快速查看", icon: "eye", perform: { if FileManager.default.fileExists(atPath: url.path) { FilePreview.shared.show(url) } else { model.error = "文件已移走或删除。"; model.searchFiles() } }),
                MenuAction(id: "open-with-file", title: "打开方式…", icon: "app", perform: { FileActionsWindow.shared.show(url,page:"open") }),
                MenuAction(id: "share-file", title: "分享…", icon: "square.and.arrow.up", perform: { FileActionsWindow.shared.show(url,page:"share") }),
                MenuAction(id: "ask-file", title: "询问此文件…", icon: "sparkles", perform: { model.fileAI.present([url]) }),
                MenuAction(id: "reveal-file", title: "在 Finder 中显示", icon: "folder", perform: { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
                MenuAction(id: "copy-file-path", title: "复制路径", icon: "doc.on.doc", perform: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string) })
            ]
        }
        result.append(MenuAction(id: "favorite", title: model.favorites.contains(row.id) ? "取消收藏" : "加入收藏", icon: model.favorites.contains(row.id) ? "star.fill" : "star", perform: { model.toggleFavorite(row.id) }))
        return result
    }
    private func filteredMenu(applicationMenu: Bool) -> [MenuAction] { menuItems(applicationMenu: applicationMenu).filter { actionQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(actionQuery) } }
    private func menuPanel(applicationMenu: Bool) -> some View {
        let items = filteredMenu(applicationMenu: applicationMenu)
        return VStack(alignment: .leading, spacing: 0) {
            Text(applicationMenu ? "Keylane " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") : (model.tab == "Clipboard" ? "剪贴板操作" : (selectedEntry?.name ?? "操作")) + (submenu ? " › Finder" : "")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 8)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { closeMenus(); item.perform() } label: {
                    HStack(spacing: VisualStyle.actionSpacing) { Image(systemName: item.icon).font(VisualStyle.actionSymbol).symbolRenderingMode(.monochrome).frame(width: VisualStyle.actionIconWidth, height: 20); Text(item.title).font(VisualStyle.rowText); Spacer(); HStack(spacing: 3) { ForEach(Array(item.keys.enumerated()), id: \.offset) { _, key in Keycap(text: key) } } }.padding(.horizontal, 11).frame(height: 39).background(index == actionSelection ? Color.primary.opacity(contrast == .increased ? 0.24 : 0.12) : Color.clear, in: RoundedRectangle(cornerRadius: VisualStyle.selectionRadius))
                }.buttonStyle(.plain).padding(.horizontal, 8).onHover { inside in if inside { actionSelection = index } }
            }
            if items.isEmpty { Text("没有匹配的操作").font(.caption).foregroundStyle(.secondary).padding(16) }
            Divider().padding(.top, 9)
            SearchField(text: $actionQuery, placeholder: "搜索操作…", focusToken: focusToken, wantsFocus: actions || appMenu, fontSize: 14, navigation: model.navigation, submit: {
                if items.indices.contains(actionSelection) { let action = items[actionSelection]; closeMenus(); action.perform() }
            }, move: moveSelection, escape: escape, back: { escape() }, forward: {
                if items.indices.contains(actionSelection), items[actionSelection].id == "finder" { let item = items[actionSelection]; closeMenus(); item.perform() }
            }).frame(height: 22).padding(.horizontal, 16).padding(.vertical, 10).onChange(of: actionQuery) { _, _ in actionSelection = 0 }
        }.frame(width: 345)
    }
    private func toggleMenu(application: Bool) {
        model.compactExpanded = true
        let open = application ? !appMenu : !actions
        submenu = false; actions = !application && open; appMenu = application && open; actionQuery = ""; actionSelection = 0; focusToken += 1
    }
    private func closeMenus() { submenu = false; actions = false; appMenu = false; actionQuery = ""; focusToken += 1 }
    private var moduleTitle: String { switch model.tab { case "Notes": return "便笺"; case "Clipboard": return "搜索剪贴板历史…"; case "Files": return "搜索文件…"; default: return "设置" } }
    private var primaryTitle: String { if argumentTarget != nil { return "启动新实例" }; if model.tab == "Clipboard" { return model.clipboard.primaryAction == "paste" ? "粘贴" : "复制" }; return model.tab == "Commands" || model.tab == "Files" ? "打开" : "返回" }
    private func argumentEditor(_ target: Entry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { backButton { argumentTarget = nil; focusToken += 1 }; Text(target.name).font(.title2.weight(.semibold)) }
            Text("启动一个新实例，并传入以下参数。参数是否生效取决于目标应用；不会通过 Shell 执行。").foregroundStyle(.secondary)
            TextField("例如：--profile \"Work Profile\"", text: $argumentText).textFieldStyle(.roundedBorder).focused($argumentsFocused).onSubmit { run() }
            if let arguments = try? ArgumentParser.parse(argumentText) { Text(arguments.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            Spacer()
        }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity).task { await Task.yield(); guard !Task.isCancelled else { return }; argumentsFocused = true }
    }
    @ViewBuilder private var moduleContent: some View {
        switch model.tab {
        case "Notes": HSplitView {
            VStack { Button("新建便笺", systemImage: "plus") { model.newNote() }.padding(10); List(model.savedNotes.filter { model.query.isEmpty || $0.body.localizedCaseInsensitiveContains(model.query) }) { note in Button(note.title.isEmpty ? "未命名" : note.title) { model.noteID = note.id; model.notes = note.body }.buttonStyle(.plain) } }.frame(minWidth: 160, idealWidth: 190, maxWidth: 230)
            TextEditor(text: $model.notes).font(.system(size: 15)).scrollContentBackground(.hidden).padding(12)
        }
        case "Clipboard": ClipboardHistoryView(controller:model.clipboard,query:model.query)
        default: Form {
            Section("剪贴板") { Button("剪贴板设置…") { model.openSettings(page: "clipboard") } }
            Section("快捷链接") { TextField("网址", text: $model.link) }
            Section("备份") { Button("导出便笺…") { model.exportData() } }
            Section("键盘") { LabeledContent("显示 / 隐藏") { Keycaps(keys: model.bindings["launcher"]?.keycaps ?? []) }; HStack { Keycaps(keys: ["↑", "↓"]); Text("选择"); Keycap(text: "↩"); Text("打开"); Keycaps(keys: ["⌘", "K"]); Text("操作"); Keycap(text: "Esc"); Text("返回") } }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
        }
    }
    private func navigate(_ tab: String) { closeMenus(); model.tab = tab }
    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "chevron.backward").font(.system(size: 15, weight: .medium)).frame(width: 24, height: 26) }
            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large).help("返回").accessibilityLabel("返回")
    }
    private func run() {
        if (model.tab == "Files" || selectedEntry?.detail == "File"), model.fileSearch.isSearching { return }
        if let target = argumentTarget { do { let args = try ArgumentParser.parse(argumentText); model.launch(URL(fileURLWithPath: target.id), arguments: args) } catch { model.error = "参数引号或转义未完成。" }; return }
        if actions || appMenu { let items = filteredMenu(applicationMenu: appMenu); if items.indices.contains(actionSelection) { let item = items[actionSelection]; closeMenus(); item.perform() }; return }
        if model.tab == "Clipboard" { if model.clipboard.primaryAction == "paste" { (NSApp.delegate as? Delegate)?.pasteClipboard() } else { model.clipboard.copySelected() }; return }
        if model.tab != "Commands" && model.tab != "Files" { model.tab = "Commands"; return }; let list = rows; if list.indices.contains(selection) { model.perform(list[selection]) } }
}

/// Samples the scrolling content in this window, rather than the desktop behind it.
private struct ChromeBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .headerView
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
