import SwiftUI
import AppKit
import Combine
import KeylaneCore

struct Launcher: View {
    let model: Model
    @StateObject private var observation: ViewObservation
    @StateObject private var modifiers = LauncherModifiers()
    @State private var selection = LauncherResultSelection()
    @State private var selectionQuery = ""
    @State private var pageRevision = 0
    @State private var presentation = LauncherPagePresentation()
    @State private var presentedModuleActivation: LauncherModuleRegistry.Activation?
    private var moduleActivation: LauncherModuleRegistry.Activation? {
        model.launcherModules?.activation(forPage: model.pageID)
    }
    @State private var surfaceMounted = false
    @State private var dispatchedQuery: String?
    private var launcherVisible: Bool { presentation.visible }
    private var page: LauncherPage? { model.activeLauncherPage }
    private var showsFileResults: Bool { page?.contentPlacement == .fileResults }
    private var loading: AnyPublisher<Bool, Never>? {
        if model.pageID == .root {
            return model.searchesFilesHere ? model.fileSearch.$isSearching.eraseToAnyPublisher() : nil
        }
        return page?.loading
    }

    @State private var fileType = "all"
    private enum Menu { case application, actions, filter, sort }
    @State private var menu: Menu?
    private var actions: Bool { menu == .actions }
    private var appMenu: Bool { menu == .application }
    private var filterOpen: Bool { menu == .filter || menu == .sort }
    private var sortBinding: Binding<Bool> {
        Binding(get: { menu == .sort }, set: { open in
            closeMenus()
            if open { menu = .sort }
        })
    }
    private var filterBinding: Binding<Bool> {
        Binding(get: { menu == .filter }, set: { open in
            closeMenus()
            if open { menu = .filter }
        })
    }
    @State private var mainSearchQuery = ""
    @State private var mainSearchSelection = LauncherResultSelection()
    @State private var mainSearchExpanded = false
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
            ViewObservation.changes(model.$appearance),
            ViewObservation.changes(model.$interfaceSize),
            ViewObservation.changes(model.$windowMode),
            ViewObservation.changes(model.$compactExpanded),
            ViewObservation.changes(model.footerFeedback.$current),
            ViewObservation.changes(model.$presentedLauncherHeight),
            ViewObservation.changes(model.$compactFavorites),
            ViewObservation.changes(model.$favorites),
            ViewObservation.changes(model.$favoriteOrder),
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$usage),
            ViewObservation.changes(model.$excluded),
            ViewObservation.changes(model.$runningPaths),
            ViewObservation.changes(model.$navigation),
            ViewObservation.changes(model.$rootSearchSensitivity),
            ViewObservation.changes(model.$rootFileContentSearch),
            ViewObservation.changes(model.$fileResults),
            ViewObservation.changes(model.fileSearch.$isSearching),
            ViewObservation.changes(model.fileSearch.$browsingDirectory),
            ViewObservation.changes(model.fileSearch.$directorySort),
            ViewObservation.changes(model.$fileSearchStatus),
            ViewObservation.changes(model.fileSearch.$options.map { [$0.enabled, $0.searchFromLauncher] })
        ]))
    }

    private var rows: [Entry] {
        if showsFileResults { return model.fileEntries(ofType: fileType) }
        return model.pageID == .root ? model.commands : []
    }
    private var selectionIsCurrent: Bool {
        presentation.page == model.pageID && selectionQuery == model.query
    }

    private func selectionIndex(in results: [Entry]) -> Int? {
        guard selectionIsCurrent else { return nil }
        return selection.index(in: results, identifiedBy: \.commandID)
    }

    private func firstSelectable(_ results: [Entry]) -> CommandID? {
        guard let first = results.first,
              !(first.detail == "File" && model.fileSearch.isSearching) else { return nil }
        return first.commandID
    }

    private func resetResultSelection(to restored: LauncherResultSelection = .init()) {
        selectionQuery = model.query
        selection = restored
        selection.selectDefault(firstSelectable(rows))
    }

    private func activateResult(_ id: CommandID, selectOnly: Bool = false) {
        guard selectionIsCurrent, let row = rows.first(where: { $0.commandID == id }) else { return }
        selection.id = id
        if !selectOnly { model.perform(row) }
    }

    private var launcherSurface: some View {
        let results = rows
        let selectedIndex = selectionIndex(in: results)
        let showsSearchBar = argumentTarget == nil && page?.contentPlacement != .form
        let compactSurface = model.isCompact && model.presentedLauncherHeight <= model.launcherHeight + 0.5
        return ZStack(alignment: .top) {
            if let target = argumentTarget { argumentEditor(target).padding(.bottom, VisualStyle.launcherBottomInset) }
            else if compactSurface { Color.clear }
            else {
                if showsFileResults {
                    ResultDetailLayout(hasResults: !results.isEmpty) {
                        commandList(results, selectedIndex: selectedIndex)
                    } detail: {
                        FileSearchDetail(url: selectedIndex.map { URL(fileURLWithPath: results[$0].id) })
                    } emptyState: {
                        if model.fileSearch.isSearching {
                            Text("正在搜索文件…").font(VisualStyle.rowText).foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 12) {
                                ResultDetailEmptyState(title: model.query.isEmpty ? "搜索文件" : "没有匹配结果",
                                                       message: model.fileSearchStatus)
                                Button("选择搜索文件夹…", systemImage: "folder") {
                                    model.chooseFileSearchFolder(returnToLauncher: true)
                                }.buttonStyle(ContentActionButtonStyle())
                            }
                        }
                    }
                } else if model.pageID == .root {
                    commandList(results, selectedIndex: selectedIndex).frame(height: 470, alignment: .top)
                } else if let page, let content = page.content {
                    Group {
                        switch page.contentPlacement {
                        case .underChrome: content()
                        case .form: content().padding(.bottom, VisualStyle.launcherBottomInset)
                        case .inset, .fileResults:
                            content().padding(.top, VisualStyle.launcherTopInset).padding(.bottom, VisualStyle.launcherBottomInset)
                        }
                    }.id(moduleActivation?.id)
                }
            }
            if !compactSurface { VStack(spacing: 0) {
                if showsSearchBar {
                    ChromeBlur().frame(height: VisualStyle.launcherTopInset)
                        .mask(LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0),
                                                     .init(color: .black.opacity(0.7), location: 0.48),
                                                     .init(color: .clear, location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                }
                Spacer(minLength: 0)
                ChromeBlur().frame(height: 78)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.5), .init(color: .black.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom))
            }.allowsHitTesting(false) }
            // Keep the search field interactive while the blur's full-window spacer is inert.
            if showsSearchBar { VStack(spacing: 0) {
                searchBar
                if compactSurface && model.compactFavorites {
                    let favorites = model.compactFavoriteEntries
                    if !favorites.isEmpty { compactFavoritesBar(favorites) }
                }
                Spacer(minLength: 0)
            } }
            if actions || appMenu || filterOpen { Color.clear.contentShape(Rectangle()).onTapGesture { closeMenus() } }
            if !compactSurface { footer.frame(maxHeight: .infinity, alignment: .bottom) }
            if showsSearchBar && showsTypeFilter {
                typeFilter.frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(VisualStyle.launcherEdgeInset)
            }
        }
        .frame(width: VisualStyle.launcherWidth, height: model.presentedLauncherHeight, alignment: .top)
        .overlay(alignment: .top) {
            if launcherVisible, argumentTarget == nil, let loading {
                WindowLoadingIndicator(loading: loading).id(model.pageID)
            }
        }
        .scaleEffect(model.interfaceScale)
        .frame(width: VisualStyle.launcherWidth * model.interfaceScale, height: model.presentedLauncherHeight * model.interfaceScale)
        .scrollIndicators(.visible, axes: .vertical)

        .background { if reduceTransparency { Color(nsColor: .windowBackgroundColor) } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: actions)
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: appMenu)
        .background {
            Button("") { toggleMenu(application: false) }.keyboardShortcut("k", modifiers: .command).hidden().accessibilityHidden(true)
            Button("") { closeMenus(); model.runCommand(.init(rawValue: "settings"), origin: .menu) }.keyboardShortcut(",", modifiers: .command).hidden().accessibilityHidden(true)
            if let shortcutSubmit = page?.shortcutSubmit {
                Button("") { if page?.optionSubmit != nil { closeMenus() }; shortcutSubmit() }
                    .keyboardShortcut(.return, modifiers: .command).hidden().accessibilityHidden(true)
            }
            if let optionSubmit = page?.optionSubmit {
                Button("") { closeMenus(); optionSubmit() }.keyboardShortcut(.return, modifiers: .option).hidden().accessibilityHidden(true)
            }
            pageMenuShortcuts
            ForEach(0..<min(10, results.count), id: \.self) { index in
                Button("") { activateResult(results[index].commandID) }.keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: .command).hidden().accessibilityHidden(true)
            }
        }
        .onChange(of: firstSelectable(results), initial: true) { _, first in
            if selectionIsCurrent { selection.selectDefault(first) }
        }
        .clipShape(RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius, style: .continuous))
        .preferredColorScheme(model.colorScheme)
    }

    private var observedSurface: some View {
        Group {
            if surfaceMounted {
                launcherSurface
            } else {
                Color.clear
            }
        }
        .task(id: launcherVisible) {
            guard !launcherVisible, surfaceMounted, model.pageID == .root || showsFileResults else { return }
            // Keep fast hotkey toggles warm. The outer view retains query,
            // selection and page state independently of the rendered surface.
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            // Secondary pages keep their own scroll and editing state.
            guard !launcherVisible, model.pageID == .root || showsFileResults else { return }
            surfaceMounted = false
        }
        .onAppear {
            updatePresentation(visible: (NSApp.delegate as? Delegate)?.window?.isVisible == true)
            focusToken += 1
        }
        .onChange(of: model.windowMode) { _, _ in focusToken += 1 }
        .onDisappear { updatePresentation(visible: false) }
        .onExitCommand { if !SearchField.isComposing { escape() } }
        .onReceive(model.activePageUpdates) { _ in
            if launcherVisible { pageRevision &+= 1 }
        }
        .onReceive(model.launcherModules?.registrationUpdates ?? Empty().eraseToAnyPublisher()) { _ in
            if presentedModuleActivation != nil || moduleActivation != nil { pageRevision &+= 1 }
        }
        .onReceive(model.rootSearchUpdates) { _ in
            if launcherVisible && model.pageID == .root { pageRevision &+= 1 }
        }
        .onReceive(model.launcherModules?.presentationUpdates ?? Empty().eraseToAnyPublisher()) { _ in
            if launcherVisible && model.pageID == .root { pageRevision &+= 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShown)) { _ in
            if launcherVisible && presentation.page == model.pageID { closeMenus() }
            updatePresentation(visible: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherResetSearch)) { _ in
            mainSearchQuery = ""
            mainSearchSelection = .init()
            mainSearchExpanded = false
            if presentation.page == .root { resetResultSelection() }
            dismissArgumentEditor()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherHidden)) { _ in
            updatePresentation(visible: false)
        }
    }

    var body: some View {
        let _ = pageRevision
        observedSurface
        .onChange(of: fileType) { _, _ in resetResultSelection(); focusToken += 1 }
        .onChange(of: model.fileSearch.browsingDirectory) { _, directory in
            if directory == nil && menu == .sort { closeMenus() }
        }
        .onChange(of: model.query) { _, _ in
            guard presentation.page == model.pageID else { return }
            if showsFileResults && FileSearchLocation.typedURL(model.query) != nil { fileType = "all" }
            if launcherVisible { refreshActiveQuery() }
            if selectionQuery != model.query { resetResultSelection() }
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
            if model.pageID == .root { resetResultSelection() }
        }
        .onChange(of: model.pageID) { _, _ in updatePresentation(visible: launcherVisible) }
        .onChange(of: moduleActivation?.id) { _, _ in updatePresentation(visible: launcherVisible) }
    }

    private func updatePresentation(visible: Bool) {
        let wasVisible = launcherVisible
        let current = model.pageID
        let activation = moduleActivation
        let previousActivation = presentedModuleActivation
        let change = presentation.update(page: current, visible: visible, activationID: activation?.id)
        presentedModuleActivation = activation
        if wasVisible != visible {
            if visible {
                surfaceMounted = true
                modifiers.start()
                model.launcherModules?.launcherShown()
            } else {
                modifiers.stop()
                model.launcherModules?.launcherHidden()
            }
        }
        if wasVisible != visible || change.previousPage != nil { closeMenus() }
        if let previous = change.deactivation {
            dispatchedQuery = nil
            if previous == .root {
                model.fileSearch.cancel()
                FilePreview.shared.dismiss()
            } else if let previousActivation {
                model.leaveRegisteredPage(previous, activation: previousActivation)
            } else if let previousPage = model.launcherModules?.page(previous, includingInactive: true) {
                previousPage.leave()
                previousPage.releasePreview?()
            }
        }

        if let previous = change.previousPage {
            dismissArgumentEditor()
            if previous == .root {
                mainSearchQuery = model.query
                mainSearchSelection = selection
                mainSearchExpanded = model.compactExpanded
            }
            if current == .root {
                model.query = mainSearchQuery
                model.compactExpanded = mainSearchExpanded
            } else {
                model.query = ""
            }
        }

        if change.activation != nil, let page, let activation {
            model.trackRegisteredPage(page, activation: activation)
        }
        switch change.activation {
        case .enter:
            if let seed = page?.enter?(model.query) {
                if showsFileResults { fileType = "all" }
                model.query = seed
            }
            refreshActiveQuery()
        case .resume:
            if let resume = page?.resume {
                dispatchedQuery = model.query
                resume()
            } else { refreshActiveQuery() }
        case nil:
            break
        }
        if change.previousPage != nil {
            resetResultSelection(to: current == .root ? mainSearchSelection : .init())
        } else if change.activation != nil, selectionQuery != model.query {
            resetResultSelection()
        }
    }

    private func refreshActiveQuery() {
        guard dispatchedQuery != model.query else { return }
        dispatchedQuery = model.query
        if let page { page.queryChanged(model.query) }
        else if model.pageID == .root { model.searchFiles() }
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
            guard selectionIsCurrent else { return }
            selection.move(by: delta, in: rows, identifiedBy: \.commandID)
        }
    }
    private func escape() {
        if submenu != nil { dismissSubmenu(); return }
        if argumentTarget != nil { dismissArgumentEditor(); focusToken += 1; return }
        if actions || appMenu || filterOpen { closeMenus() }
        else if model.pageID != .root && model.launcherEscapeBehavior == .backOrClose { model.pageID = .root }
        else { (NSApp.delegate as? Delegate)?.hideLauncher() }
    }

    private func compactFavoritesBar(_ favorites: [Entry]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(favorites) { row in
                    Button { model.perform(row) } label: {
                        Group {
                            if let artwork = model.launcherModules?.artwork(for: row) { artwork }
                            else if row.id.hasSuffix(".app") { WorkspaceItemIcon(path: row.id) }
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
                Color.clear.frame(width: showsFileResults && model.fileSearch.browsingDirectory != nil ? 312 : page?.typeFilterWidth ?? 138, height: 36)
                    .accessibilityHidden(true)
            }
        }.padding(.horizontal, model.pageID == .root ? 19 : VisualStyle.launcherEdgeInset)
            .frame(height: model.pageID == .root ? 61 : VisualStyle.launcherControlDiameter + 2 * VisualStyle.launcherEdgeInset)
            .frame(height: 61, alignment: .top)
    }
    @ViewBuilder private var typeFilter: some View {
        if showsFileResults {
            HStack(alignment: .top, spacing: 8) {
                if let directory = model.fileSearch.browsingDirectory {
                    Button("上一级文件夹", systemImage: "arrow.up") {
                        closeMenus()
                        model.showFileLocation(directory.deletingLastPathComponent(), browse: true)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 30, height: VisualStyle.launcherControlDiameter)
                    .help("上一级文件夹")
                    ResultTypeFilter(selection: Binding(
                        get: { model.fileSearch.directorySort.rawValue },
                        set: { if let sort = FileDirectorySort(rawValue: $0) { model.fileSearch.setDirectorySort(sort) } }
                    ), options: FileDirectorySort.allCases.map {
                        .init(id: $0.rawValue, title: $0.title, symbol: "arrow.up.arrow.down")
                    }, open: sortBinding, navigation: model.navigation, width: 128, searchPlaceholder: "查找排序方式…")
                }
                ResultTypeFilter(selection: $fileType, options: ResultFilterOption.files, open: filterBinding, navigation: model.navigation)
            }
        } else if let filter = page?.typeFilter { filter(filterBinding) }
    }
    private func commandList(_ results: [Entry], selectedIndex: Int?) -> some View {
        SelectableResultList(selection: selectedIndex.map { results[$0].commandID },
                             query: model.query, firstResult: results.first?.commandID,
                             revealInitialSelection: true) {
            if results.isEmpty && !showsFileResults {
                ResultDetailEmptyState(message: FileSearchLocation.typedURL(model.query) != nil
                    && model.fileSearch.lastPublishedQuery == model.query
                    ? model.fileSearchStatus : "试试应用名称、拼音或计算表达式")
                    .frame(maxWidth: .infinity).padding(.top, 80)
            }
            ForEach(Array(results.enumerated()), id: \.element.commandID) { index, row in
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
                ResultListButton(id: row.commandID, action: {
                    activateResult(row.commandID, selectOnly: showsFileResults)
                }) {
                    if row.id == "calculator" {
                        CalculatorResultCard(expression: model.query, result: row.name, selected: index == selectedIndex, conversionDetail: row.detail == "回车复制结果" ? nil : row.detail)
                    } else if showsFileResults {
                        fileResultRow(row, selected: index == selectedIndex)
                    } else {
                        resultRow(row, index: index, selected: index == selectedIndex)
                    }
                }
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
    private func fileResultRow(_ row: Entry, selected: Bool) -> some View {
        let url = URL(fileURLWithPath: row.id)
        let isFolder = row.isDirectory
        return ResultListRow(selected: selected, height: isFolder || row.subtitle != nil ? 48 : 40) {
            WorkspaceItemIcon(path: row.id, fallbackSymbol: isFolder ? "folder" : "doc")
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                HighlightedResultText(text: row.name, query: model.query)
                    .font(VisualStyle.rowText).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if isFolder {
                    Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
            }
        }.help(url.path)
    }
    private func resultRow(_ row: Entry, index: Int, selected: Bool) -> some View {
        ResultListRow(selected: selected, layout: .root) {
            Group {
                if let artwork = model.launcherModules?.artwork(for: row) { artwork }
                else if row.id.hasSuffix(".app") || row.detail == "File" {
                    WorkspaceItemIcon(path: row.id, fallbackSymbol: row.detail == "File" ? (row.isDirectory ? "folder" : "doc") : "app")
                        // AppKit application icons include transparent margins.
                        .scaleEffect(row.id.hasSuffix(".app") ? 1.2 : 1)
                }
                else { Image(systemName: row.symbol).font(.system(size: 21, weight: .regular)).foregroundStyle(iconColor(row.id)) }
            }
            .frame(width: 26, height: 26)
            .overlay(alignment: .bottom) {
                if model.runningPaths.contains(row.id) {
                    Circle()
                        .fill(Color.primary.opacity(0.78))
                        .frame(width: 4, height: 4)
                        .offset(y: 6)
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
    private func iconColor(_ id: String) -> Color { switch id { case "clipboard": return .orange; case "screenshot": return .purple; case "quicklink": return .blue; default: return .primary.opacity(0.8) } }
    private static let footerMenuWidth: CGFloat = 345
    private static let footerMinimumGap: CGFloat = 24

    private var footer: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                expandingControl(application: true)
                Spacer(minLength: Self.footerMinimumGap)
                expandingControl(application: false)
            }
        }.padding(.horizontal, VisualStyle.launcherEdgeInset).padding(.bottom, VisualStyle.launcherEdgeInset)
    }
    private func expandingControl(application: Bool) -> some View {
        let secondary = page?.badge != nil
        let badgeTitle = page?.badgeTitle?() ?? page?.badge?.title ?? ""
        let badgeSymbol = page?.badge?.symbol ?? ""
        let menuTitle = page?.badgeActions == nil ? "Keylane 菜单" : "\(badgeTitle)菜单"
        let feedback = application ? model.footerFeedback.current : nil
        let preferredApplicationWidth = feedback.map { LauncherFooterFeedbackLabel.width(for: $0.label) }
            ?? (secondary ? min(420, SecondaryPageBadge.width(for: badgeTitle)) : 36)
        let showsActions = page?.contentPlacement != .form || !menuItems(applicationMenu: false).isEmpty
        let primaryLabel = LauncherFooterButtonLabel(title: primaryTitle,
            keys: page?.contentPlacement == .form && page?.shortcutSubmit != nil ? ["⌘", "↩"] : ["↩"])
        let actionsLabel = LauncherFooterButtonLabel(title: "操作", keys: ["⌘", "K"])
        let actionsWidth = showsActions ? actionsLabel.width : 0
        let capsuleInset: CGFloat = 4
        let maximumActionWidth: CGFloat = page?.maximumActionWidth ?? (showsActions ? 196 : 126)
        let primaryWidth = min(primaryLabel.width, max(0, maximumActionWidth - actionsWidth - 2 * capsuleInset))
        let actionWidth = primaryWidth + actionsWidth + 2 * capsuleInset
        let rightWidth = actions ? Self.footerMenuWidth : actionWidth
        let availableApplicationWidth = VisualStyle.launcherWidth - 2 * VisualStyle.launcherEdgeInset
            - Self.footerMinimumGap - rightWidth
        let applicationWidth = min(preferredApplicationWidth, availableApplicationWidth)
        let primaryEnabled = application || primaryActionEnabled
        let open = application ? appMenu : actions
        let alignment: Alignment = application ? .bottomLeading : .bottomTrailing
        let items = open ? filteredMenu(applicationMenu: application) : []
        let menuHeight = menuRowsHeight(items) + 87
        return ZStack(alignment: alignment) {
            if open {
                menuPanel(applicationMenu: application, items: items)
                    .frame(width: Self.footerMenuWidth, height: menuHeight, alignment: .bottom)
                    .transition(.opacity)
            } else if let feedback {
                NativeHoverButton(title: feedback.actionTitle == nil ? "\(feedback.message) · 打开\(menuTitle)" : feedback.label, action: {
                    if feedback.actionTitle != nil { model.footerFeedback.performAction() }
                    else { toggleMenu(application: true) }
                }) {
                    LauncherFooterFeedbackLabel(feedback: feedback)
                }
                .frame(width: applicationWidth, height: 36)
                .transition(.opacity)
            } else if application && secondary {
                NativeHoverButton(title: "打开\(menuTitle)", action: { toggleMenu(application: true) }) {
                    SecondaryPageBadge(title: badgeTitle, symbol: badgeSymbol,
                                       artwork: model.launcherModules?.module(forPage: model.pageID).flatMap(ModuleArtwork.module))
                }.frame(width: applicationWidth, height: 36).transition(.opacity)
            } else if application {
                NativeHoverButton(title: "Keylane 菜单", action: { toggleMenu(application: true) }) {
                    Image(systemName: "text.menu").font(.system(size: 16)).frame(width: 36, height: 36)
                }.frame(width: 36, height: 36).clipShape(Circle()).transition(.opacity)
            } else {
                HStack(spacing: 0) {
                    NativeHoverButton(title: primaryLabel.title, action: { run() }) {
                        primaryLabel
                    }
                    .frame(width: primaryWidth, height: 28)
                    .disabled(!primaryEnabled)
                    .opacity(primaryEnabled ? 1 : 0.45)
                    if showsActions {
                        NativeHoverButton(title: actionsLabel.title, action: { toggleMenu(application: false) }) {
                            actionsLabel
                        }.frame(width: actionsWidth, height: 28)
                    }
                }.padding(capsuleInset).frame(width: actionWidth, height: 36).transition(.opacity)
            }
        }
        // The container remains in the same hierarchy. Only its size changes; its bottom
        // corner stays fixed. No matched-position or automatic glass transition can slide it.
        .frame(width: open ? Self.footerMenuWidth : (application ? applicationWidth : actionWidth), height: open ? menuHeight : 36, alignment: alignment)
        .modifier(LauncherMenuSurface(open: open, tint: open ? nil : feedback?.style.color.opacity(0.16)))
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: feedback?.message)
    }
    private var pageMenuShortcuts: some View {
        let entryActions: [LauncherAction]
        if page?.actionShortcutsEnabled == true {
            entryActions = page?.actions?() ?? []
        } else if page == nil, !appMenu, submenu == nil, argumentTarget == nil,
                  let entry = selectedEntry, entry.commandID.rawValue.hasPrefix("app:") {
            entryActions = model.applicationResultActions.shortcutActions(for: entry, model: model)
        } else {
            entryActions = []
        }
        return ForEach((page?.badgeActions?() ?? []) + entryActions) { action in
            let modifiers = action.keys.dropLast()
            if action.enabled, !modifiers.isEmpty, let key = action.keys.last,
               !usesPageSubmitShortcut(key: key, modifiers: modifiers),
               let character = key.lowercased().first {
                pageMenuShortcut(action, key: character, modifiers: modifiers)
            }
        }
    }

    private func usesPageSubmitShortcut(key: String, modifiers: ArraySlice<String>) -> Bool {
        guard key == "↩" else { return false }
        return (modifiers.elementsEqual(["⌘"]) && page?.shortcutSubmit != nil)
            || (modifiers.elementsEqual(["⌥"]) && page?.optionSubmit != nil)
    }

    private func pageMenuShortcut(_ action: MenuAction, key: Character, modifiers: ArraySlice<String>) -> some View {
        var flags: EventModifiers = []
        if modifiers.contains("⌘") { flags.insert(.command) }
        if modifiers.contains("⌥") { flags.insert(.option) }
        if modifiers.contains("⌃") { flags.insert(.control) }
        if modifiers.contains("⇧") { flags.insert(.shift) }
        return Button("") {
            if action.submenu != nil, !actions { toggleMenu(application: false) }
            activate(action)
        }
        .keyboardShortcut(key == "↩" ? .return : KeyEquivalent(key), modifiers: flags)
        .hidden()
        .accessibilityHidden(true)
    }

    private typealias MenuAction = LauncherAction
    private var selectedEntry: Entry? {
        let results = rows
        return selectionIndex(in: results).map { results[$0] }
    }
    private func menuItems(applicationMenu: Bool) -> [MenuAction] {
        if applicationMenu {
            if let badgeActions = page?.badgeActions { return badgeActions() }
            return [
                MenuAction(id: "about", title: "关于 Keylane", icon: "app.badge", perform: { model.openSettings(page: "about") }),
                MenuAction(id: "settings", title: "设置…", icon: "gearshape", keys: ["⌘", ","], perform: { model.runCommand(.init(rawValue: "settings"), origin: .menu) }),
                MenuAction(id: "clipboard", title: "剪贴板历史", icon: "list.clipboard", perform: { model.runCommand(.init(rawValue: "clipboard"), origin: .menu) }),
                MenuAction(id: "hide", title: "隐藏 Keylane", icon: "rectangle.compress.vertical", keys: ["esc"], perform: { (NSApp.delegate as? Delegate)?.hideLauncher() }),
                MenuAction(id: "quit", title: "退出 Keylane", icon: "rectangle.portrait.and.arrow.right", perform: { NSApp.terminate(nil) })
            ].filter { model.launcherModules?.isCommandModuleEnabled(CommandID(rawValue: $0.id)) != false }
        }
        if let submenu {
            return [MenuAction(id: "back", title: "返回", icon: "chevron.left", perform: dismissSubmenu)] + submenu.items
        }
        if let page, !showsFileResults { return page.actions?() ?? [] }
        guard let row = selectedEntry else { return [] }
        var actions = model.launcherModules?.actions(for: row) ?? [
            MenuAction(id: "open", title: "执行命令", icon: "return", keys: ["↩"]) {
                model.runCommand(row.commandID, origin: .menu, usageKey: row.id)
            },
            model.favoriteAction(for: row)
        ]
        if model.pageID == .root, !row.commandID.rawValue.hasPrefix("app:") {
            actions.append(contentsOf: model.favoriteOrderActions(for: row.id))
        }
        if model.pageID == .root, model.usage[row.id, default: 0] > 0,
           !actions.contains(where: { $0.id == "reset-ranking" }) {
            actions.append(model.resetRankingAction(for: row))
        }
        return actions
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
    private func filteredMenu(applicationMenu: Bool) -> [MenuAction] {
        menuItems(applicationMenu: applicationMenu).filter {
            actionQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(actionQuery)
                || $0.value?.localizedCaseInsensitiveContains(actionQuery) == true
        }
    }
    private func menuRowsHeight(_ items: [MenuAction]) -> CGFloat {
        guard !items.isEmpty else { return 48 }
        let breaks = zip(items, items.dropFirst()).filter { $0.group != $1.group }.count
        return min(320, CGFloat(items.count * 39 + breaks * 9))
    }

    private func menuPanel(applicationMenu: Bool, items: [MenuAction]) -> some View {
        let title: String
        if applicationMenu, page?.badgeActions != nil {
            title = page?.badgeTitle?() ?? page?.badge?.title ?? ""
        } else if applicationMenu {
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
            title = "Keylane " + version
        } else {
            let base = page?.actionContextTitle?() ?? page?.actionTitle ?? selectedEntry?.name ?? "操作"
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
                                                enabled: item.enabled, destructive: item.destructive, artwork: item.artwork,
                                                activate: { activate(item) }, highlight: { actionSelection = index }) {
                                    if let value = item.value {
                                        Text(value).font(VisualStyle.rowText).foregroundStyle(.secondary)
                                            .lineLimit(1).help(value)
                                    }
                                    if !item.keys.isEmpty { Keycaps(keys: item.keys) }
                                    if item.submenu != nil {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                    }
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
            SearchField(text: $actionQuery, placeholder: "搜索操作…", focusToken: focusToken, wantsFocus: actions || appMenu, compact: true, navigation: model.navigation, submit: {
                if items.indices.contains(actionSelection) { activate(items[actionSelection]) }
            }, move: moveSelection, escape: escape, back: { escape() }, forward: {
                if items.indices.contains(actionSelection), items[actionSelection].submenu != nil { activate(items[actionSelection]) }
            }).frame(height: 22).padding(.horizontal, 16).padding(.vertical, 10)
                .onChange(of: actionQuery) { _, _ in actionSelection = items.firstIndex(where: \.enabled) ?? 0 }
        }.frame(width: Self.footerMenuWidth)
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
    private var primaryActionEnabled: Bool {
        guard presentation.page == model.pageID else { return false }
        if argumentTarget != nil { return true }
        if model.pageID == .root || showsFileResults {
            guard let row = selectedEntry else { return false }
            return row.detail != "File" || !model.fileSearch.isSearching
        }
        return page?.primaryEnabled?() != false
    }

    private var primaryTitle: String {
        if argumentTarget != nil { return "启动新实例" }
        if let title = page?.primaryTitle?() { return title }
        if let row = selectedEntry {
            if let title = model.launcherModules?.primaryTitle(for: row) { return title }
            if row.id == "calculator" { return "复制结果" }
        }
        return model.pageID == .root || showsFileResults ? "打开" : "返回"
    }
    private func dismissArgumentEditor() {
        argumentTarget = nil
        argumentText = ""
        argumentsFocused = false
    }

    private func argumentEditor(_ target: LauncherAction.ArgumentForm) -> some View {
        LauncherCreationForm(back: {
            dismissArgumentEditor()
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
        guard presentation.page == model.pageID else { return }
        if let target = argumentTarget {
            do { target.submit(try ArgumentParser.parse(argumentText)) }
            catch { model.error = "参数引号或转义未完成。" }
            return
        }
        if (showsFileResults || selectedEntry?.detail == "File"), model.fileSearch.isSearching { return }
        if actions || appMenu {
            let items = filteredMenu(applicationMenu: appMenu)
            if items.indices.contains(actionSelection) { activate(items[actionSelection]) }
            return
        }
        if let submit = page?.submit { submit(); return }
        if model.pageID != .root && !showsFileResults { model.pageID = .root; return }
        if let row = selectedEntry { model.perform(row) }
    }
}

private struct LauncherFooterButtonLabel: View {
    let title: String
    let keys: [String]
    private let fontSize: CGFloat = 13
    private let titleSpacing: CGFloat = 7
    private let keySpacing: CGFloat = 3
    private let horizontalPadding: CGFloat = 10

    var width: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let keyWidth = CGFloat(keys.count) * Keycap.side + CGFloat(keys.count - 1) * keySpacing
        return titleWidth + titleSpacing + keyWidth + 2 * horizontalPadding
    }

    var body: some View {
        HStack(spacing: titleSpacing) {
            Text(title).lineLimit(1).truncationMode(.tail)
            HStack(spacing: keySpacing) {
                ForEach(keys, id: \.self) { Keycap(text: $0) }
            }.fixedSize()
        }
        .font(.system(size: fontSize, weight: .medium))
        .padding(.horizontal, horizontalPadding)
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
