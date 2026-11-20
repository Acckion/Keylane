import SwiftUI
import AppKit
import Combine
import KeylaneCore

@Observable
private final class LauncherSwipeMotion {
    var offset: CGFloat = 0
}

private struct LauncherSwipeOffset: ViewModifier {
    let motion: LauncherSwipeMotion
    var spacing: CGFloat = 0
    var isSettled = false

    func body(content: Content) -> some View {
        content.offset(x: isSettled ? 0 : motion.offset + spacing)
    }
}

struct Launcher: View {
    let model: Model
    @StateObject private var observation: ViewObservation
    @StateObject private var modifiers = LauncherModifiers()
    @State private var selection = LauncherResultSelection()
    @State private var selectionQuery = ""
    @State private var pageRevision = 0
    @State private var presentation = LauncherPagePresentation()
    @State private var pageHistory = LauncherPageHistory()
    @State private var presentedModuleActivation: LauncherModuleRegistry.Activation?
    private var moduleActivation: LauncherModuleRegistry.Activation? {
        model.launcherModules?.activation(forPage: model.pageID)
    }
    @State private var surfaceMounted = false
    @State private var pageSwipeMotion = LauncherSwipeMotion()
    @State private var pageSwipeNeighbor: PageID?
    @State private var pageSwipeDirection = 1
    @State private var swipeFiles: [SpotlightFile]?
    @State private var swipeClips: [ClipItem]?
    @State private var pageSwipeTransition: UUID?
    @State private var pageSwipeAwaitingContent = false
    @State private var pageSwipePreviewOpacity = 1.0
    @State private var dispatchedQuery: String?
    private var launcherVisible: Bool { presentation.visible }
    private var page: LauncherPage? { model.activeLauncherPage }
    private var showsFileResults: Bool { page?.contentPlacement == .fileResults }
    private var showsReadingDetail: Bool { page?.contentPlacement == .readingDetail }
    private var showsRecentFiles: Bool {
        showsFileResults && model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var loading: AnyPublisher<Bool, Never>? {
        if model.pageID == .root {
            return model.searchesFilesHere ? model.fileSearch.$isSearching.eraseToAnyPublisher() : nil
        }
        return page?.loading
    }

    @State private var fileType = "all"
    private enum Menu { case application, actions, filter, sort }
    @State private var menu: Menu?
    @State private var inlineEmojiTarget: (query: String, range: NSRange)?
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
    @State private var actionSelectionID: String?
    @State private var menuContext: LauncherPagePresentation.ActionContext?
    @State private var focusToken = 0
    @State private var submenuPath: [String] = []
    @State private var argumentTarget: LauncherAction.ArgumentForm?
    @State private var argumentText = ""
    @FocusState private var argumentsFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.aiInteraction.$rootTab),
            ViewObservation.changes(model.aiInteraction.$rootFallback),
            ViewObservation.changes(model.aiSettings.$state),
            ViewObservation.changes(model.$pageID),
            ViewObservation.changes(model.$query),
            ViewObservation.changes(model.scripts.$rootArgumentScript),
            ViewObservation.changes(model.$appearance),
            ViewObservation.changes(model.$interfaceSize),
            ViewObservation.changes(model.$windowMode),
            ViewObservation.changes(model.$compactExpanded),
            ViewObservation.changes(model.footerFeedback.$current),
            ViewObservation.changes(model.$presentedLauncherHeight),
            ViewObservation.changes(model.$compactBarMergeProgress),
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

    private var rootScriptArguments: ScriptCommand? {
        model.pageID == .root ? model.scripts.rootArgumentScript : nil
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
        if rootScriptArguments != nil { model.scripts.cancelRootArguments() }
        selection.id = id
        if !selectOnly { performRootEntry(row) }
    }

    private var launcherSurface: some View {
        let results = rows
        let selectedIndex = selectionIndex(in: results)
        let showsSearchBar = argumentTarget == nil && page?.contentPlacement != .form && page?.contentPlacement != .conversation
        let compactSurface = model.presentedLauncherHeight <= VisualStyle.launcherTopInset + 0.5
        let reveal = model.launcherBackdropOpacity
        return ZStack(alignment: .top) {
            Group {
                if let target = argumentTarget { argumentEditor(target) }
                else if compactSurface { Color.clear }
                else {
                    if showsFileResults {
                        ResultDetailLayout(hasResults: !results.isEmpty) {
                            commandList(results, selectedIndex: selectedIndex)
                        } detail: {
                            FileSearchDetail(url: selectedIndex.map { URL(fileURLWithPath: results[$0].id) })
                        } emptyState: {
                            if model.fileSearch.isSearching {
                                Text(showsRecentFiles ? "正在载入最近使用的文件…" : "正在搜索文件…")
                                    .font(VisualStyle.rowText).foregroundStyle(.secondary)
                            } else {
                                VStack(spacing: 12) {
                                    let filtered = fileType != "all" && !model.fileResults.isEmpty
                                    ResultDetailEmptyState(title: showsRecentFiles ? "最近使用" : "没有匹配结果",
                                                           message: filtered ? "没有符合当前类型的文件。" : model.fileSearchStatus)
                                    if !filtered {
                                        Button("选择搜索文件夹…", systemImage: "folder") {
                                            model.chooseFileSearchFolder(returnToLauncher: true)
                                        }.buttonStyle(ContentActionButtonStyle())
                                    }
                                }
                            }
                        }
                    } else if model.pageID == .root {
                        commandList(results, selectedIndex: selectedIndex).frame(height: 470, alignment: .top)
                    } else if let page, let content = page.content {
                        Group {
                            switch page.contentPlacement {
                            case .underChrome: content()
                            case .readingDetail:
                                ScrollView {
                                    content()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, VisualStyle.launcherEdgeInset)
                                }
                                .launcherScrollInsets()
                                .launcherScrollEdgeFade()
                            case .form, .conversation:
                                content()
                                    .environment(\.conversationInputEnabled, menu == nil)
                                    .environment(\.conversationInputFocusToken, focusToken)
                            case .inset, .fileResults:
                                content().padding(.top, VisualStyle.launcherTopInset).padding(.bottom, VisualStyle.launcherBottomInset)
                            }
                        }.id(moduleActivation?.id)
                    }
                }
            }
            .opacity(reveal)
            if !compactSurface && page?.fullBleed != true { VStack(spacing: 0) {
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
            }.opacity(reveal).allowsHitTesting(false) }
            // Keep the search field interactive while the blur's full-window spacer is inert.
            if showsSearchBar { VStack(spacing: 0) {
                launcherSearchBar(compactSurface: compactSurface)
                Spacer(minLength: 0)
            } }
            if actions || appMenu || filterOpen { Color.clear.contentShape(Rectangle()).onTapGesture { closeMenus() } }
            if model.presentedLauncherHeight >= VisualStyle.launcherTopInset + VisualStyle.launcherBottomInset {
                footer.frame(maxHeight: .infinity, alignment: .bottom)
                    .opacity(reveal)
            }
            if showsSearchBar && showsTypeFilter {
                typeFilter.frame(maxWidth: .infinity, alignment: .topTrailing)
                    .padding(VisualStyle.launcherEdgeInset)
            }
            if let insertion = inlineEmojiTarget {
                Color.clear.contentShape(Rectangle()).onTapGesture { closeMenus() }
                EmojiInlinePicker(controller: model.emoji, navigation: model.navigation, choose: { glyph in
                    if model.query == insertion.query, let target = Range(insertion.range, in: model.query) {
                        model.query.replaceSubrange(target, with: glyph)
                    }
                    closeMenus()
                }, dismiss: closeMenus)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 48)
                .padding(.top, VisualStyle.launcherTopInset)
            }
        }
        .modifier(LauncherSwipeOffset(motion: pageSwipeMotion))
        .opacity(pageSwipeAwaitingContent ? 1 - pageSwipePreviewOpacity : 1)
        .overlay(alignment: .topLeading) {
            if let pageSwipeNeighbor {
                pageSwipePreview(pageSwipeNeighbor)
                    .frame(width: VisualStyle.launcherWidth, height: model.presentedLauncherHeight)
                    .modifier(LauncherSwipeOffset(motion: pageSwipeMotion,
                                                  spacing: CGFloat(pageSwipeDirection) * pageSwipeStride,
                                                  isSettled: pageSwipeAwaitingContent))
                    .opacity(pageSwipePreviewOpacity)
            }
        }
        .frame(width: VisualStyle.launcherWidth, height: model.presentedLauncherHeight, alignment: .top)
        .clipped()
        .overlay(alignment: .top) {
            if launcherVisible, argumentTarget == nil, let loading {
                WindowLoadingIndicator(loading: loading).id(model.pageID)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if page?.contentPlacement == .conversation, menu == nil, let feedback = model.footerFeedback.current {
                NativeHoverButton(title: feedback.label, action: {
                    if feedback.actionTitle != nil { model.footerFeedback.performAction() }
                    else { model.footerFeedback.clear() }
                }) {
                    LauncherFooterFeedbackLabel(feedback: feedback)
                }
                .frame(width: LauncherFooterFeedbackLabel.width(for: feedback.label),
                       height: VisualStyle.launcherControlDiameter)
                .modifier(LauncherMenuSurface(open: false, tint: feedback.style.color.opacity(0.16)))
                .padding(.horizontal, VisualStyle.launcherEdgeInset)
                .padding(.bottom, VisualStyle.launcherBottomInset + 6)
            }
        }
        .scaleEffect(model.interfaceScale)
        .frame(width: VisualStyle.launcherWidth * model.interfaceScale, height: model.presentedLauncherHeight * model.interfaceScale)
        .scrollIndicators(.visible, axes: .vertical)

        .background { if reduceTransparency && !compactSurface { Color(nsColor: .windowBackgroundColor) } }
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: actions)
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: appMenu)
        .background {
            if rootScriptArguments == nil {
                Button("") { toggleMenu(application: false) }.keyboardShortcut("k", modifiers: .command).hidden().accessibilityHidden(true)
                Button("") { closeMenus(); model.runCommand(.init(rawValue: "settings"), origin: .menu) }.keyboardShortcut(",", modifiers: .command).hidden().accessibilityHidden(true)
            }
            if let page {
                ForEach(LauncherPage.ReturnKey.allCases, id: \.self) { key in
                    if page.returnBindings.contains(key), key != .plain || menu == nil {
                        Button("") { submitReturn(key, on: page.id) }
                            .keyboardShortcut(key.shortcut)
                            .hidden().accessibilityHidden(true)
                    }
                }
            }
            if rootScriptArguments == nil {
                pageMenuShortcuts
                ForEach(0..<min(10, results.count), id: \.self) { index in
                    Button("") { activateResult(results[index].commandID) }.keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: .command).hidden().accessibilityHidden(true)
                }
            }
        }
        .onChange(of: firstSelectable(results), initial: true) { _, first in
            if selectionIsCurrent { selection.selectDefault(first) }
        }
        .onChange(of: results.first?.isFallback == true ? results.map(\.commandID) : []) { _, _ in
            // An async match or a settings change may replace the selected fallback.
            if selectionIsCurrent, selectionIndex(in: results) == nil {
                selection.id = firstSelectable(results)
            }
        }
        .onChange(of: showsRecentFiles ? results.map(\.commandID) : []) { _, ids in
            if showsRecentFiles, selectionIsCurrent, let selected = selection.id, !ids.contains(selected) {
                selection.id = firstSelectable(results)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: VisualStyle.launcherCornerRadius, style: .continuous))
        .keylaneTheme(backgroundOpacity: model.launcherBackdropOpacity)
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
        .task(id: launcherVisible ? model.pageID : nil) {
            guard launcherVisible, !showsFileResults else { return }
            let files = await model.fileSearch.recentForLauncherSwipe()
            if !Task.isCancelled { swipeFiles = files }
        }
        .task(id: launcherVisible && !model.isCompact) {
            guard launcherVisible, !model.isCompact else { return }
            let clips = await model.clipboard.recentForLauncherSwipe()
            if !Task.isCancelled { swipeClips = clips }
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
        .task(id: pageSwipeReadyToReveal ? pageSwipeTransition : nil) {
            guard pageSwipeReadyToReveal, let transition = pageSwipeTransition else { return }
            // Give the result selection update a turn before revealing the active page.
            await Task.yield()
            guard !Task.isCancelled, pageSwipeTransition == transition, pageSwipeReadyToReveal else { return }
            withAnimation(.easeOut(duration: 0.08), completionCriteria: .logicallyComplete) {
                pageSwipePreviewOpacity = 0
            } completion: {
                if pageSwipeTransition == transition { clearPageSwipe() }
            }
        }
        .onReceive(model.clipboard.$searching.combineLatest(model.clipboard.$loadingDetail)) { _ in
            if pageSwipeAwaitingContent, pageSwipeNeighbor == model.pageID { pageRevision &+= 1 }
        }
        .onAppear {
            updatePresentation(visible: (NSApp.delegate as? Delegate)?.window?.isVisible == true)
            focusToken += 1
            ((NSApp.delegate as? Delegate)?.window as? LauncherPanel)?.cancelWithoutFocusedView = {
                guard launcherVisible else { return false }
                escape()
                return true
            }
        }
        .onChange(of: model.windowMode) { _, _ in focusToken += 1 }
        .onDisappear {
            ((NSApp.delegate as? Delegate)?.window as? LauncherPanel)?.cancelWithoutFocusedView = nil
            updatePresentation(visible: false)
        }
        .onExitCommand { if !SearchField.isComposing { escape() } }
        .onReceive(model.launcherPageSwipes, perform: handlePageSwipe)
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
            pageHistory = .init()
            mainSearchQuery = ""
            mainSearchSelection = .init()
            mainSearchExpanded = false
            if presentation.page == .root { resetResultSelection() }
            dismissArgumentEditor()
            cancelRootScriptArguments()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherHidden)) { _ in
            clearPageSwipe()
            swipeFiles = nil
            swipeClips = nil
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
            if rootScriptArguments != nil { cancelRootScriptArguments() }
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
        .onChange(of: menuContext == nil ? nil : currentMenuContext) { _, value in
            if menuContext != nil, menuContext != value { closeMenus() }
        }
        .onChange(of: model.pageID) { _, _ in
            if pageSwipeAwaitingContent, pageSwipeNeighbor != model.pageID {
                clearPageSwipe()
            } else if pageSwipeTransition == nil, pageSwipeMotion.offset != 0 {
                settlePageSwipe()
            }
            updatePresentation(visible: launcherVisible)
        }
        .onChange(of: rootScriptArguments) { _, _ in closeMenus() }
        .onChange(of: moduleActivation?.id) { _, _ in updatePresentation(visible: launcherVisible) }
    }

    private func handlePageSwipe(_ event: Model.LauncherPageSwipe) {
        guard launcherVisible, presentation.page == model.pageID, pageSwipeTransition == nil else { return }
        guard menu == nil, argumentTarget == nil, rootScriptArguments == nil else {
            settlePageSwipe()
            return
        }
        let destinations = model.swipeDestinations
        guard let current = destinations.firstIndex(where: { $0.page == model.pageID }) else { return }
        switch event {
        case let .drag(distance):
            guard !reduceMotion else { return }
            let step = distance < 0 ? 1 : -1
            let next = current + step
            let points = distance / model.interfaceScale
            let neighbor = destinations.indices.contains(next) ? destinations[next].page : nil
            if pageSwipeDirection != step { pageSwipeDirection = step }
            if pageSwipeNeighbor != neighbor { pageSwipeNeighbor = neighbor }
            withTransaction(Transaction(animation: nil)) {
                pageSwipeMotion.offset = neighbor == nil
                    ? points / (4 + abs(points) / 35)
                    : min(pageSwipeStride, max(-pageSwipeStride, points))
            }
        case let .finish(step, velocity):
            guard let step, destinations.indices.contains(current + step) else {
                settlePageSwipe()
                return
            }
            let destination = destinations[current + step]
            if reduceMotion {
                openSwipeDestination(destination)
                return
            }
            let transition = UUID()
            let source = model.pageID
            pageSwipeTransition = transition
            pageSwipeDirection = step
            pageSwipeNeighbor = destination.page
            let target = CGFloat(-step) * pageSwipeStride
            let remaining = abs(target - pageSwipeMotion.offset)
            let releaseSpeed = max(0, velocity / model.interfaceScale * CGFloat(-step))
            let duration = min(0.23, max(0.095, Double(remaining / (3_000 + releaseSpeed * 0.5))))
            let controlY = min(0.82, 0.38 + Double(releaseSpeed) / 6_000)
            withAnimation(.timingCurve(0.25, controlY, 0.42, 1, duration: duration),
                          completionCriteria: .logicallyComplete) {
                pageSwipeMotion.offset = target
            } completion: {
                guard pageSwipeTransition == transition else { return }
                withTransaction(Transaction(animation: nil)) {
                    guard model.pageID == source else { clearPageSwipe(); return }
                    pageSwipeAwaitingContent = true
                    pageSwipeMotion.offset = 0
                    openSwipeDestination(destination)
                    if model.pageID != destination.page { clearPageSwipe() }
                }
            }
        }
    }

    private var pageSwipeReadyToReveal: Bool {
        guard pageSwipeAwaitingContent, launcherVisible,
              let destination = pageSwipeNeighbor, destination == model.pageID,
              presentation.page == destination else { return false }
        switch model.swipeDestinations.first(where: { $0.page == destination })?.command?.rawValue {
        case CompactLauncherShortcut.clipboard.rawValue:
            return !model.clipboard.searching && !model.clipboard.loadingDetail
        case CompactLauncherShortcut.files.rawValue:
            return !model.fileSearch.isSearching
        default:
            return destination != .root || !model.searchesFilesHere || !model.fileSearch.isSearching
        }
    }

    private func clearPageSwipe() {
        pageSwipeTransition = nil
        pageSwipeNeighbor = nil
        pageSwipeMotion.offset = 0
        pageSwipeAwaitingContent = false
        pageSwipePreviewOpacity = 1
    }

    private var pageSwipeStride: CGFloat { VisualStyle.launcherWidth + 10 }

    private func pageSwipePreview(_ pageID: PageID) -> some View {
        let destination = model.launcherModules?.page(pageID)
        let shortcut = model.swipeDestinations.first(where: { $0.page == pageID })?.command
        let rows: [LauncherSwipePreview.Row]
        let detail: String?
        let emptyTitle: String
        switch shortcut?.rawValue {
        case CompactLauncherShortcut.files.rawValue:
            let files = swipeFiles ?? []
            rows = files.map { .init(id: $0.id, title: $0.name, detail: $0.url.path, symbol: "doc") }
            detail = files.first?.url.path
            emptyTitle = swipeFiles == nil ? "正在载入最近使用的文件…" : "没有最近使用的文件"
        case CompactLauncherShortcut.snippets.rawValue:
            let snippets = model.snippets.entries.prefix(12)
            rows = snippets.map { .init(id: $0.id, title: $0.title, detail: $0.keyword, symbol: $0.icon ?? "text.alignleft") }
            detail = snippets.first?.text
            emptyTitle = "没有文字片段"
        case CompactLauncherShortcut.clipboard.rawValue:
            let clips = swipeClips ?? Array(model.clipboard.items.prefix(12))
            rows = clips.map { .init(id: $0.id, title: $0.preview, detail: $0.source, symbol: "clipboard") }
            detail = clips.first?.preview
            emptyTitle = swipeClips == nil && clips.isEmpty ? "正在载入剪贴板…" : "没有剪贴板记录"
        default:
            let commands = model.commands(in: nil, query: mainSearchQuery, page: .root).prefix(12)
            rows = commands.map { .init(id: $0.id, title: $0.name, detail: $0.detail, symbol: $0.symbol) }
            detail = nil
            emptyTitle = "没有匹配结果"
        }
        return LauncherSwipePreview(title: destination?.placeholder ?? (mainSearchQuery.isEmpty ? "搜索应用、文件和命令…" : mainSearchQuery),
                                    badge: destination?.badge, rows: rows, detail: detail, emptyTitle: emptyTitle)
    }

    private func openSwipeDestination(_ destination: (page: PageID, command: CommandID?)) {
        if let command = destination.command {
            model.runCommand(command, origin: .search, usageKey: command.rawValue)
            if command == CompactLauncherShortcut.files.id, model.pageID == destination.page {
                model.fileSearch.usePreparedRecentsOnNextSearch()
            }
        } else {
            mainSearchExpanded = true
            model.compactExpanded = true
            model.pageID = .root
        }
    }

    private func settlePageSwipe() {
        withAnimation(reduceMotion ? nil : .timingCurve(0.2, 0.72, 0.44, 1, duration: 0.17), completionCriteria: .logicallyComplete) {
            pageSwipeMotion.offset = 0
        } completion: {
            if pageSwipeMotion.offset == 0, pageSwipeTransition == nil { pageSwipeNeighbor = nil }
        }
    }

    private func updatePresentation(visible: Bool) {
        let wasVisible = launcherVisible
        let current = model.pageID
        if !visible || current != .root { cancelRootScriptArguments() }
        let activation = moduleActivation
        let previousActivation = presentedModuleActivation
        let change = presentation.update(page: current, visible: visible, activationID: activation?.id)
        let restoredQuery = change.previousPage.flatMap { previous in
            pageHistory.transition(from: previous, to: current, parentOfCurrent: page?.parent, query: model.query)
        }
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
        // An opted-in page remains active across hiding. A page or module change
        // still releases its state even if the window was already hidden.
        let retainedPrevious = change.previousPage.flatMap { previous -> PageID? in
            model.launcherModules?.page(previous, includingInactive: true)?.keepsStateWhenHidden == true ? previous : nil
        }
        if let previous = change.deactivation ?? retainedPrevious {
            dispatchedQuery = nil
            let retainsState = !visible && change.previousPage == nil &&
                model.launcherModules?.page(previous, includingInactive: true)?.keepsStateWhenHidden == true
            if previous == .root {
                model.fileSearch.cancel()
                FilePreview.shared.dismiss()
            } else if !retainsState {
                if let previousActivation {
                    model.leaveRegisteredPage(previous, activation: previousActivation)
                } else if let previousPage = model.launcherModules?.page(previous, includingInactive: true) {
                    previousPage.leave()
                    previousPage.releasePreview?()
                }
            }
        }

        let isOpeningExistingDraft = model.isOpeningExistingDraft(current)
        let opensExistingDraft = visible && isOpeningExistingDraft
        let entryIntent = change.activation == .enter || opensExistingDraft ? model.takePageEntry(for: current) : .standard
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
            } else if !isOpeningExistingDraft {
                model.query = restoredQuery ?? ""
            }
        }

        if change.activation != nil, let page, let activation {
            model.trackRegisteredPage(page, activation: activation)
        }
        if change.activation == .enter || opensExistingDraft {
            if let seed = entryIntent.resolve(current: model.query, restored: restoredQuery,
                                              pageConsumesEntryQuery: page?.consumesEntryQuery == true,
                                              existingDraft: { page?.entryDraft?() }, enter: { page?.enter?($0) }) {
                if showsFileResults { fileType = "all" }
                model.query = seed
            }
            refreshActiveQuery()
        } else if change.activation == .resume {
            if let resume = page?.resume {
                dispatchedQuery = model.query
                resume()
            } else { refreshActiveQuery() }
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
            let enabled = items.filter(\.enabled)
            if let current = enabled.firstIndex(where: { $0.id == actionSelectionID }) {
                actionSelectionID = enabled[NavigationBounds.move(current, by: delta, count: enabled.count)].id
            } else {
                actionSelectionID = enabled.first?.id
            }
        }
        else if let move = page?.move { move(delta) }
        else if model.pageID == .root || showsFileResults {
            guard selectionIsCurrent else { return }
            selection.move(by: delta, in: rows, identifiedBy: \.commandID)
        }
    }
    private func escape() {
        if inlineEmojiTarget != nil { closeMenus(); return }
        if !submenuPath.isEmpty { dismissSubmenu(); return }
        if rootScriptArguments != nil { cancelRootScriptArguments(); return }
        if argumentTarget != nil { dismissArgumentEditor(); focusToken += 1; return }
        if actions || appMenu || filterOpen { closeMenus() }
        else if presentation.page == model.pageID { model.cancelLauncherPage() }
    }

    private func goBack() {
        guard presentation.page == model.pageID else { return }
        model.goBackInLauncher()
    }

    private var showsTypeFilter: Bool { showsFileResults || page?.typeFilter != nil }

    private func launcherSearchBar(compactSurface: Bool) -> some View {
        let split = compactSurface && model.isCompact
        let glass = model.windowMode == "compact" ? 1 - model.launcherBackdropOpacity : 0
        let separation = split ? 1 : 1 - model.compactBarMergeProgress
        return CompactLauncherBar(model: model, separation: separation,
                                  interactive: split, glassOpacity: glass) {
            searchBar
        }
        .animation(reduceMotion ? nil : .spring(duration: split ? 0.46 : 0.24, bounce: split ? 0.18 : 0),
                   value: split)
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            if let script = rootScriptArguments {
                LauncherBackButton(action: cancelRootScriptArguments)
                RootScriptArgumentBar(script: script, controller: model.scripts, submit: run)
                    .id(script.id)
            } else {
                if model.pageID != .root {
                    LauncherBackButton(action: goBack)
                }
                if model.pageID == .root { Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .regular)).foregroundStyle(.secondary) }
                switch showsReadingDetail ? .none : (page?.headerInput ?? .searchField) {
                case let .custom(display):
                    display().frame(maxWidth: .infinity, alignment: .leading)
                case .searchField:
                    SearchField(text: Binding(get: { model.query }, set: { model.query = $0 }), placeholder: model.pageID == .root ? "搜索应用、文件和命令…" : moduleTitle, focusToken: focusToken, wantsFocus: !actions && !appMenu && !filterOpen && inlineEmojiTarget == nil, navigation: model.navigation, submit: { run() }, move: moveSelection, escape: escape,
                                back: page?.moveHorizontal.map { move in { move(-1) } },
                                forward: page?.moveHorizontal.map { move in { move(1) } },
                                navigateWhileTyping: page?.navigateWhileTyping ?? false,
                                spaceAtEnd: model.pageID == .root ? { ScriptCommandsModule.focusArguments(forAlias: $0, model: model) } : nil,
                                insertEmoji: openInlineEmoji,
                                tab: model.pageID == .root ? openQuickAI : nil)
                        .frame(height: 30)
                case .none:
                    Spacer(minLength: 0)
                }
                if model.pageID == .root, model.aiInteraction.showsRootHint, quickAIEntryEnabled {
                    Button { _ = launchQuickAI(model.query) } label: {
                        HStack(spacing: 6) {
                            Text("Quick AI")
                            if model.aiInteraction.rootTab { Keycap(text: "⇥") }
                        }.font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("使用搜索文字询问 AI")
                    .accessibilityLabel("询问 Quick AI")
                }
                if showsTypeFilter {
                    Color.clear.frame(width: showsFileResults && model.fileSearch.browsingDirectory != nil ? 312 : page?.typeFilterWidth ?? 138, height: 36)
                        .accessibilityHidden(true)
                }
            }
        }.padding(.horizontal, model.pageID == .root ? 19 : VisualStyle.launcherEdgeInset)
            .frame(height: model.pageID == .root ? 61 : VisualStyle.launcherControlDiameter + 2 * VisualStyle.launcherEdgeInset)
            .frame(height: 61, alignment: .top)
    }

    private func openQuickAI(_ query: String) -> Bool {
        guard presentation.page == .root, model.pageID == .root, model.aiInteraction.rootTab,
              menu == nil, inlineEmojiTarget == nil, argumentTarget == nil, rootScriptArguments == nil else { return false }
        return launchQuickAI(query)
    }
    private var quickAIEntryEnabled: Bool {
        model.aiSettings.state.enabled
            && !model.disabledCommands.contains(QuickAILauncher.commandID.rawValue)
            && model.launcherModules?.isCommandModuleEnabled(QuickAILauncher.commandID) == true
    }

    private func launchQuickAI(_ query: String) -> Bool {
        guard quickAIEntryEnabled else { return false }
        guard model.aiSettings.state.connection(for: .quick) != nil else {
            model.openSettings(page: AIModule.models.page)
            return true
        }
        return model.runCommand(QuickAILauncher.commandID, origin: .search, arguments: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [query])
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
                        sectionHeader(row.isFallback ? "备选命令" : model.query.isEmpty ? "建议" : "搜索结果")
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
    private func iconColor(_ id: String) -> ThemeColorStyle { switch id { case "clipboard": return .init(role: .orange); case "screenshot": return .init(role: .purple); case "quicklink": return .init(role: .blue); default: return .text } }
    private static let footerMenuWidth = LauncherActionListPanel.width
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
        let conversation = page?.contentPlacement == .conversation
        let secondary = page?.badge != nil
        let badgeTitle = page?.badgeTitle?() ?? page?.badge?.title ?? ""
        let badgeSymbol = page?.badge?.symbol ?? ""
        let menuTitle = page?.badgeActions == nil ? "Keylane 菜单" : "\(badgeTitle)菜单"
        let feedback = application && !conversation ? model.footerFeedback.current : nil
        let preferredApplicationWidth = conversation ? VisualStyle.launcherControlDiameter
            : feedback.map { LauncherFooterFeedbackLabel.width(for: $0.label) }
                ?? (secondary ? min(420, SecondaryPageBadge.width(for: badgeTitle)) : 36)
        let showsActions = rootScriptArguments == nil && (page?.contentPlacement != .form || !rootMenuItems(applicationMenu: false).isEmpty)
        let actionBar = LauncherFooterActionBar(title: primaryTitle,
            keys: (page?.returnBindings.primary ?? .plain).shortcut.launcherKeycaps,
            enabled: primaryActionEnabled, showsActions: showsActions,
            perform: { run() }, showActions: { toggleMenu(application: false) })
        let actionWidth = conversation ? VisualStyle.launcherControlDiameter : actionBar.width
        let rightWidth = actions ? Self.footerMenuWidth : actionWidth
        let availableApplicationWidth = VisualStyle.launcherWidth - 2 * VisualStyle.launcherEdgeInset
            - Self.footerMinimumGap - rightWidth
        let applicationWidth = min(preferredApplicationWidth, availableApplicationWidth)
        let open = application ? appMenu : actions
        let alignment: Alignment = application ? .bottomLeading : .bottomTrailing
        let items = open ? filteredMenu(applicationMenu: application) : []
        let menuHeight = menuRowsHeight(items) + 87
        return LauncherExpandingMenu(open: open,
            closedSize: CGSize(width: application ? applicationWidth : actionWidth, height: 36),
            menuSize: CGSize(width: Self.footerMenuWidth, height: menuHeight), alignment: alignment,
            tint: open ? nil : feedback?.style.color.opacity(0.16)) {
            if conversation {
                ConversationFooterButton(title: application ? "对话选项" : "操作",
                                         symbol: application ? "plus" : "command") {
                    toggleMenu(application: application)
                }
            } else if let feedback {
                NativeHoverButton(title: feedback.actionTitle == nil ? "\(feedback.message) · 打开\(menuTitle)" : feedback.label, action: {
                    if feedback.actionTitle != nil { model.footerFeedback.performAction() }
                    else { toggleMenu(application: true) }
                }) {
                    LauncherFooterFeedbackLabel(feedback: feedback)
                }
                .frame(width: applicationWidth, height: 36)
            } else if application && secondary {
                NativeHoverButton(title: "打开\(menuTitle)", action: { toggleMenu(application: true) }) {
                    SecondaryPageBadge(title: badgeTitle, symbol: badgeSymbol,
                                       artwork: model.launcherModules?.module(forPage: model.pageID).flatMap(ModuleArtwork.module))
                }.frame(width: applicationWidth, height: 36)
            } else if application {
                NativeHoverButton(title: "Keylane 菜单", action: { toggleMenu(application: true) }) {
                    Image(systemName: "text.menu").font(.system(size: 16)).frame(width: 36, height: 36)
                }.frame(width: 36, height: 36).clipShape(Circle())
            } else {
                actionBar
            }
        } menu: {
            menuPanel(applicationMenu: application, items: items)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.20), value: feedback?.message)
    }
    private var shortcutActions: [LauncherAction] {
        let entryActions: [LauncherAction]
        if page?.actionShortcutsEnabled == true {
            entryActions = page?.actions?() ?? []
        } else if page == nil, !appMenu, submenuPath.isEmpty, argumentTarget == nil,
                  let entry = selectedEntry, entry.commandID.rawValue.hasPrefix("app:") {
            entryActions = model.applicationResultActions.shortcutActions(for: entry, model: model)
        } else if page == nil, !appMenu, submenuPath.isEmpty, argumentTarget == nil,
                  let entry = selectedEntry, entry.id == CalculatorLauncherModule.resultID.rawValue,
                  entry.detail != CalculatorLauncherModule.colorDetail {
            entryActions = model.launcherModules?.actions(for: entry) ?? []
        } else {
            entryActions = []
        }
        return (page?.badgeActions?() ?? []) + entryActions
    }

    private var pageMenuShortcuts: some View {
        let candidates = shortcutActions
        let context = candidates.isEmpty ? nil : actionContext()
        return ForEach(candidates) { action in
            if let context, let shortcut = action.shortcut, action.enabled, !shortcut.modifiers.isEmpty,
               page?.returnBindings.reserves(shortcut) != true {
                pageMenuShortcut(action, shortcut: shortcut, context: context)
            }
        }
    }

    private func actionContext(tracksSelection: Bool = true) -> LauncherPagePresentation.ActionContext? {
        let selectedID: String?
        if !tracksSelection { selectedID = nil }
        else if model.pageID == .root || showsFileResults { selectedID = selectionIsCurrent ? selection.id?.rawValue : nil }
        else { selectedID = page?.actionSelectionID?() }
        return presentation.actionContext(page: model.pageID, activationID: moduleActivation?.id, selectionID: selectedID)
    }

    private var currentMenuContext: LauncherPagePresentation.ActionContext? {
        actionContext(tracksSelection: !appMenu || page?.badgeActions != nil)
    }

    private func pageMenuShortcut(_ action: MenuAction, shortcut: KeyboardShortcut,
                                  context: LauncherPagePresentation.ActionContext) -> some View {
        Button("") {
            guard actionContext() == context, !SearchField.isComposing,
                  let current = shortcutActions.first(where: { $0.id == action.id }), current.enabled,
                  current.shortcut?.key == shortcut.key, current.shortcut?.modifiers == shortcut.modifiers else { return }
            if current.submenu != nil, !actions { toggleMenu(application: false) }
            activate(current, startsAtRoot: true)
        }
        .keyboardShortcut(shortcut)
        .hidden()
        .accessibilityHidden(true)
    }

    private typealias MenuAction = LauncherAction
    private var selectedEntry: Entry? {
        let results = rows
        return selectionIndex(in: results).map { results[$0] }
    }
    private func rootMenuItems(applicationMenu: Bool) -> [MenuAction] {
        if applicationMenu {
            if let badgeActions = page?.badgeActions { return badgeActions() }
            return [
                MenuAction(id: "about", title: "关于 Keylane", icon: "app.badge", perform: { model.openSettings(page: "about") }),
                MenuAction(id: "settings", title: "设置…", icon: "gearshape", shortcut: .init(",", modifiers: .command), perform: { model.runCommand(.init(rawValue: "settings"), origin: .menu) }),
                MenuAction(id: "clipboard", title: "剪贴板历史", icon: "list.clipboard", perform: { model.runCommand(.init(rawValue: "clipboard"), origin: .menu) }),
                MenuAction(id: "hide", title: "隐藏 Keylane", icon: "rectangle.compress.vertical", shortcut: .init(.escape, modifiers: []), perform: { (NSApp.delegate as? Delegate)?.hideLauncher() }),
                MenuAction(id: "quit", title: "退出 Keylane", icon: "rectangle.portrait.and.arrow.right", perform: { NSApp.terminate(nil) })
            ].filter { model.launcherModules?.isCommandModuleEnabled(CommandID(rawValue: $0.id)) != false }
        }
        if let page, !showsFileResults { return page.actions?() ?? [] }
        guard let row = selectedEntry else { return [] }
        if row.isFallback {
            return [
                MenuAction(id: "run-fallback", title: "运行备选命令", icon: "return", shortcut: .init(.return, modifiers: [])) {
                    model.perform(row)
                },
                MenuAction(id: "manage-fallback", title: "管理备选命令…", icon: "gearshape", group: 1) {
                    model.openSettings(page: "launcher")
                }
            ]
        }
        var actions = model.launcherModules?.actions(for: row) ?? [
            MenuAction(id: "open", title: "执行命令", icon: "return", shortcut: .init(.return, modifiers: [])) {
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
    private func currentSubmenu(root: [MenuAction]) -> MenuAction.Submenu? {
        var items = root
        var active: MenuAction.Submenu?
        for id in submenuPath {
            guard let parent = items.first(where: { $0.id == id }), parent.enabled,
                  let submenu = parent.submenu else { return nil }
            active = submenu
            items = submenu.items
        }
        return active
    }

    private func dismissSubmenu() {
        submenuPath.removeAll()
        actionQuery = ""
        actionSelectionID = nil
        focusToken += 1
    }

    private func activate(_ item: MenuAction, startsAtRoot: Bool = false) {
        guard item.enabled else { return }
        if item.submenu != nil {
            if startsAtRoot { submenuPath = [item.id] }
            else { submenuPath.append(item.id) }
            actionQuery = ""
            actionSelectionID = nil
            focusToken += 1
        } else if item.id == "back", !submenuPath.isEmpty {
            dismissSubmenu()
        } else {
            closeMenus()
            item.perform()
        }
    }

    private func filteredMenu(applicationMenu: Bool) -> [MenuAction] {
        guard let menuContext, menuContext == currentMenuContext else { return [] }
        let root = rootMenuItems(applicationMenu: applicationMenu)
        let items: [MenuAction]
        if !applicationMenu, !submenuPath.isEmpty {
            let back = MenuAction(id: "back", title: "返回", icon: "chevron.left", perform: dismissSubmenu)
            items = [back] + (currentSubmenu(root: root)?.items ?? [])
        } else {
            items = root
        }
        return items.filter {
            actionQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(actionQuery)
                || $0.value?.localizedCaseInsensitiveContains(actionQuery) == true
        }
    }

    private func selectedAction(in items: [MenuAction]) -> MenuAction? {
        guard let actionSelectionID else { return items.first(where: \.enabled) }
        return items.first { $0.id == actionSelectionID && $0.enabled }
    }

    private func activateMenuItem(_ id: String, applicationMenu: Bool, focus: Int) {
        guard focusToken == focus, applicationMenu ? appMenu : actions, !SearchField.isComposing,
              let item = filteredMenu(applicationMenu: applicationMenu).first(where: { $0.id == id }) else { return }
        activate(item)
    }

    private func activateSelectedMenuItem(applicationMenu: Bool, focus: Int, requiresSubmenu: Bool = false) {
        guard focusToken == focus, applicationMenu ? appMenu : actions, !SearchField.isComposing,
              let item = selectedAction(in: filteredMenu(applicationMenu: applicationMenu)),
              !requiresSubmenu || item.submenu != nil else { return }
        activate(item)
    }

    private func menuRowsHeight(_ items: [MenuAction]) -> CGFloat {
        LauncherActionListPanel.rowsHeight(items)
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
            let submenu = submenuPath.isEmpty ? nil : currentSubmenu(root: rootMenuItems(applicationMenu: false))
            title = submenu.map { base + " › " + $0.title } ?? base
        }
        let focus = focusToken
        let selectedID = selectedAction(in: items)?.id
        return LauncherActionListPanel(title: title, items: items, selectedID: selectedID,
            query: Binding(get: { actionQuery }, set: { query in
                guard actionQuery != query else { return }
                actionQuery = query; actionSelectionID = nil
            }), focusToken: focusToken, wantsFocus: actions || appMenu, navigation: model.navigation,
            activate: { activateMenuItem($0, applicationMenu: applicationMenu, focus: focus) },
            highlight: { if focus == focusToken { actionSelectionID = $0 } },
            submit: { activateSelectedMenuItem(applicationMenu: applicationMenu, focus: focus) },
            move: moveSelection, escape: escape,
            forward: { activateSelectedMenuItem(applicationMenu: applicationMenu, focus: focus, requiresSubmenu: true) },
            reconcile: { actionSelectionID = LauncherActionSelection.reconcile(actionSelectionID, enabledIDs: $0) })

    }
    private func toggleMenu(application: Bool) {
        if rootScriptArguments != nil {
            guard application else { return }
            cancelRootScriptArguments()
        }
        if !application, page?.contentPlacement == .form, rootMenuItems(applicationMenu: false).isEmpty { return }
        model.compactExpanded = true
        let target: Menu = application ? .application : .actions
        let open = menu != target
        closeMenus()
        if open, let context = actionContext(tracksSelection: !application || page?.badgeActions != nil) {
            menuContext = context
            menu = target
        }
    }

    private func openInlineEmoji(_ range: NSRange) -> Bool {
        guard !model.emoji.disablesInlinePicker, model.pageID != EmojiSearchController.pageID,
              model.launcherModules?.isModuleEnabled(.init(rawValue: "keylane.emoji")) == true else { return false }
        closeMenus()
        model.compactExpanded = true
        inlineEmojiTarget = (model.query, range)
        return true
    }

    private func closeMenus() {
        inlineEmojiTarget = nil
        menu = nil
        submenuPath.removeAll()
        menuContext = nil
        actionQuery = ""
        actionSelectionID = nil
        focusToken += 1
    }
    private var moduleTitle: String { page?.placeholder ?? "设置" }
    private var primaryActionEnabled: Bool {
        guard presentation.page == model.pageID else { return false }
        if argumentTarget != nil { return true }
        if rootScriptArguments != nil { return true }
        if model.pageID == .root || showsFileResults {
            guard let row = selectedEntry else { return false }
            return row.detail != "File" || !model.fileSearch.isSearching
        }
        return page?.primaryEnabled?() != false
    }

    private var primaryTitle: String {
        if argumentTarget != nil { return "启动新实例" }
        if rootScriptArguments != nil { return "运行脚本" }
        if let title = page?.primaryTitle?() { return title }
        if let row = selectedEntry {
            if row.isFallback { return "运行备选命令" }
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

    private func cancelRootScriptArguments() {
        guard model.scripts.rootArgumentScript != nil else { return }
        model.scripts.cancelRootArguments()
        focusToken += 1
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
    private func submitReturn(_ key: LauncherPage.ReturnKey, on pageID: PageID) {
        guard presentation.page == pageID, model.pageID == pageID, let page,
              !SearchField.isComposing else { return }
        if page.returnBindings.primary == key {
            if key == .plain { run() }
            else { performPrimaryAction() }
        } else if let action = page.returnBindings.alternates[key] {
            if action.dismissMenu { closeMenus() }
            action.perform()
        }
    }

    private func run() {
        guard presentation.page == model.pageID, !SearchField.isComposing else { return }
        if rootScriptArguments != nil || argumentTarget != nil {
            performPrimaryAction()
            return
        }
        if (showsFileResults || selectedEntry?.detail == "File"), model.fileSearch.isSearching { return }
        if actions || appMenu {
            let items = filteredMenu(applicationMenu: appMenu)
            if let item = selectedAction(in: items) { activate(item) }
            return
        }
        performPrimaryAction()
    }

    private func performPrimaryAction() {
        guard primaryActionEnabled else { return }
        if rootScriptArguments != nil {
            ScriptCommandsModule.runRootArguments(model)
            return
        }
        if let target = argumentTarget {
            do { target.submit(try ArgumentParser.parse(argumentText)) }
            catch { model.error = "参数引号或转义未完成。" }
            return
        }
        if let submit = page?.submit { submit(); return }
        if model.pageID != .root && !showsFileResults { goBack(); return }
        if let row = selectedEntry { performRootEntry(row) }
    }

    private func performRootEntry(_ row: Entry) {
        if row.id == CalculatorLauncherModule.resultID.rawValue, row.detail == CalculatorLauncherModule.colorDetail {
            toggleMenu(application: false)
        } else {
            model.perform(row)
        }
    }
}

struct LauncherBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24, height: 26)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help("返回")
        .accessibilityLabel("返回")
    }
}

/// Samples the scrolling content in this window, rather than the desktop behind it.
struct ChromeBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .headerView
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
