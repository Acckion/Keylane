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
    @State private var fileType = "all"
    @State private var filterOpen = false
    @State private var mainSearchQuery = ""
    @State private var mainSearchSelection = 0
    @State private var mainSearchExpanded = false
    @State private var pendingMainSelection: Int?
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
        if model.navigationMode != nil || ["Calendar", "Contacts", "Dictionary", "Emoji"].contains(model.tab) { return [] }
        if model.tab == "Files" { return model.fileResults.filter { FileResultTypeFilter.includes($0.url, selection: fileType) }.map { file in Entry(id: file.url.path, name: file.name, detail: "File", symbol: "doc", action: { model.openFile(file.url) }) } }
        let results = model.commands
        // Keep file results together while preserving the ranking within each section.
        return results.filter { $0.detail != "File" } + results.filter { $0.detail == "File" }
    }
    var body: some View {
        let results = ["Commands", "Files"].contains(model.tab) ? rows : []
        ZStack(alignment: .top) {
            if let target = argumentTarget { argumentEditor(target).padding(.bottom, 52) }
            else if model.isCompact && model.launcherHeight <= model.launcherHeight + 0.5 { Color.clear }
            else {
                if model.tab == "Files" {
                    ResultDetailLayout {
                        commandList(results)
                    } detail: {
                        FileSearchDetail(url: results.indices.contains(selection) ? URL(fileURLWithPath: results[selection].id) : nil)
                    }
                } else if model.tab == "Calendar" { CalendarPage(controller: model.calendar) }
                else if model.tab == "Contacts" { ContactsPage(controller: model.contacts) }
                else if model.tab == "Dictionary" { DictionaryPage(controller: model.dictionary) }
                else if let mode = model.navigationMode {
                    NavigationPage(controller: model.systemNavigation, mode: mode,
                                   requestAccess: model.requestKeyboardAccess, reload: reloadNavigation) { runNavigation($0, mode: mode) }
                }
                else if model.tab == "Emoji" { EmojiSearchPage(controller: model.emoji) { useEmoji($0, paste: true) } }
                else if model.tab == "Clipboard" { ClipboardHistoryView(controller:model.clipboard,query:model.query) }
                else if model.tab == "Screenshots" {
                    ScreenshotLibraryPage(library: model.screenshots, query: model.query, chooseFolders: chooseScreenshotFolders)
                }
                else if model.tab == "Commands" { commandList(results).frame(height: 470, alignment: .top) }
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
            if actions || appMenu || filterOpen { Color.clear.contentShape(Rectangle()).onTapGesture { closeMenus() } }
            if !model.isCompact { footer.frame(maxHeight: .infinity, alignment: .bottom) }
            if argumentTarget == nil && showsTypeFilter {
                typeFilter.frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(VisualStyle.launcherEdgeInset)
            }
        }
        .frame(width: 760, height: model.launcherHeight, alignment: .top)
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
                Button("") { if model.tab == "Commands" || model.tab == "Files" { let results = rows; guard results.indices.contains(index) else { return }; selection = index; model.perform(results[index]) } }.keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: .command).hidden().accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius, style: .continuous))
        .preferredColorScheme(model.colorScheme)
        .onAppear { focusToken += 1; modifiers.start() }
        .onChange(of: model.windowMode) { _, _ in focusToken += 1 }
        .onDisappear { modifiers.stop() }
        .onExitCommand { if !SearchField.isComposing { escape() } }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShown)) { _ in modifiers.start(); closeMenus(); if model.tab == "Screenshots" { model.screenshots.refresh() }; model.systemShortcuts.refresh(); if model.tab == "Contacts" { model.contacts.start() }; if model.navigationMode != nil { reloadNavigation() }; if model.searchesFilesHere { model.searchFiles() } }
        .onReceive(NotificationCenter.default.publisher(for: .launcherHidden)) { _ in modifiers.stop(); model.screenshots.stop(); actions = false; appMenu = false; actionQuery = ""; model.fileSearch.cancel(); model.contacts.stop(); model.systemNavigation.stop() }
        .onChange(of: fileType) { _, _ in selection = 0; selectedResultID = nil; focusToken += 1 }
        .onChange(of: model.query) { _, _ in
            if model.tab == "Screenshots" { model.screenshots.search(model.query) }
            selection = pendingMainSelection ?? 0
            pendingMainSelection = nil
            selectedResultID = nil
            if model.searchesFilesHere { model.searchFiles() }
            if model.tab == "Clipboard" { model.clipboard.search(model.query) }
            if model.tab == "Calendar" { model.calendar.query = model.query }
            if model.tab == "Contacts" { model.contacts.query = model.query }
            if model.tab == "Dictionary" { model.dictionary.search(model.query) }
            if model.tab == "Emoji" { model.emoji.query = model.query }
            if model.navigationMode != nil { model.systemNavigation.query = model.query }
        }
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
        .onChange(of: model.tab) { previous, current in
            filterOpen = false
            model.fileSearch.cancel()
            if previous == "Commands" && current != "Commands" {
                mainSearchQuery = model.query
                mainSearchSelection = selection
                mainSearchExpanded = model.compactExpanded
            }
            if current == "Commands" {
                pendingMainSelection = model.query == mainSearchQuery ? nil : mainSearchSelection
                model.query = mainSearchQuery
                selection = mainSearchSelection
                model.compactExpanded = mainSearchExpanded
            } else {
                model.query = ""
                selection = 0
            }
            selectedResultID = nil
            focusToken += 1
            if model.searchesFilesHere { model.searchFiles() }
            if current == "Clipboard" { model.clipboard.search(model.query) }
            if previous == "Screenshots" { model.screenshots.stop() }
            if current == "Screenshots" {
                model.screenshots.search(model.query)
                model.screenshots.refresh()
            }
            if current == "Calendar" { model.calendar.query = model.query }
            if previous == "Contacts" { model.contacts.stop() }
            if current == "Contacts" { model.contacts.query = model.query; model.contacts.start() }
            if model.navigationMode != nil { reloadNavigation() }
            else if previous == "Windows" || previous == "MenuItems" { model.systemNavigation.stop() }
            if current == "Emoji" {
                model.emoji.query = model.query
                model.emoji.start()
            }
            if current == "Dictionary" {
                model.query = model.dictionary.initialTerm
                model.dictionary.search(model.query)
                model.dictionary.initialTerm = ""
            }
        }
    }
    private func moveSelection(_ delta: Int) {
        if model.isCompact { model.compactExpanded = true; return }
        if actions || appMenu { actionSelection = NavigationBounds.move(actionSelection, by: delta, count: filteredMenu(applicationMenu: appMenu).count) }
        else if model.tab == "Calendar" { model.calendar.move(delta) }
        else if model.tab == "Contacts" { model.contacts.move(delta) }
        else if model.tab == "Emoji" { model.emoji.move(delta, vertical: true) }
        else if model.navigationMode != nil { model.systemNavigation.move(delta) }
        else if model.tab == "Screenshots" { model.screenshots.move(delta * model.screenshots.columns) }
        else if model.tab == "Clipboard" { model.clipboard.move(delta) }
        else if model.tab == "Commands" || model.tab == "Files" { selection = NavigationBounds.move(selection, by: delta, count: rows.count); selectedResultID = rows.indices.contains(selection) ? rows[selection].id : nil }
    }
    private func escape() {
        if submenu { submenu = false; actionQuery = ""; actionSelection = 0; focusToken += 1; return }
        if argumentTarget != nil { argumentTarget = nil; focusToken += 1; return }
        if actions || appMenu || filterOpen { closeMenus() }
        else if model.tab != "Commands" { model.tab = "Commands" }
        else { (NSApp.delegate as? Delegate)?.hideLauncher() }
    }

    private var compactFavoritesBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(model.commands.filter { model.favorites.contains($0.id) }) { row in
                    Button { model.perform(row) } label: {
                        Group {
                            if row.detail == "Shortcut" { ShortcutArtwork(image: model.systemShortcuts.icon(forCommandID: row.id)) }
                            else if row.id.hasSuffix(".app") { Image(nsImage: IconCache.shared.image(row.id)).resizable() }
                            else { Image(systemName: row.symbol).resizable().scaledToFit() }
                        }.frame(width: 26, height: 26)
                    }.buttonStyle(.plain).help(row.name).accessibilityLabel(row.name)
                }
            }.padding(.horizontal, 19).frame(height: 42)
        }.scrollIndicators(.hidden)
    }
    private var showsTypeFilter: Bool { ["Files", "Clipboard", "Emoji"].contains(model.tab) }

    private var searchBar: some View {
        HStack(spacing: 12) {
            if model.tab != "Commands" { backButton { model.tab = "Commands" } }
            if model.tab == "Commands" { Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .regular)).foregroundStyle(.secondary) }
            SearchField(text: $model.query, placeholder: model.tab == "Commands" ? "搜索应用、文件和命令…" : moduleTitle, focusToken: focusToken, wantsFocus: !actions && !appMenu && !filterOpen, navigation: model.navigation, submit: { run() }, move: moveSelection, escape: escape,
                        back: model.tab == "Screenshots" ? { model.screenshots.move(-1) }
                            : model.tab == "Emoji" ? { model.emoji.move(-1, vertical: false) } : nil,
                        forward: model.tab == "Screenshots" ? { model.screenshots.move(1) }
                            : model.tab == "Emoji" ? { model.emoji.move(1, vertical: false) } : nil,
                        navigateWhileTyping: model.tab == "Emoji" || model.tab == "Screenshots")
                .frame(height: 30)
            if model.tab == "Screenshots" { ScreenshotFilterPicker(library: model.screenshots) }
            if model.tab == "Calendar" {
                CalendarDateNavigation(controller: model.calendar)
            } else if showsTypeFilter {
                Color.clear.frame(width: model.tab == "Emoji" ? 174 : 138, height: 36).accessibilityHidden(true)
            }
        }.padding(.horizontal, model.tab == "Commands" ? 19 : VisualStyle.launcherEdgeInset)
            .frame(height: model.tab == "Commands" ? 61 : VisualStyle.launcherControlDiameter + 2 * VisualStyle.launcherEdgeInset)
            .frame(height: 61, alignment: .top)
    }
    @ViewBuilder private var typeFilter: some View {
        if model.tab == "Files" {
            ResultTypeFilter(selection: $fileType, options: ResultFilterOption.files, open: $filterOpen)
        } else if model.tab == "Emoji" {
            ResultTypeFilter(selection: Binding(get: { model.emoji.category }, set: { model.emoji.category = $0 }),
                             options: EmojiCatalog.categories, open: $filterOpen, width: 174,
                             searchPlaceholder: EmojiCatalog.label("搜索分类…", "Search categories…"))
        } else {
            ResultTypeFilter(selection: Binding(get: { model.clipboard.kind }, set: { model.clipboard.kind = $0 }),
                             options: ResultFilterOption.clipboard, open: $filterOpen)
        }
    }
    private func commandList(_ results: [Entry]) -> some View {
        return ScrollViewReader { proxy in
            ResultListScrollView {
                    if results.isEmpty {
                        VStack(spacing: 10) { Image(systemName: "magnifyingglass").font(.system(size: 26)); Text(model.tab == "Files" && model.query.isEmpty ? "搜索文件" : "没有匹配结果").font(.system(size: 14)); Text(model.tab == "Files" ? model.fileSearchStatus : "试试应用名称、拼音或计算表达式").font(.caption); if model.tab == "Files" { Button("选择搜索文件夹…", systemImage: "folder") { model.chooseFileSearchFolder(returnToLauncher: true) }.buttonStyle(ContentActionButtonStyle()).padding(.top, 8) } }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                        if row.id == "calculator" {
                            sectionHeader("计算器")
                        } else if model.tab == "Files" {
                            if index == 0 { sectionHeader(model.fileSearchStatus) }
                        } else if row.detail == "File" {
                            if index == 0 || results[index - 1].detail != "File" { sectionHeader("文件") }
                        } else {
                            if index == 0 || results[index - 1].id == "calculator" {
                                sectionHeader(model.query.isEmpty ? "建议" : "搜索结果")
                            }
                            if index == 5 && model.query.isEmpty { sectionHeader("其他") }
                        }
                        Button {
                            selection = index
                            selectedResultID = row.id
                            if model.tab != "Files" { model.perform(row) }
                        } label: {
                            if row.id == "calculator" {
                                CalculatorResultCard(expression: model.query, result: row.name, selected: index == selection)
                            } else if model.tab == "Files" {
                                fileResultRow(row, index: index)
                            } else {
                                resultRow(row, index: index)
                            }
                        }.buttonStyle(.plain).id(row.id)
                    }
            }
            .onChange(of: selection) { _, value in let results = rows; if results.indices.contains(value) { proxy.scrollTo(results[value].id) } }
            .onChange(of: model.query) { _, _ in if let first = rows.first { proxy.scrollTo(first.id, anchor: .top) } }
        }
    }
    private func sectionHeader(_ title: String) -> some View { Text(title).font(VisualStyle.sectionText).foregroundStyle(.secondary).padding(.leading, 14).padding(.top, 5).padding(.bottom, 5).frame(height: 26) }
    private func fileResultRow(_ row: Entry, index: Int) -> some View {
        let url = URL(fileURLWithPath: row.id)
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return ResultListRow(selected: index == selection, height: isFolder ? 48 : 40) {
            Image(nsImage: IconCache.shared.image(row.id)).resizable().interpolation(.high)
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                HighlightedResultText(text: row.name, query: model.query)
                    .font(VisualStyle.rowText).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isFolder {
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
        }.help(url.path)
    }
    private func resultRow(_ row: Entry, index: Int) -> some View {
        HStack(spacing: 13) {
            Group {
                if row.detail == "Shortcut" { ShortcutArtwork(image: model.systemShortcuts.icon(forCommandID: row.id)) }
                else if row.id.hasSuffix(".app") || row.detail == "File" { Image(nsImage: IconCache.shared.image(row.id)).resizable().interpolation(.high) }
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
            .frame(width: row.detail == SystemSettingsCatalog.resultKind ? 112 : 84, alignment: .trailing)
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
        if row.detail == SystemSettingsCatalog.resultKind {
            return SystemSettingsCatalog.prefersChinese() ? "系统设置" : "System Settings"
        }
        if row.id == "calculator" { return "计算结果" }
        if row.detail == "Shortcut" { return "快捷指令" }
        return "命令"
    }
    private func iconColor(_ id: String) -> Color { switch id { case "notes": return .yellow; case "clipboard": return .orange; case "screenshot": return .purple; case "quicklink": return .blue; default: return .primary.opacity(0.8) } }
    private var footer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                expandingControl(application: true)
                Spacer(minLength: 8)
                expandingControl(application: false)
            }
        }.padding(.horizontal, VisualStyle.launcherEdgeInset).padding(.bottom, VisualStyle.launcherEdgeInset)
    }
    private func expandingControl(application: Bool) -> some View {
        let badges = ["Screenshots": ("截图管理", "viewfinder"), "Files": ("文件搜索", "doc.text.magnifyingglass"), "Clipboard": ("剪贴板历史", "list.clipboard"),
                      "Calendar": ("日历", "calendar"), "Contacts": ("联系人", "person.crop.circle"), "Dictionary": ("词典", "book.closed")]
        let badge = model.navigationMode.map { ($0.title, $0.symbol) } ??
            (model.tab == "Emoji" ? (emojiBadgeTitle, "face.smiling") : badges[model.tab])
        let secondary = badge != nil
        let badgeTitle = badge?.0 ?? ""
        let badgeSymbol = badge?.1 ?? ""
        let applicationWidth: CGFloat = secondary ? min(420, SecondaryPageBadge.width(for: badgeTitle)) : 36
        let actionWidth: CGFloat = model.tab == "Screenshots" || model.tab == "Emoji" || model.navigationMode != nil ? 258 : 196
        let open = application ? appMenu : actions
        let alignment: Alignment = application ? .bottomLeading : .bottomTrailing
        let count = filteredMenu(applicationMenu: application).count
        let menuHeight = CGFloat(87 + (count == 0 ? 48 : count * 39))
        return ZStack(alignment: alignment) {
            if open {
                menuPanel(applicationMenu: application)
                    .frame(width: 345, height: menuHeight, alignment: .bottom)
                    .transition(.opacity)
            } else if application && secondary {
                NativeHoverButton(title: "打开 Keylane 菜单", action: { toggleMenu(application: true) }) {
                    SecondaryPageBadge(title: badgeTitle, symbol: badgeSymbol)
                }.frame(width: applicationWidth, height: 36).transition(.opacity)
            } else if application {
                NativeHoverButton(title: "Keylane 菜单", action: { toggleMenu(application: true) }) {
                    Image(systemName: "text.menu").font(.system(size: 16)).frame(width: 36, height: 36)
                }.frame(width: 36, height: 36).clipShape(Circle()).transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    NativeHoverButton(title: primaryTitle, action: { run() }) { HStack(spacing: 7) { Text(primaryTitle).lineLimit(1).truncationMode(.tail); Keycap(text: "↩") }.padding(.horizontal, 6) }.frame(maxWidth: .infinity).frame(height: 28)
                    NativeHoverButton(title: "操作", action: { toggleMenu(application: false) }) { HStack(spacing: 7) { Text("操作"); HStack(spacing: 3) { Keycap(text: "⌘"); Keycap(text: "K") } } }.frame(maxWidth: .infinity).frame(height: 28)
                }.font(.system(size: 13, weight: .medium)).padding(4).frame(width: actionWidth, height: 36).transition(.opacity)
            }
        }
        // The container remains in the same hierarchy. Only its size changes; its bottom
        // corner stays fixed. No matched-position or automatic glass transition can slide it.
        .frame(width: open ? 345 : (application ? applicationWidth : actionWidth), height: open ? menuHeight : 36, alignment: alignment)
        .modifier(LauncherMenuSurface(open: open))
    }
    private struct MenuAction: Identifiable {
        let id: String
        let title: String
        let icon: String
        var keys: [String] = []
        let perform: () -> Void
    }
    private var selectedEntry: Entry? { let results = rows; return results.indices.contains(selection) ? results[selection] : nil }
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
        if let mode = model.navigationMode {
            let refresh = MenuAction(id: "refresh-navigation", title: NavigationText.label("刷新结果", "Refresh Results"),
                                     icon: "arrow.clockwise", perform: reloadNavigation)
            guard let item = model.systemNavigation.selected else { return [refresh] }
            return [MenuAction(id: "run-navigation", title: mode.action, icon: mode.symbol, keys: ["↩"],
                               perform: { runNavigation(item, mode: mode) }), refresh]
        }
        if model.tab == "Emoji" {
            guard let item = model.emoji.selected else { return [] }
            return [
                MenuAction(id: "paste-emoji", title: emojiPasteTitle, icon: "doc.on.clipboard", keys: ["↩"], perform: { useEmoji(item, paste: true) }),
                MenuAction(id: "copy-emoji", title: EmojiCatalog.label("复制字符", "Copy Character"), icon: "doc.on.doc", perform: { useEmoji(item, paste: false) })
            ]
        }
        if model.tab == "Contacts" {
            var commands = [MenuAction(id: "contacts-open", title: "打开系统联系人", icon: "person.crop.circle", perform: { UtilityActions.openApplication("com.apple.AddressBook") }),
                            MenuAction(id: "contacts-refresh", title: "刷新联系人", icon: "arrow.clockwise", perform: { model.contacts.refresh() })]
            if let contact = model.contacts.selected {
                commands += contact.phones.enumerated().map { index, value in
                    MenuAction(id: "phone-\(index)", title: "复制电话 " + value, icon: "phone", perform: { UtilityActions.copy(value) })
                }
                commands += contact.emails.enumerated().map { index, value in
                    MenuAction(id: "email-\(index)", title: "复制邮箱 " + value, icon: "envelope", perform: { UtilityActions.copy(value) })
                }
            }
            return commands
        }
        if model.tab == "Dictionary" {
            var commands = [MenuAction(id: "dictionary-open", title: "打开系统词典", icon: "book.closed", perform: { model.dictionary.openDictionary() })]
            if let definition = model.dictionary.definition {
                commands.insert(MenuAction(id: "dictionary-copy", title: "复制释义", icon: "doc.on.doc", perform: { UtilityActions.copy(definition) }), at: 0)
            }
            return commands
        }
        if let row = selectedEntry, row.detail == "Shortcut" {
            return [MenuAction(id: "shortcut-run", title: "运行快捷指令", icon: "play", perform: { model.perform(row) }),
                    MenuAction(id: "shortcut-settings", title: "快捷指令设置…", icon: "gearshape", perform: { model.openSettings(page: "shortcuts") })]
        }
        if model.tab == "Calendar" {
            return [MenuAction(id: "open-calendar", title: "打开系统日历", icon: "calendar", perform: { model.calendar.openSystemCalendar() }),
                    MenuAction(id: "calendar-today", title: "今天", icon: "clock", perform: { model.calendar.showToday() }),
                    MenuAction(id: "calendar-refresh", title: "刷新日程", icon: "arrow.clockwise", perform: { model.calendar.refresh() }),
                    MenuAction(id: "calendar-settings", title: "日历设置…", icon: "gearshape", perform: { model.openSettings(page: "calendar") })]
        }
        if model.tab == "Screenshots" { return screenshotActions() }
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
            Text(applicationMenu ? "Keylane " + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版") : (model.tab == "Calendar" ? "日历操作" : model.tab == "Clipboard" ? "剪贴板操作" : (selectedEntry?.name ?? "操作")) + (submenu ? " › Finder" : "")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 8)
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
        filterOpen = false
        model.compactExpanded = true
        let open = application ? !appMenu : !actions
        submenu = false; actions = !application && open; appMenu = application && open; actionQuery = ""; actionSelection = 0; focusToken += 1
    }
    private func closeMenus() { filterOpen = false; submenu = false; actions = false; appMenu = false; actionQuery = ""; focusToken += 1 }
    private var moduleTitle: String {
        if let mode = model.navigationMode {
            return mode == .windows ? NavigationText.label("搜索窗口…", "Search Windows…")
                                    : NavigationText.label("搜索菜单项…", "Search Menu Items…")
        }
        switch model.tab { case "Emoji": return EmojiCatalog.label("搜索 Emoji 与符号…", "Search Emoji & Symbols…"); case "Contacts": return "搜索联系人…"; case "Dictionary": return "输入要查询的词语…"; case "Calendar": return "搜索日程…"; case "Notes": return "便笺"; case "Clipboard": return "搜索剪贴板历史…"; case "Screenshots": return "按 name:、text: 或 date: 搜索截图…"; case "Files": return "搜索文件…"; default: return "设置" } }
    private var primaryTitle: String { if model.tab == "Screenshots" { return "复制到剪贴板" }; if argumentTarget != nil { return "启动新实例" }; if let mode = model.navigationMode { return mode.action }; if selectedEntry?.id == "calculator" { return "复制结果" }; if model.tab == "Emoji" { return emojiPasteTitle }; if model.tab == "Contacts" { return model.contacts.selected?.firstValue == nil ? "打开联系人" : "复制" }; if model.tab == "Dictionary" { return model.dictionary.definition == nil ? "打开词典" : "复制释义" }; if selectedEntry?.detail == "Shortcut" { return model.systemShortcuts.runningID == nil ? "运行" : "运行中" }; if model.tab == "Calendar" { return "打开日历" }; if model.tab == "Clipboard" { return model.clipboard.primaryAction == "paste" ? "粘贴" : "复制" }; return model.tab == "Commands" || model.tab == "Files" ? "打开" : "返回" }
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
    private var emojiBadgeTitle: String {
        let name = EmojiCatalog.label("Emoji 与符号", "Emoji & Symbols")
        guard let item = model.emoji.selected else { return name }
        return "\(name) – \(item.title)"
    }

    private var emojiPasteTitle: String {
        guard let app = (NSApp.delegate as? Delegate)?.pasteTargetName else {
            return EmojiCatalog.label("复制字符", "Copy Character")
        }
        return EmojiCatalog.label("粘贴到 \(app)", "Paste to \(app)")
    }

    private func useEmoji(_ item: EmojiItem, paste: Bool) {
        model.error = ""
        UtilityActions.copy(item.glyph)
        model.emoji.recordUse(item)
        if paste, let delegate = NSApp.delegate as? Delegate, delegate.pasteTargetName != nil {
            delegate.pasteIntoPreviousApplication { message in model.error = message }
        } else {
            (NSApp.delegate as? Delegate)?.hideLauncher()
        }
    }

    private func reloadNavigation() {
        guard let mode = model.navigationMode else { return }
        model.systemNavigation.query = model.query
        model.systemNavigation.load(mode, target: (NSApp.delegate as? Delegate)?.previousApplication)
    }

    private func runNavigation(_ item: NavigationItem, mode: NavigationMode) {
        guard let delegate = NSApp.delegate as? Delegate else { return }
        model.systemNavigation.perform(item, mode: mode) { [weak delegate] message in
            if let message { delegate?.navigationToast.show(message) }
            else if item.application.isActive { delegate?.hideLauncher() }
        }
    }

    private func chooseScreenshotFolders() {
        model.screenshots.chooseFolders()
        (NSApp.delegate as? Delegate)?.showScreenshotLibrary()
        model.screenshots.refresh()
    }

    private func screenshotActions() -> [MenuAction] {
        let controls = [
            MenuAction(id: "screenshot-refresh", title: "刷新截图", icon: "arrow.clockwise", perform: { model.screenshots.refresh() }),
            MenuAction(id: "screenshot-folders", title: "添加搜索文件夹…", icon: "folder.badge.plus", perform: chooseScreenshotFolders),
            MenuAction(id: "screenshot-settings", title: "截图设置…", icon: "gearshape", perform: { model.openSettings(page: "screenshots") })
        ]
        guard let item = model.screenshots.selected else { return controls }
        return [
            MenuAction(id: "screenshot-copy", title: "复制到剪贴板", icon: "doc.on.doc", keys: ["↩"], perform: { copyScreenshot(item) }),
            MenuAction(id: "screenshot-preview", title: "快速查看", icon: "eye", perform: { withScreenshot(item) { FilePreview.shared.show(item.url) } }),
            MenuAction(id: "screenshot-open", title: "打开原文件", icon: "arrow.up.forward.app", perform: {
                withScreenshot(item) {
                    guard NSWorkspace.shared.open(item.url) else { throw CocoaError(.fileReadUnknown) }
                    (NSApp.delegate as? Delegate)?.hideLauncher()
                }
            }),
            MenuAction(id: "screenshot-share", title: "分享…", icon: "square.and.arrow.up", perform: { withScreenshot(item) { FileActionsWindow.shared.show(item.url, page: "share") } }),
            MenuAction(id: "screenshot-reveal", title: "在 Finder 中显示", icon: "folder", perform: { withScreenshot(item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } }),
            MenuAction(id: "screenshot-trash", title: "移到废纸篓…", icon: "trash", perform: { trashScreenshot(item) })
        ] + controls
    }

    private func withScreenshot(_ item: ScreenshotMedia, perform: () throws -> Void) {
        do { try model.screenshots.validate(item); try perform() }
        catch { model.error = "截图操作失败：" + error.localizedDescription; model.screenshots.refresh() }
    }

    private func copyScreenshot(_ item: ScreenshotMedia) {
        withScreenshot(item) {
            try model.screenshots.copy(item)
            (NSApp.delegate as? Delegate)?.hideLauncher()
        }
    }

    private func trashScreenshot(_ item: ScreenshotMedia) {
        let alert = NSAlert()
        alert.messageText = "将这张截图移到废纸篓？"
        alert.informativeText = item.name
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true
        if alert.runModal() == .alertSecondButtonReturn {
            withScreenshot(item) { try model.screenshots.moveToTrash(item) }
        }
        (NSApp.delegate as? Delegate)?.showScreenshotLibrary()
    }

    private func run() {
        if (model.tab == "Files" || selectedEntry?.detail == "File"), model.fileSearch.isSearching { return }
        if let target = argumentTarget { do { let args = try ArgumentParser.parse(argumentText); model.launch(URL(fileURLWithPath: target.id), arguments: args) } catch { model.error = "参数引号或转义未完成。" }; return }
        if actions || appMenu { let items = filteredMenu(applicationMenu: appMenu); if items.indices.contains(actionSelection) { let item = items[actionSelection]; closeMenus(); item.perform() }; return }
        if let mode = model.navigationMode {
            if let item = model.systemNavigation.selected { runNavigation(item, mode: mode) }
            return
        }
        if model.tab == "Emoji" {
            if let item = model.emoji.selected { useEmoji(item, paste: true) }
            return
        }
        if model.tab == "Contacts" {
            if let value = model.contacts.selected?.firstValue { UtilityActions.copy(value) }
            else { UtilityActions.openApplication("com.apple.AddressBook") }
            return
        }
        if model.tab == "Dictionary" {
            if let definition = model.dictionary.definition { UtilityActions.copy(definition) }
            else { model.dictionary.openDictionary() }
            return
        }
        if model.tab == "Calendar" { model.calendar.openSystemCalendar(); return }
        if model.tab == "Screenshots" {
            if let item = model.screenshots.selected { copyScreenshot(item) }
            return
        }
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
