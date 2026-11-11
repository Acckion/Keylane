import SwiftUI
import AppKit
import Combine
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
    let model: Model
    @StateObject private var observation: ViewObservation
    @StateObject private var modifiers = LauncherModifiers()
    @State private var selection = 0
    @State private var pageRevision = 0
    @State private var launcherVisible = false
    @State private var presentedPage = PageID.root
    private var page: LauncherPage? { model.activeLauncherPage }
    private var showsFileResults: Bool { page?.contentPlacement == .fileResults }
    @State private var fileType = "all"
    private enum Menu { case application, actions, filter }
    @State private var menu: Menu?
    private var actions: Bool { menu == .actions }
    private var appMenu: Bool { menu == .application }
    private var filterOpen: Bool { menu == .filter }
    private var filterBinding: Binding<Bool> {
        Binding(get: { filterOpen }, set: { open in
            closeMenus()
            if open { menu = .filter }
        })
    }
    @State private var mainSearchQuery = ""
    @State private var mainSearchSelection = 0
    @State private var mainSearchExpanded = false
    @State private var pendingMainSelection: Int?
    @State private var selectedResultID: String?
    @State private var actionQuery = ""
    @State private var actionSelection = 0
    @State private var focusToken = 0
    @State private var submenu: LauncherAction.Submenu?
    @State private var argumentTarget: LauncherAction.ArgumentForm?
    @State private var argumentText = ""
    @FocusState private var argumentsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$pageID),
            ViewObservation.changes(model.$query),
            ViewObservation.changes(model.$error),
            ViewObservation.changes(model.$appearance),
            ViewObservation.changes(model.$interfaceSize),
            ViewObservation.changes(model.$windowMode),
            ViewObservation.changes(model.$compactExpanded),
            ViewObservation.changes(model.$presentedLauncherHeight),
            ViewObservation.changes(model.$compactFavorites),
            ViewObservation.changes(model.$favorites),
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$usage),
            ViewObservation.changes(model.$excluded),
            ViewObservation.changes(model.$runningPaths),
            ViewObservation.changes(model.$navigation),
            ViewObservation.changes(model.$rootSearchSensitivity),
            ViewObservation.changes(model.$rootFileContentSearch),
            ViewObservation.changes(model.$fileResults),
            ViewObservation.changes(model.$fileSearchStatus),
            ViewObservation.changes(model.fileSearch.$options.map { [$0.enabled, $0.searchFromLauncher] })
        ]))
    }

    private var rows: [Entry] {
        if showsFileResults { return model.fileEntries(ofType: fileType) }
        return model.pageID == .root ? model.commands : []
    }
    private var launcherSurface: some View {
        let results = rows
        let showsSearchBar = argumentTarget == nil && page?.contentPlacement != .form
        let compactSurface = model.isCompact && model.presentedLauncherHeight <= model.launcherHeight + 0.5
        return ZStack(alignment: .top) {
            if let target = argumentTarget { argumentEditor(target).padding(.bottom, VisualStyle.launcherBottomInset) }
            else if compactSurface { Color.clear }
            else {
                if showsFileResults {
                    ResultDetailLayout {
                        commandList(results)
                    } detail: {
                        FileSearchDetail(url: results.indices.contains(selection) ? URL(fileURLWithPath: results[selection].id) : nil)
                    }
                } else if model.pageID == .root {
                    commandList(results).frame(height: 470, alignment: .top)
                } else if let page, let content = page.content {
                    switch page.contentPlacement {
                    case .underChrome: content()
                    case .form: content().padding(.bottom, VisualStyle.launcherBottomInset)
                    case .inset, .fileResults:
                        content().padding(.top, VisualStyle.launcherTopInset).padding(.bottom, VisualStyle.launcherBottomInset)
                    }
                }
            }
            if !compactSurface { VStack(spacing: 0) {
                if showsSearchBar {
                    ChromeBlur().frame(height: 88)
                        .mask(LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .black.opacity(0.7), location: 0.48), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                }
                Spacer(minLength: 0)
                if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red).padding(8).background(.regularMaterial) }
                ChromeBlur().frame(height: 78)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.5), .init(color: .black.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom))
            }.allowsHitTesting(false) }
            // Keep the search field interactive while the blur's full-window spacer is inert.
            if showsSearchBar { VStack(spacing: 0) {
                searchBar
                if compactSurface && model.compactFavorites && !model.favorites.isEmpty { compactFavoritesBar }
                Spacer(minLength: 0)
            } }
            if actions || appMenu || filterOpen { Color.clear.contentShape(Rectangle()).onTapGesture { closeMenus() } }
            if !compactSurface { footer.frame(maxHeight: .infinity, alignment: .bottom) }
            if showsSearchBar && showsTypeFilter {
                typeFilter.frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(VisualStyle.launcherEdgeInset)
            }
        }
        .frame(width: 760, height: model.presentedLauncherHeight, alignment: .top)
        .scaleEffect(model.interfaceScale)
        .frame(width: 760 * model.interfaceScale, height: model.presentedLauncherHeight * model.interfaceScale)
        .scrollIndicators(.visible, axes: .vertical)

        .background { if reduceTransparency { Color(nsColor: .windowBackgroundColor) } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: actions)
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: appMenu)
        .background {
            Button("") { toggleMenu(application: false) }.keyboardShortcut("k", modifiers: .command).hidden().accessibilityHidden(true)
            Button("") { closeMenus(); model.runCommand(.init(rawValue: "settings"), origin: .menu) }.keyboardShortcut(",", modifiers: .command).hidden().accessibilityHidden(true)
            Button("") { page?.shortcutSubmit?() }.keyboardShortcut(.return, modifiers: .command).hidden().accessibilityHidden(true)
            ForEach(0..<min(10, results.count), id: \.self) { index in
                Button("") { if model.pageID == .root || showsFileResults { let results = rows; guard results.indices.contains(index) else { return }; selection = index; model.perform(results[index]) } }.keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: .command).hidden().accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius, style: .continuous))
        .preferredColorScheme(model.colorScheme)
    }

    var body: some View {
        let _ = pageRevision
        launcherSurface
        .onAppear {
            launcherVisible = (NSApp.delegate as? Delegate)?.window?.isVisible == true
            focusToken += 1
            modifiers.start()
        }
        .onChange(of: model.windowMode) { _, _ in focusToken += 1 }
        .onDisappear { modifiers.stop() }
        .onExitCommand { if !SearchField.isComposing { escape() } }
        .onReceive(model.activePageUpdates) { _ in
            if launcherVisible { pageRevision &+= 1 }
        }
        .onReceive(model.rootSearchUpdates) { _ in
            if launcherVisible && model.pageID == .root { pageRevision &+= 1 }
        }
        .onReceive(model.launcherModules?.presentationUpdates ?? Empty().eraseToAnyPublisher()) { _ in
            if launcherVisible && model.pageID == .root { pageRevision &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShown)) { _ in
            launcherVisible = true
            modifiers.start()
            closeMenus()
            model.launcherModules?.launcherShown()
            if presentedPage == model.pageID {
                if let resume = page?.resume { resume() }
                else { refreshActiveQuery() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherResetSearch)) { _ in
            mainSearchQuery = ""
            mainSearchSelection = 0
            mainSearchExpanded = false
            pendingMainSelection = nil
            selectedResultID = nil
            selection = 0
            argumentTarget = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherHidden)) { _ in
            launcherVisible = false
            modifiers.stop()
            closeMenus()
            model.launcherModules?.page(presentedPage)?.leave()
            if presentedPage == .root { model.fileSearch.cancel() }
        }
        .onChange(of: fileType) { _, _ in selection = 0; selectedResultID = nil; focusToken += 1 }
        .onChange(of: model.query) { _, _ in
            selection = pendingMainSelection ?? 0
            pendingMainSelection = nil
            selectedResultID = nil
            if launcherVisible { refreshActiveQuery() }
        }
        .onChange(of: model.fileSearch.options.enabled) { _, _ in
            if launcherVisible && model.searchesFilesHere { model.searchFiles() } else { model.fileSearch.cancel(); model.fileResults = [] }
        }
        .onChange(of: model.fileSearch.options.searchFromLauncher) { _, _ in
            if model.pageID == .root { if launcherVisible && model.searchesFilesHere { model.searchFiles() } else { model.fileSearch.cancel(); model.fileResults = [] } }
        }
        .onChange(of: model.rootFileContentSearch) { _, _ in
            if launcherVisible && model.pageID == .root && model.searchesFilesHere {
                model.searchFiles()
            }
        }
        .onChange(of: model.rootSearchSensitivity) { _, _ in
            if model.pageID == .root {
                selection = 0
                selectedResultID = nil
            }
        }
        .onChange(of: model.fileResults) { previous, current in
            guard showsFileResults || model.pageID == .root else { return }
            let oldID = selectedResultID ?? (showsFileResults && previous.indices.contains(selection) ? previous[selection].id : nil)
            let results = rows
            if let oldID, let index = results.firstIndex(where: { $0.id == oldID }) { selection = index }
            else { selection = min(selection,max(0,results.count-1)) }
        }
        .onChange(of: model.pageID) { previous, current in pageChanged(from: previous, to: current) }
    }

    private func pageChanged(from previous: PageID, to current: PageID) {
        closeMenus()
        if previous == .root { model.fileSearch.cancel() }
        else if let previousPage = model.launcherModules?.page(previous) {
            previousPage.leave()
            previousPage.releasePreview?()
        }
        presentedPage = current
        if previous == .root {
            mainSearchQuery = model.query
            mainSearchSelection = selection
            mainSearchExpanded = model.compactExpanded
        }
        let oldQuery = model.query
        if current == .root {
            pendingMainSelection = oldQuery == mainSearchQuery ? nil : mainSearchSelection
            model.query = mainSearchQuery
            selection = mainSearchSelection
            model.compactExpanded = mainSearchExpanded
            if launcherVisible && oldQuery == model.query { refreshActiveQuery() }
        } else {
            let seed = launcherVisible ? page?.enter?("") : nil
            model.query = seed ?? ""
            selection = 0
            if launcherVisible && oldQuery == model.query { refreshActiveQuery() }
        }
        selectedResultID = nil
        focusToken += 1
    }

    private func refreshActiveQuery() {
        if let page { page.queryChanged(model.query) }
        else if model.searchesFilesHere { model.searchFiles() }
    }
    private func moveSelection(_ delta: Int) {
        if model.isCompact { model.compactExpanded = true; return }
        if actions || appMenu {
            let items = filteredMenu(applicationMenu: appMenu)
            let enabled = items.indices.filter { items[$0].enabled }
            if let current = enabled.firstIndex(of: actionSelection) {
                actionSelection = enabled[NavigationBounds.move(current, by: delta, count: enabled.count)]
            } else if let first = enabled.first { actionSelection = first }
        }
        else if let move = page?.move { move(delta) }
        else if model.pageID == .root || showsFileResults {
            let results = rows
            selection = NavigationBounds.move(selection, by: delta, count: results.count)
            selectedResultID = results.indices.contains(selection) ? results[selection].id : nil
        }
    }
    private func escape() {
        if submenu != nil { dismissSubmenu(); return }
        if argumentTarget != nil { argumentTarget = nil; focusToken += 1; return }
        if actions || appMenu || filterOpen { closeMenus() }
        else if model.pageID != .root && model.launcherEscapeBehavior == .backOrClose { model.pageID = .root }
        else { (NSApp.delegate as? Delegate)?.hideLauncher() }
    }

    private var compactFavoritesBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(model.commands.filter { model.favorites.contains($0.id) }) { row in
                    Button { model.perform(row) } label: {
                        Group {
                            if let artwork = model.launcherModules?.artwork(for: row) { artwork }
                            else if row.id.hasSuffix(".app") { Image(nsImage: IconCache.shared.image(row.id)).resizable() }
                            else { Image(systemName: row.symbol).resizable().scaledToFit() }
                        }.frame(width: 26, height: 26)
                    }.buttonStyle(.plain).help(row.name).accessibilityLabel(row.name)
                }
            }.padding(.horizontal, 19).frame(height: 42)
        }.scrollIndicators(.hidden)
    }
    private var showsTypeFilter: Bool { showsFileResults || page?.typeFilter != nil }

    private var searchBar: some View {
        HStack(spacing: 12) {
            if model.pageID != .root { backButton { model.pageID = .root } }
            if model.pageID == .root { Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .regular)).foregroundStyle(.secondary) }
            SearchField(text: Binding(get: { model.query }, set: { model.query = $0 }), placeholder: model.pageID == .root ? "搜索应用、文件和命令…" : moduleTitle, focusToken: focusToken, wantsFocus: !actions && !appMenu && !filterOpen, navigation: model.navigation, submit: { run() }, move: moveSelection, escape: escape,
                        back: page?.moveHorizontal.map { move in { move(-1) } },
                        forward: page?.moveHorizontal.map { move in { move(1) } },
                        navigateWhileTyping: page?.navigateWhileTyping ?? false)
                .frame(height: 30)
            if let accessory = page?.searchAccessory { accessory() }
            else if showsTypeFilter {
                Color.clear.frame(width: page?.typeFilterWidth ?? 138, height: 36).accessibilityHidden(true)
            }
        }.padding(.horizontal, model.pageID == .root ? 19 : VisualStyle.launcherEdgeInset)
            .frame(height: model.pageID == .root ? 61 : VisualStyle.launcherControlDiameter + 2 * VisualStyle.launcherEdgeInset)
            .frame(height: 61, alignment: .top)
    }
    @ViewBuilder private var typeFilter: some View {
        if showsFileResults {
            ResultTypeFilter(selection: $fileType, options: ResultFilterOption.files, open: filterBinding, navigation: model.navigation)
        } else if let filter = page?.typeFilter { filter(filterBinding) }
    }
    private func commandList(_ results: [Entry]) -> some View {
        SelectableResultList(selection: results.indices.contains(selection) ? results[selection].id : nil,
                             query: model.query, firstResult: results.first?.id) {
            if results.isEmpty {
                VStack(spacing: 10) { Image(systemName: "magnifyingglass").font(.system(size: 26)); Text(showsFileResults && model.query.isEmpty ? "搜索文件" : "没有匹配结果").font(.system(size: 14)); Text(showsFileResults ? model.fileSearchStatus : "试试应用名称、拼音或计算表达式").font(.caption); if showsFileResults { Button("选择搜索文件夹…", systemImage: "folder") { model.chooseFileSearchFolder(returnToLauncher: true) }.buttonStyle(ContentActionButtonStyle()).padding(.top, 8) } }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
            }
            ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                if row.id == "calculator" {
                    sectionHeader("计算器")
                } else if showsFileResults {
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
                    if !showsFileResults { model.perform(row) }
                } label: {
                    if row.id == "calculator" {
                        CalculatorResultCard(expression: model.query, result: row.name, selected: index == selection)
                    } else if showsFileResults {
                        fileResultRow(row, index: index)
                    } else {
                        resultRow(row, index: index)
                    }
                }.buttonStyle(.plain).id(row.id)
                    .contextMenu {
                        if row.commandID.rawValue.hasPrefix("app:") {
                            Button("使用参数启动…", systemImage: "terminal") {
                                closeMenus()
                                argumentText = ""
                                argumentTarget = .init(title: row.name) { [weak model] arguments in
                                    model?.launch(URL(fileURLWithPath: row.id), arguments: arguments)
                                }
                            }
                        }
                    }
            }
        }
    }
    private func sectionHeader(_ title: String) -> some View { Text(title).font(VisualStyle.sectionText).foregroundStyle(.secondary).padding(.leading, 14).padding(.top, 5).padding(.bottom, 5).frame(height: 26) }
    private func fileResultRow(_ row: Entry, index: Int) -> some View {
        let url = URL(fileURLWithPath: row.id)
        let isFolder = row.isDirectory
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
        ResultListRow(selected: index == selection, layout: .root) {
            Group {
                if let artwork = model.launcherModules?.artwork(for: row) { artwork }
                else if row.id.hasSuffix(".app") || row.detail == "File" { Image(nsImage: IconCache.shared.image(row.id)).resizable().interpolation(.high) }
                else { Image(systemName: row.symbol).font(.system(size: 21, weight: .regular)).foregroundStyle(iconColor(row.id)) }
            }
            .frame(width: 26, height: 26)
            .overlay(alignment: .bottomLeading) {
                if model.runningPaths.contains(row.id) {
                    Circle().fill(.green).frame(width: 5, height: 5).offset(x: -1, y: 3)
                        .accessibilityLabel("正在运行")
                }
            }
        } content: {
            HStack(spacing: ResultListRowLayout.root.horizontalInset) {
                HighlightedResultText(text: row.name, query: model.query).font(VisualStyle.rowText).lineLimit(1).truncationMode(.middle)
                if let subtitle = row.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                if row.detail == "File" {
                    Text(URL(fileURLWithPath: row.id).deletingLastPathComponent().path).font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if row.detail == "AI" { Text("AI").font(.system(size: 12)).foregroundStyle(.secondary) }
                if let alias = model.aliases[row.id], !alias.isEmpty {
                    Text(alias).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer(minLength: 8)
                resultAttributeBadge(row, index: index)
            }
        }
    }
    private func resultAttributeBadge(_ row: Entry, index: Int) -> some View {
        let showingShortcut = modifiers.commandHeld && index < 10
        let custom = model.launcherModules?.detailView(for: row)
        return Group {
            if let custom { custom }
            else { Text(resultAttribute(row)) }
        }
            .font(.system(size:14,weight:.regular)).foregroundStyle(.secondary).lineLimit(1)
            .frame(width: custom != nil ? 180 : row.detail == SystemSettingsCatalog.resultKind ? 112 : 84, alignment: .trailing)
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
        if let detail = model.launcherModules?.displayDetail(for: row) { return detail }
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
        let secondary = page?.badge != nil
        let badgeTitle = page?.badgeTitle?() ?? page?.badge?.title ?? ""
        let badgeSymbol = page?.badge?.symbol ?? ""
        let applicationWidth: CGFloat = secondary ? min(420, SecondaryPageBadge.width(for: badgeTitle)) : 36
        let showsActions = page?.contentPlacement != .form || !menuItems(applicationMenu: false).isEmpty
        let actionWidth: CGFloat = page?.actionWidth ?? (showsActions ? 196 : 126)
        let open = application ? appMenu : actions
        let alignment: Alignment = application ? .bottomLeading : .bottomTrailing
        let items = open ? filteredMenu(applicationMenu: application) : []
        let menuHeight = menuRowsHeight(items) + 87
        return ZStack(alignment: alignment) {
            if open {
                menuPanel(applicationMenu: application, items: items)
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
                    NativeHoverButton(title: primaryTitle, action: { run() }) {
                        HStack(spacing: 7) {
                            Text(primaryTitle).lineLimit(1).truncationMode(.tail)
                            HStack(spacing: 3) {
                                if page?.contentPlacement == .form && page?.shortcutSubmit != nil { Keycap(text: "⌘") }
                                Keycap(text: "↩")
                            }
                        }.padding(.horizontal, 6)
                    }
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .disabled(page?.primaryEnabled?() == false)
                    .opacity(page?.primaryEnabled?() == false ? 0.45 : 1)
                    if showsActions {
                        NativeHoverButton(title: "操作", action: { toggleMenu(application: false) }) {
                            HStack(spacing: 7) {
                                Text("操作")
                                HStack(spacing: 3) { Keycap(text: "⌘"); Keycap(text: "K") }
                            }
                        }.frame(maxWidth: .infinity).frame(height: 28)
                    }
                }.font(.system(size: 13, weight: .medium)).padding(4).frame(width: actionWidth, height: 36).transition(.opacity)
            }
        }
        // The container remains in the same hierarchy. Only its size changes; its bottom
        // corner stays fixed. No matched-position or automatic glass transition can slide it.
        .frame(width: open ? 345 : (application ? applicationWidth : actionWidth), height: open ? menuHeight : 36, alignment: alignment)
        .modifier(LauncherMenuSurface(open: open))
    }
    private typealias MenuAction = LauncherAction
    private var selectedEntry: Entry? { let results = rows; return results.indices.contains(selection) ? results[selection] : nil }
    private func menuItems(applicationMenu: Bool) -> [MenuAction] {
        if applicationMenu {
            return [
                MenuAction(id: "about", title: "关于 Keylane", icon: "app.badge", perform: { model.openSettings(page: "about") }),
                MenuAction(id: "settings", title: "设置…", icon: "gearshape", keys: ["⌘", ","], perform: { model.runCommand(.init(rawValue: "settings"), origin: .menu) }),
                MenuAction(id: "clipboard", title: "剪贴板历史", icon: "list.clipboard", perform: { model.runCommand(.init(rawValue: "clipboard"), origin: .menu) }),
                MenuAction(id: "notes", title: "便笺", icon: "note", perform: { model.runCommand(.init(rawValue: "notes"), origin: .menu) }),
                MenuAction(id: "hide", title: "隐藏 Keylane", icon: "rectangle.compress.vertical", keys: ["esc"], perform: { (NSApp.delegate as? Delegate)?.hideLauncher() }),
                MenuAction(id: "quit", title: "退出 Keylane", icon: "rectangle.portrait.and.arrow.right", perform: { NSApp.terminate(nil) })
            ]
        }
        if let submenu {
            return [MenuAction(id: "back", title: "返回", icon: "chevron.left", perform: dismissSubmenu)] + submenu.items
        }
        if let page, !showsFileResults { return page.actions?() ?? [] }
        guard let row = selectedEntry else { return [] }
        if let actions = model.launcherModules?.actions(for: row) { return actions }
        return [
            MenuAction(id: "open", title: "执行命令", icon: "return", keys: ["↩"]) {
                model.runCommand(row.commandID, origin: .menu, usageKey: row.id)
            },
            model.favoriteAction(for: row)
        ]
    }
    private func dismissSubmenu() {
        submenu = nil
        actionQuery = ""
        actionSelection = 0
        focusToken += 1
    }
    private func activate(_ item: MenuAction) {
        guard item.enabled else { return }
        if let next = item.submenu {
            submenu = next
            actionQuery = ""
            actionSelection = 0
            focusToken += 1
        } else if item.id == "back", submenu != nil {
            dismissSubmenu()
        } else {
            closeMenus()
            item.perform()
        }
    }
    private func filteredMenu(applicationMenu: Bool) -> [MenuAction] { menuItems(applicationMenu: applicationMenu).filter { actionQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(actionQuery) } }
    private func menuRowsHeight(_ items: [MenuAction]) -> CGFloat {
        guard !items.isEmpty else { return 48 }
        let breaks = zip(items, items.dropFirst()).filter { $0.group != $1.group }.count
        return min(320, CGFloat(items.count * 39 + breaks * 9))
    }

    private func menuPanel(applicationMenu: Bool, items: [MenuAction]) -> some View {
        let title: String
        if applicationMenu {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
            title = "Keylane " + version
        } else {
            let base = page?.actionTitle ?? selectedEntry?.name ?? "操作"
            title = submenu.map { base + " › " + $0.title } ?? base
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 8)
            if items.isEmpty {
                Text("没有匹配的操作").font(.caption).foregroundStyle(.secondary).padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index > 0, items[index - 1].group != item.group {
                                    Divider().padding(.horizontal, 16).frame(height: 9)
                                }
                                LauncherMenuRow(title: item.title, symbol: item.icon, selected: index == actionSelection,
                                                enabled: item.enabled, destructive: item.destructive,
                                                activate: { activate(item) }, highlight: { actionSelection = index }) {
                                    if !item.keys.isEmpty { Keycaps(keys: item.keys) }
                                }
                                .padding(.horizontal, 8)
                                .id(item.id)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: menuRowsHeight(items))
                    .onChange(of: actionSelection) { _, index in
                        if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
                    }
                    .onChange(of: actionQuery) { _, _ in
                        if let first = items.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
            }
            Divider().padding(.top, 9)
            SearchField(text: $actionQuery, placeholder: "搜索操作…", focusToken: focusToken, wantsFocus: actions || appMenu, fontSize: 14, navigation: model.navigation, submit: {
                if items.indices.contains(actionSelection) { activate(items[actionSelection]) }
            }, move: moveSelection, escape: escape, back: { escape() }, forward: {
                if items.indices.contains(actionSelection), items[actionSelection].submenu != nil { activate(items[actionSelection]) }
            }).frame(height: 22).padding(.horizontal, 16).padding(.vertical, 10)
                .onChange(of: actionQuery) { _, _ in actionSelection = items.firstIndex(where: \.enabled) ?? 0 }
        }.frame(width: 345)
    }
    private func toggleMenu(application: Bool) {
        if !application, page?.contentPlacement == .form, menuItems(applicationMenu: false).isEmpty { return }
        model.compactExpanded = true
        let target: Menu = application ? .application : .actions
        let open = menu != target
        closeMenus()
        if open { menu = target }
    }

    private func closeMenus() {
        menu = nil
        submenu = nil
        actionQuery = ""
        actionSelection = 0
        focusToken += 1
    }
    private var moduleTitle: String { page?.placeholder ?? "设置" }
    private var primaryTitle: String {
        if argumentTarget != nil { return "启动新实例" }
        if let title = page?.primaryTitle?() { return title }
        if let row = selectedEntry {
            if let title = model.launcherModules?.primaryTitle(for: row) { return title }
            if row.id == "calculator" { return "复制结果" }
        }
        return model.pageID == .root || showsFileResults ? "打开" : "返回"
    }
    private func argumentEditor(_ target: LauncherAction.ArgumentForm) -> some View {
        LauncherCreationForm(back: {
            argumentTarget = nil
            focusToken += 1
        }) {
            Text(target.title).foregroundStyle(.secondary)
        } fields: {
            LauncherCreationField("启动参数", detail: "参数是否生效取决于目标应用；不会通过 Shell 执行。") {
                VStack(alignment: .leading, spacing: 8) {
                    LauncherCreationControl(focused: argumentsFocused) {
                        TextField("例如：--profile \"Work Profile\"", text: $argumentText)
                            .textFieldStyle(.plain)
                            .focused($argumentsFocused)
                            .onSubmit { run() }
                    }
                    if let arguments = try? ArgumentParser.parse(argumentText), !arguments.isEmpty {
                        Text(arguments.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n"))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            argumentsFocused = true
        }
    }
    private func backButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "chevron.backward").font(.system(size: 15, weight: .medium)).frame(width: 24, height: 26) }
            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large).help("返回").accessibilityLabel("返回")
    }
    private func run() {
        if (showsFileResults || selectedEntry?.detail == "File"), model.fileSearch.isSearching { return }
        if let target = argumentTarget { do { let args = try ArgumentParser.parse(argumentText); target.submit(args) } catch { model.error = "参数引号或转义未完成。" }; return }
        if actions || appMenu { let items = filteredMenu(applicationMenu: appMenu); if items.indices.contains(actionSelection) { activate(items[actionSelection]) }; return }
        if let submit = page?.submit { submit(); return }
        if model.pageID != .root && !showsFileResults { model.pageID = .root; return }
        if let row = selectedEntry { model.perform(row) }
    }
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
