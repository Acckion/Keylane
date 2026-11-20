import SwiftUI
import AppKit
import Carbon
import Combine
import Darwin
import ServiceManagement
import ApplicationServices
import KeylaneCore

final class Model: ObservableObject {
    let updates = KeylaneReleaseCheck()
    private let dataStoreURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Keylane/data.sqlite")
    @Published var error = ""
    @Published var settingsPage = "applications"
    @Published private(set) var applicationSettingsPath: String?
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }
    @Published var placement = UserDefaults.standard.string(forKey: "placement") ?? "activeScreen" { didSet { UserDefaults.standard.set(placement, forKey: "placement") } }
    @Published var launcherReturnDelay = LauncherReturnDelay(rawValue: UserDefaults.standard.object(forKey: "launcherReturnDelay") as? Int ?? 90) ?? .after90Seconds {
        didSet { UserDefaults.standard.set(launcherReturnDelay.rawValue, forKey: "launcherReturnDelay") }
    }
    @Published var rootSearchSensitivity = LauncherSearchRanking.Sensitivity(rawValue: UserDefaults.standard.string(forKey: "rootSearchSensitivity") ?? "") ?? .low {
        didSet { UserDefaults.standard.set(rootSearchSensitivity.rawValue, forKey: "rootSearchSensitivity") }
    }
    @Published var rootFileContentSearch = UserDefaults.standard.object(forKey: "rootFileContentSearch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(rootFileContentSearch, forKey: "rootFileContentSearch") }
    }
    @Published var interfaceSize = UserDefaults.standard.string(forKey: "interfaceSize") ?? "medium" { didSet { UserDefaults.standard.set(interfaceSize, forKey: "interfaceSize") } }
    @Published var windowMode = UserDefaults.standard.string(forKey: "windowMode") ?? "expanded" {
        didSet {
            UserDefaults.standard.set(windowMode, forKey: "windowMode")
            if windowMode == "compact", pageID == .root, query.isEmpty { compactExpanded = false }
        }
    }
    @Published var compactExpanded = false
    let footerFeedback = LauncherFooterFeedbackPresenter()
    var interfaceScale: CGFloat { interfaceSize == "small" ? 0.9 : interfaceSize == "large" ? 1.1 : 1 }
    var isCompact: Bool { windowMode == "compact" && pageID == .root && query.isEmpty && !compactExpanded && footerFeedback.current == nil }
    @Published var presentedLauncherHeight: CGFloat = 470
    @Published var compactBarMergeProgress: CGFloat = 1
    enum LauncherPageSwipe {
        case drag(CGFloat)
        case finish(Int?, velocity: CGFloat)
    }
    let launcherPageSwipes = PassthroughSubject<LauncherPageSwipe, Never>()

    var swipeDestinations: [(page: PageID, command: CommandID?)] {
        var destinations: [(page: PageID, command: CommandID?)] = [(.root, nil)]
        guard let registry = launcherModules else { return destinations }
        for shortcut in CompactLauncherShortcut.allCases {
            guard registry.isRegisteredCommandEnabled(shortcut.id),
                  let declaration = registry.declaration(shortcut.id),
                  case let .page(page) = declaration.destination else { continue }
            destinations.append((page, shortcut.id))
        }
        return destinations
    }

    var launcherHeight: CGFloat { isCompact ? VisualStyle.launcherTopInset : 470 }
    var launcherBackdropOpacity: CGFloat {
        Self.launcherBackdropOpacity(at: presentedLauncherHeight)
    }

    static func launcherBackdropOpacity(at height: CGFloat) -> CGFloat {
        let progress = min(1, max(0, (height - VisualStyle.launcherTopInset) / 210))
        return progress * progress * (3 - 2 * progress)
    }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    @Published var query = ""
    @Published var pageID = PageID.root
    let aiSettings = AIConfiguration()
    let aiInteraction = AIInteractionPreferences()
    let aiFileAccess = AIFileToolPreferences()
    var continueModuleAIAction: ((AIActionContext, String) -> Bool)?
    var openAIChatLink: ((UUID) -> Void)?
    let aiRuntime = AIRuntime()
    lazy var moduleAIAction = AIActionSession(configuration: aiSettings, runtime: aiRuntime)

    lazy var dictation = DictationController(configuration: aiSettings, runtime: aiRuntime)
    lazy var fileAI: FileAIController = {
        let controller = FileAIController(settings: aiSettings, runtime: aiRuntime)
        controller.continueConversation = { [weak self] context, answer in self?.continueModuleAIAction?(context, answer) == true }
        controller.invocationUpdates = { [weak self] id in
            guard let self, let registry = self.launcherModules else { return Empty().eraseToAnyPublisher() }
            return Publishers.MergeMany([
                registry.availabilityChanges.map { [weak registry] in registry?.isCommandModuleEnabled(.init(rawValue: id)) == true }.eraseToAnyPublisher(),
                self.$disabledCommands.map { !$0.contains(id) }.eraseToAnyPublisher(),
                self.fileSearch.$options.map(\.enabled).eraseToAnyPublisher()
            ]).eraseToAnyPublisher()
        }
        controller.isInvocationAvailable = { [weak self] id in
            guard let self else { return false }
            return self.fileSearch.options.enabled && self.launcherModules?.isCommandModuleEnabled(.init(rawValue: id)) == true
                && !self.disabledCommands.contains(id)
        }
        controller.openSettings = { [weak self] in self?.openSettings(page: "ai") }
        return controller
    }()
    private var moduleSearchChanges: AnyCancellable?
    private var moduleActivationRevocations: AnyCancellable?
    private var registeredPageCleanup: (page: PageID, activation: LauncherModuleRegistry.Activation, session: LauncherPageSession)?
    let rootSearchUpdates = PassthroughSubject<Void, Never>()
    let clipboard = ClipboardController(startTimer: false, presentationActive: false, startStorage: false)
    let screenshots = ScreenshotLibrary()
    let downloads = DownloadsController()
    let systemShortcuts = SystemShortcutsController(active: false)
    let scripts = ScriptCommandsController()
    lazy var snippets = SnippetsController(storageURL: dataStoreURL)
    let quicklinks = QuicklinksController()
    let contacts = ContactsController()
    let dictionary = DictionaryController()
    let emoji = EmojiSearchController()
    let systemNavigation = NavigationController()
    let cameraPreview = CameraPreview()
    let menuBar = MenuBarRegistry()
    lazy var focus = FocusController(registry: menuBar)
    let dropShelf = DropShelfController()
    lazy var calendar = CalendarController(registry: menuBar)
    @Published var roots = UserDefaults.standard.stringArray(forKey: "applicationRoots") ?? ApplicationCatalog.defaultRoots
    @Published var excluded = Set(UserDefaults.standard.stringArray(forKey: "excludedApps") ?? []) {
        didSet { applicationEntries = nil; commandSearch.invalidate() }
    }
    @Published var applicationsEnabled = (UserDefaults.standard.object(forKey: "applicationsEnabled") as? Bool) ?? true { didSet { UserDefaults.standard.set(applicationsEnabled, forKey: "applicationsEnabled") } }
    @Published var applicationCustomDepth = UserDefaults.standard.integer(forKey: "applicationCustomDepth") {
        didSet {
            UserDefaults.standard.set(applicationCustomDepth, forKey: "applicationCustomDepth")
            reloadCatalog()
        }
    }
    @Published var applicationHotkeyAction = UserDefaults.standard.string(forKey: "applicationHotkeyAction") ?? "toggle" { didSet { UserDefaults.standard.set(applicationHotkeyAction, forKey: "applicationHotkeyAction") } }
    @Published var aliases = UserDefaults.standard.dictionary(forKey: "aliases") as? [String:String] ?? [:]
    @Published var usage = UserDefaults.standard.dictionary(forKey: "usage") as? [String:Int] ?? [:]
    private var searchUsage = UserDefaults.standard.data(forKey: SearchUsageHistory.storageKey)
        .flatMap { try? JSONDecoder().decode(SearchUsageHistory.self, from: $0) } ?? SearchUsageHistory()
    @Published var disabledCommands = Set(UserDefaults.standard.stringArray(forKey: "disabledLauncherCommands") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(disabledCommands), forKey: "disabledLauncherCommands")
            commandSearch.invalidate()
            rootSearchUpdates.send()
        }
    }
    @Published var bindings: [String:Shortcut] = (UserDefaults.standard.data(forKey: "shortcuts").flatMap { try? JSONDecoder().decode([String:Shortcut].self, from: $0) }) ?? ["launcher": .launcher]
    @Published var navigation = UserDefaults.standard.string(forKey: "navigation") ?? "arrows" { didSet { UserDefaults.standard.set(navigation, forKey: "navigation") } }
    @Published var windowActivationBehavior = WindowActivationBehavior(
        rawValue: UserDefaults.standard.string(forKey: "windowActivationBehavior") ?? ""
    ) ?? .systemDefault {
        didSet { UserDefaults.standard.set(windowActivationBehavior.rawValue, forKey: "windowActivationBehavior") }
    }
    @Published var launcherEscapeBehavior = LauncherEscapeBehavior(rawValue: UserDefaults.standard.string(forKey: "launcherEscapeBehavior") ?? "") ?? .backOrClose {
        didSet { UserDefaults.standard.set(launcherEscapeBehavior.rawValue, forKey: "launcherEscapeBehavior") }
    }
    @Published var escapeClosesUtilityWindows = UserDefaults.standard.object(forKey: "escapeClosesUtilityWindows") as? Bool ?? true {
        didSet { UserDefaults.standard.set(escapeClosesUtilityWindows, forKey: "escapeClosesUtilityWindows") }
    }
    @Published var pageNavigationKeys = PageNavigationKeys(rawValue: UserDefaults.standard.string(forKey: "pageNavigationKeys") ?? "") ?? .brackets {
        didSet { UserDefaults.standard.set(pageNavigationKeys.rawValue, forKey: "pageNavigationKeys") }
    }
    @Published var hyperIncludesShift = UserDefaults.standard.object(forKey: "hyperIncludesShift") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hyperIncludesShift, forKey: "hyperIncludesShift") }
    }
    @Published var replaceHyperKeycaps = UserDefaults.standard.bool(forKey: "replaceHyperKeycaps") {
        didSet { UserDefaults.standard.set(replaceHyperKeycaps, forKey: "replaceHyperKeycaps") }
    }
    @Published var doubleTap = UserDefaults.standard.string(forKey: "doubleTap") ?? "off"
    @Published var hyperkey = UserDefaults.standard.bool(forKey: "hyperkey")
    @Published var modifierStatus = ""
    @Published var scanStatus = "正在扫描…"
    let fileSearch = FileSearchController(startImmediately: false)
    var fileSearchSeed: String?
    private var mutatingFiles = Set<String>()
    private(set) var fileDetailPath: String?
    @Published var fileResults: [SpotlightFile] = [] {
        didSet { filteredFileEntries.removeAll() }
    }
    private var filteredFileEntries: [String: [Entry]] = [:]

    func fileEntries(ofType type: String) -> [Entry] {
        if let cached = filteredFileEntries[type] { return cached }
        let entries = fileResults.lazy.filter { FileResultTypeFilter.includes($0, selection: type) }
            .map(BuiltinLauncherModules.fileEntry)
        let result = Array(entries)
        filteredFileEntries[type] = result
        return result
    }
    @Published var fileSearchStatus = "输入文件名，搜索Spotlight已索引的文件。"
    @Published var lastScanSeconds = 0.0
    @Published var loginStatus = ""
    @Published var loginEnabled = false
    let discovery = ApplicationDiscovery()
    let applicationResultActions = ApplicationResultActions()
    let finderAutomation = PermissionFeature("finderAutomation.enabled", authorization: .automation("com.apple.finder", appName: "Finder"))
    let crossAppPaste = PermissionFeature("crossAppPaste.enabled", authorization: .postEvent)
    let lockScreenPermission = PermissionFeature("lockScreen.enabled", authorization: .postEvent)
    let systemKeyboardPermission = PermissionFeature("systemKeyboard.enabled", authorization: .postEvent, observeImmediately: false)
    let systemControlsPermission = PermissionFeature("systemControls.enabled", authorization: .accessibility, observeImmediately: false)
    let systemEventsPermission = PermissionFeature("systemEvents.enabled", authorization: .automation("com.apple.systemevents", appName: "系统事件"), observeImmediately: false)
    let clipboardSpeech = PermissionFeature("clipboardSpeech.enabled", authorization: .persistentClipboard, observeImmediately: false)
    let applicationAutoQuit = ApplicationAutoQuit()
    private(set) lazy var applicationSettingsCatalog = ApplicationSettingsCatalog(model: self)
    @Published var runningPaths: Set<String> = []
    enum ApplicationCatalogConsumer { case applications, windowLayout, focus }
    private var applicationCatalogConsumers: Set<ApplicationCatalogConsumer> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    @Published var apps: [URL] = [] { didSet { applicationEntries = nil } }
    private var applicationEntries: (locale: Locale, rows: [Entry])?
    private let commandSearch = LauncherCommandSearch()
    private(set) lazy var launcherModules: LauncherModuleRegistry? = {
        do {
            let modules = BuiltinLauncherModules.make(model: self)
            if let system = modules.first(where: { $0.id == SystemActionsModule.id }) {
                SystemActionsModule.migratePreferences(model: self, commands: system.commands)
            }
            let registry = try LauncherModuleRegistry(modules: modules) { [weak self] id in
                self?.disabledCommands.contains(id.rawValue) == false
            }
            let remaining = registry.migrateDisabledCommands(disabledCommands)
            if remaining != disabledCommands { disabledCommands = remaining }
            return registry
        }
        catch {
            NSLog("Keylane: invalid built-in module catalog: %@", String(describing: error))
            return nil
        }
    }()
    func setModuleEnabled(_ id: ModuleID, _ enabled: Bool) {
        guard let registry = launcherModules, registry.setModuleEnabled(id, enabled) else { return }
        commandSearch.invalidate()
        if !enabled, registry.module(forPage: pageID) == id { pageID = .root }
    }

    var activeLauncherPage: LauncherPage? { launcherModules?.page(pageID) }

    func trackRegisteredPage(_ page: LauncherPage, activation: LauncherModuleRegistry.Activation) {
        if let current = registeredPageCleanup, current.page == page.id, current.activation == activation { return }
        let previous = registeredPageCleanup
        registeredPageCleanup = nil
        previous?.session.end()
        let session = LauncherPageSession()
        let owner = FilePresentationOwner.extensionActivation(activation.id)
        session.onEnd {
            page.leave()
            page.releasePreview?()
            FilePreview.shared.dismiss(owner: owner)
        }
        registeredPageCleanup = (page.id, activation, session)
        page.startSession?(session)
    }

    func leaveRegisteredPage(_ page: PageID, activation: LauncherModuleRegistry.Activation) {
        guard let cleanup = registeredPageCleanup, cleanup.page == page, cleanup.activation == activation else { return }
        registeredPageCleanup = nil
        cleanup.session.end()
    }
    lazy var activePageUpdates: AnyPublisher<Void, Never> = {
        $pageID.removeDuplicates().map { [weak self] pageID in
            self?.launcherModules?.page(pageID)?.updates ?? Empty().eraseToAnyPublisher()
        }.switchToLatest().receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }()

    private var appIdentities: [String: ApplicationIdentity] = [:] {
        didSet { applicationEntries = nil; commandSearch.invalidate() }
    }
    @Published private(set) var fallbackCommandOrder = FallbackCommandOrder(preferences: .standard) {
        didSet {
            UserDefaults.standard.set(fallbackCommandOrder.custom, forKey: FallbackCommandOrder.preferenceKey)
            rootSearchUpdates.send()
        }
    }
    private var pendingPageEntry: (page: PageID, intent: LauncherPagePresentation.EntryIntent)?

    var fallbackCommandIDs: [String] {
        get { fallbackCommandOrder.custom ?? fallbackCommandOrder.ids(in: launcherModules?.fallbackCatalog() ?? []) }
        set { fallbackCommandOrder.custom = newValue }
    }

    func isOpeningExistingDraft(_ page: PageID) -> Bool {
        pendingPageEntry?.page == page && pendingPageEntry?.intent == .existingDraft
    }

    func takePageEntry(for page: PageID) -> LauncherPagePresentation.EntryIntent {
        defer { pendingPageEntry = nil }
        return pendingPageEntry?.page == page ? pendingPageEntry?.intent ?? .standard : .standard
    }

    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    @Published private(set) var favoriteOrder = UserDefaults.standard.stringArray(forKey: "favoriteOrder") ?? []

    func favoriteOrderActions(for id: String) -> [LauncherAction] {
        guard favorites.contains(id) else { return [] }
        let order = visibleFavoriteIDs
        guard let index = order.firstIndex(of: id) else { return [] }
        return [
            .init(id: "move-favorite-earlier", title: "向前移动收藏", icon: "arrow.up", group: 1, enabled: index > 0) { [weak self] in
                self?.moveFavorite(id, by: -1)
            },
            .init(id: "move-favorite-later", title: "向后移动收藏", icon: "arrow.down", group: 1, enabled: index + 1 < order.count) { [weak self] in
                self?.moveFavorite(id, by: 1)
            }
        ]
    }

    private var orderedFavoriteIDs: [String] {
        var remaining = favorites
        return favoriteOrder.filter { remaining.remove($0) != nil } + remaining.sorted()
    }

    private var visibleFavoriteIDs: [String] {
        guard !favorites.isEmpty else { return [] }
        if pageID == .root, query.isEmpty { return commands.filter { favorites.contains($0.id) }.map(\.id) }
        let input = LauncherCommandSearch.Input(query: "", page: .root, aliases: aliases, favorites: favorites, usage: usage)
        let visible = Set(launcherModules?.candidates(for: input).map(\.id) ?? [])
        return orderedFavoriteIDs.filter { visible.contains($0) }
    }

    private func moveFavorite(_ id: String, by delta: Int) {
        let visible = visibleFavoriteIDs
        guard let index = visible.firstIndex(of: id), visible.indices.contains(index + delta) else { return }
        var order = orderedFavoriteIDs
        guard let source = order.firstIndex(of: id), let destination = order.firstIndex(of: visible[index + delta]) else { return }
        order.swapAt(source, destination)
        saveFavoriteOrder(order)
    }

    private func saveFavoriteOrder(_ order: [String]) {
        favoriteOrder = order
        UserDefaults.standard.set(order, forKey: "favoriteOrder")
    }

    func favoriteAction(for entry: Entry) -> LauncherAction {
        let favorite = favorites.contains(entry.id)
        return .init(id: "favorite", title: favorite ? "取消收藏" : "加入收藏", icon: favorite ? "star.fill" : "star") { [weak self] in
            self?.toggleFavorite(entry.id, showsFeedback: true)
        }
    }
    func toggleFavorite(_ id: String, showsFeedback: Bool = false) {
        var order = orderedFavoriteIDs
        let added = favorites.remove(id) == nil
        if added {
            favorites.insert(id)
            order.append(id)
        } else {
            order.removeAll { $0 == id }
        }
        saveFavoriteOrder(order)
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
        if showsFeedback {
            (NSApp.delegate as? Delegate)?.showLauncherFeedback(added ? "已加入收藏" : "已取消收藏", style: .success)
        }
    }
    func openSettings(page: String? = nil) {
        applicationSettingsPath = nil
        if let page { settingsPage = page }
        (NSApp.delegate as? Delegate)?.showSettings()
    }
    func openApplicationCommandSettings(path: String) {
        applicationSettingsPath = path
        settingsPage = "applications"
        (NSApp.delegate as? Delegate)?.showSettings()
    }
    func showAllApplicationSettings() { applicationSettingsPath = nil }
    func setApplicationEnabled(_ enabled: Bool, path: String) {
        if enabled { excluded.remove(path) } else { excluded.insert(path) }
        commandSearch.invalidate()
        rootSearchUpdates.send()
        reloadCatalog()
    }
    func isApplicationCommandAvailable(at path: String) -> Bool {
        let id = CommandID(rawValue: "app:" + path)
        return applicationsEnabled && !excluded.contains(path) && !disabledCommands.contains(id.rawValue)
            && launcherModules?.isCommandModuleEnabled(id) == true
            && apps.contains(where: { $0.path == path }) && FileManager.default.fileExists(atPath: path)
    }
    func resetUsage(for key: String) {
        searchUsage.reset(id: key)
        usage.removeValue(forKey: key)
        persistUsage()
        commandSearch.invalidate()
        rootSearchUpdates.send()
    }

    private func recordUsage(for key: String, queryKey: String? = nil) {
        searchUsage.record(id: key, queryKey: queryKey)
        let count = usage[key, default: 0]
        usage[key] = count < Int.max ? count + 1 : count
        persistUsage()
    }

    private func persistUsage() {
        UserDefaults.standard.set(usage, forKey: "usage")
        if let data = try? JSONEncoder().encode(searchUsage) {
            UserDefaults.standard.set(data, forKey: SearchUsageHistory.storageKey)
        }
    }

    func resetRankingAction(for entry: Entry) -> LauncherAction {
        .init(id: "reset-ranking", title: "重置优先级", icon: "arrow.counterclockwise", group: 3) { [weak self] in
            guard let self else { return }
            self.resetUsage(for: entry.id)
            (NSApp.delegate as? Delegate)?.showLauncherFeedback("已重置「\(entry.name)」的搜索优先级。", style: .success)
        }
    }
    func exportData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Keylane-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Store(url: dataStoreURL).export(to: url) }
        catch { self.error = error.localizedDescription }
    }

    init() {
        let defaults = UserDefaults.standard
        // Install the documented shelf defaults once; never replace a user's existing binding
        // or occupy a combination already configured for another Keylane command.
        if !defaults.bool(forKey: "dropShelf.shortcutsInstalled") {
            let shelfDefaults: [String: Shortcut] = [
                "drop-shelf-new": .init(key: 49, modifiers: 2048 | 512),
                "drop-shelf-clipboard": .init(key: 0, modifiers: 2048 | 512),
                "drop-shelf-select": .init(key: 1, modifiers: 2048 | 512)
            ]
            for (action, shortcut) in shelfDefaults where bindings[action] == nil && !bindings.values.contains(shortcut) {
                bindings[action] = shortcut
            }
            if let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: "shortcuts") }
            defaults.set(true, forKey: "dropShelf.shortcutsInstalled")
        }
        defaults.removeObject(forKey: "notes")
        if aliases.removeValue(forKey: "notes") != nil { defaults.set(aliases, forKey: "aliases") }
        if bindings.removeValue(forKey: "notes") != nil, let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: "shortcuts")
        }
        if disabledCommands.contains("notes") { disabledCommands.remove("notes") }
        let oldSearchUsage = searchUsage
        searchUsage.reset(id: "notes")
        if usage.removeValue(forKey: "notes") != nil || oldSearchUsage != searchUsage { persistUsage() }

        discovery.updated = { [weak self] records, elapsed in
            guard let self else { return }
            self.appIdentities = Dictionary(uniqueKeysWithValues: records.map { ($0.id,$0.identity) })
            self.apps = records.map(\.url); self.lastScanSeconds = elapsed
            self.scanStatus = "已索引 \(records.count) 个应用"
        }
        discovery.failed = { [weak self] text in self?.error = text }
        fileSearch.updated = { [weak self] files, status in
            guard let self else { return }
            if self.fileResults != files { self.fileResults = files }
            else if self.pageID == .root {
                self.commandSearch.invalidate()
                self.rootSearchUpdates.send()
            }
            if self.fileSearchStatus != status { self.fileSearchStatus = status }
        }
        refreshLogin()
        moduleActivationRevocations = launcherModules?.activationRevocations.sink { [weak self] revocation in
            guard let self else { return }
            if let cleanup = self.registeredPageCleanup {
                self.leaveRegisteredPage(cleanup.page, activation: revocation.activation)
            }
            // File actions can take focus after the launcher page has already left.
            let owner = FilePresentationOwner.extensionActivation(revocation.activation.id)
            FilePreview.shared.dismiss(owner: owner)
            FileActionsWindow.shared.dismiss(owner: owner)
            if self.launcherModules?.module(forPage: self.pageID) == revocation.module { self.pageID = .root }
        }
        moduleSearchChanges = launcherModules?.searchInvalidations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] module in
                self?.commandSearch.invalidate(module: module)
                self?.rootSearchUpdates.send()
            }
    }
    func acquireApplicationCatalog(for consumer: ApplicationCatalogConsumer) {
        guard applicationCatalogConsumers.insert(consumer).inserted,
              applicationCatalogConsumers.count == 1 else { return }
        applicationSettingsCatalog.start()
        reloadCatalog()
        refreshRunningApps()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshRunningApps() })
        }
    }
    private func stopApplicationDiscovery() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        discovery.stop()
    }
    func releaseApplicationCatalog(for consumer: ApplicationCatalogConsumer) {
        guard applicationCatalogConsumers.remove(consumer) != nil, applicationCatalogConsumers.isEmpty else { return }
        stopApplicationDiscovery()
        applicationSettingsCatalog.stop()
        commandSearch.releasePreparedNames()
        apps = []
        appIdentities = [:]
        runningPaths = []
        WorkspaceItemIcon.discardCachedImages()
    }
    deinit { stopApplicationDiscovery() }
    func refreshRunningApps() { runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }) }
    func reloadCatalog() {
        UserDefaults.standard.set(roots, forKey: "applicationRoots"); UserDefaults.standard.set(Array(excluded), forKey: "excludedApps")
        scanStatus = "正在扫描…"; discovery.configure(roots: roots, excluded: excluded, customDepth: applicationCustomDepth == 3 ? 3 : nil)
    }
    func addRoot() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url, !roots.contains(url.path) { roots.append(url.path); reloadCatalog() } }
    func setAlias(_ id: String, value: String) { aliases[id] = value.trimmingCharacters(in: .whitespacesAndNewlines); UserDefaults.standard.set(aliases, forKey: "aliases") }
    func perform(_ entry: Entry) {
        guard let fallbackQuery = entry.fallbackQuery else {
            runCommand(entry.commandID, origin: .search, usageKey: entry.id)
            return
        }
        guard pageID == .root, fallbackQuery == query,
              commands.contains(where: { $0.id == entry.id && $0.fallbackQuery == fallbackQuery }) else { return }
        launcherModules?.invokeFallback(entry.commandID, query: fallbackQuery) { destination in
            switch destination {
            case .action: break
            case let .page(page):
                openPage(page, origin: .search, initialQuery: fallbackQuery)
            case let .settings(page):
                openSettings(page: page)
            }
        }
    }
    @discardableResult
    func runCommand(_ id: CommandID, origin: LauncherCommandOrigin, usageKey: String? = nil, arguments: [String] = [], aiSource: AIActionSource? = nil) -> Bool {
        let queryKey = usageKey != nil && pageID == .root && origin != .shortcut ? SearchUsageHistory.queryKey(query) : nil
        let admitted = launcherModules?.invoke(id, origin: origin, arguments: arguments, aiSource: aiSource) { destination in
            switch destination {
            case .action: break
            case let .page(page): openPage(page, origin: origin)
            case let .settings(page): openSettings(page: page)
            }
        }
        if admitted == true, let usageKey { recordUsage(for: usageKey, queryKey: queryKey) }
        return admitted == true
    }
    func openPage(_ page: PageID, origin: LauncherCommandOrigin, initialQuery: String? = nil) {
        guard launcherModules?.page(page) != nil else { return }
        if pageID != page { pendingPageEntry = initialQuery.map { (page, .query($0)) } }
        pageID = page
        if origin != .search { (NSApp.delegate as? Delegate)?.revealLauncherDestination() }
    }
    func openPageWithExistingDraft(_ page: PageID) {
        guard launcherModules?.page(page)?.entryDraft != nil else { return }
        pendingPageEntry = (page, .existingDraft)
        pageID = page
        (NSApp.delegate as? Delegate)?.revealLauncherDestination()
    }
    func goBackInLauncher() {
        guard pageID != .root else { return }
        let page = activeLauncherPage
        if let back = page?.back { back() }
        else if let parent = page?.parent, launcherModules?.page(parent) != nil { pageID = parent }
        else { pageID = .root }
    }
    func cancelLauncherPage() {
        if launcherEscapeBehavior.returnsToParent(from: pageID) { goBackInLauncher() }
        else { (NSApp.delegate as? Delegate)?.hideLauncher() }
    }
    func launch(_ url: URL) {
        if NSWorkspace.shared.open(url) { (NSApp.delegate as? Delegate)?.hideLauncher() }
        else { error = "无法打开应用，路径可能已经失效。"; discovery.refresh() }
    }
    func launch(_ url: URL, arguments: [String]) {
        let queryKey = pageID == .root ? SearchUsageHistory.queryKey(query) : nil
        let configuration = NSWorkspace.OpenConfiguration(); configuration.arguments = arguments; configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async { if let error { self?.error = error.localizedDescription } else { self?.recordUsage(for: url.path, queryKey: queryKey); (NSApp.delegate as? Delegate)?.hideLauncher() } }
        }
    }
    func setShortcut(_ action: String, value: Shortcut?) {
        do {
            try updateShortcut(action, value: value)
            error = ""
        } catch { self.error = error.localizedDescription }
    }

    func updateShortcut(_ action: String, value: Shortcut?) throws {
        var proposed = bindings
        proposed[action] = value
        try updateShortcuts(proposed)
    }

    func updateShortcuts(_ proposed: [String: Shortcut]) throws {
        let data = try JSONEncoder().encode(proposed)
        try (NSApp.delegate as? Delegate)?.shortcuts.apply(proposed)
        bindings = proposed
        UserDefaults.standard.set(data, forKey: "shortcuts")
    }
    func setHyperKey(_ value: Bool) {
        if value {
            guard requestModifierAccess(needsInputMonitoring: true) else { return }
        }
        hyperkey = value
        configureModifiers()
    }

    func setDoubleTap(_ value: String) {
        if value != "off" {
            guard requestModifierAccess(needsInputMonitoring: false) else { return }
        }
        doubleTap = value
        configureModifiers()
    }

    private func requestModifierAccess(needsInputMonitoring: Bool) -> Bool {
        guard AXIsProcessTrusted() else {
            requestKeyboardAccess()
            modifierStatus = "请先授予辅助功能权限，再启用修饰键快捷方式。"
            return false
        }
        if needsInputMonitoring && !CGPreflightListenEventAccess() && !CGRequestListenEventAccess() {
            modifierStatus = "请先授予输入监控权限，再启用 Hyper Key。"
            return false
        }
        return true
    }

    func configureModifiers() {
        guard let delegate = NSApp.delegate as? Delegate else { return }
        if !AXIsProcessTrusted() {
            doubleTap = "off"
            hyperkey = false
        } else if hyperkey && !CGPreflightListenEventAccess() {
            hyperkey = false
        }
        if let issue = delegate.modifiers.configure(doubleTap: doubleTap, hyper: hyperkey, includeShift: hyperIncludesShift) {
            modifierStatus = issue
        } else { modifierStatus = doubleTap == "off" && !hyperkey ? "未启用" : "已启用（需实际键盘验证）" }
        UserDefaults.standard.set(doubleTap, forKey: "doubleTap"); UserDefaults.standard.set(hyperkey, forKey: "hyperkey")
    }
    func requestKeyboardAccess() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    func refreshLogin() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        switch status { case .enabled: loginStatus = "已开启"; case .requiresApproval: loginStatus = "需要在系统设置中批准"; case .notRegistered: loginStatus = "未开启"; default: loginStatus = "当前安装方式不可用" }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { self.error = error.localizedDescription }; refreshLogin()
    }
    func applicationSearchEntries() -> [Entry] {
        let locale = Locale.current
        if let applicationEntries, applicationEntries.locale == locale { return applicationEntries.rows }
        var counts: [String: Int] = [:]
        let visible = apps.compactMap { url -> (path: String, name: String, key: String, aliases: [String])? in
            let path = url.path
            guard !excluded.contains(path) else { return nil }
            let identity = appIdentities[path]
            let name = identity?.displayName ?? url.deletingPathExtension().lastPathComponent
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            counts[key, default: 0] += 1
            return (path, name, key, identity?.aliases ?? [])
        }
        let rows = visible.map { app in
            let duplicate = counts[app.key, default: 0] > 1
            return Entry(id: app.path, commandID: .init(rawValue: "app:" + app.path), name: app.name,
                         detail: "Application", symbol: "app", aliases: duplicate ? app.aliases + [app.path] : app.aliases,
                         subtitle: duplicate ? (app.path as NSString).abbreviatingWithTildeInPath : nil)
        }
        applicationEntries = (locale, rows)
        return rows
    }

    func discoveredIdentity(for url: URL) -> ApplicationIdentity? { appIdentities[url.path] }
    func appName(_ url: URL) -> String { appIdentities[url.path]?.displayName ?? url.deletingPathExtension().lastPathComponent }
    var searchesFilesHere: Bool {
        fileSearch.isRunning && fileSearch.options.enabled
            && (activeLauncherPage?.contentPlacement == .fileResults
                || (pageID == .root && (fileSearch.options.searchFromLauncher || FileSearchLocation.typedURL(query) != nil)))
    }

    func searchFiles() {
        guard searchesFilesHere else {
            fileSearch.cancel()
            if !fileResults.isEmpty { fileResults = [] }
            return
        }
        if query != fileDetailPath { fileDetailPath = nil }
        fileSearch.search(query, includeContents: pageID != .root || rootFileContentSearch,
                          standalone: pageID != .root, showPathItself: query == fileDetailPath)
    }

    func showFileLocation(_ url: URL, browse: Bool) {
        do {
            let file = try fileSearch.inspect(url)
            guard !browse || file.isDirectory else { throw CocoaError(.fileReadUnknown) }
            fileDetailPath = browse ? nil : file.id
            if pageID == BuiltinLauncherModules.fileSearchPage {
                if query == file.id { searchFiles() } else { query = file.id }
            } else {
                fileSearchSeed = file.id
                openPage(BuiltinLauncherModules.fileSearchPage, origin: .search)
            }
        } catch { fileActionFeedback(error.localizedDescription, style: .failure) }
    }

    func withFileResult(_ url: URL, perform: (SpotlightFile) -> Void) {
        do { perform(try fileSearch.inspect(url)) }
        catch { fileActionFeedback(error.localizedDescription, style: .failure) }
    }

    func performFileMutation(_ url: URL, trash: Bool) {
        guard !mutatingFiles.contains(url.path) else { return }
        let target: FileResultOperations.Target
        do { target = try fileSearch.mutationTarget(url) }
        catch { fileActionFeedback(error.localizedDescription, style: .failure); return }
        mutatingFiles.insert(url.path)
        let execute = { [weak self] in
            guard let self else { return }
            do { _ = try self.fileSearch.mutationTarget(url) }
            catch {
                self.mutatingFiles.remove(url.path)
                self.fileActionFeedback(error.localizedDescription, style: .failure)
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { () -> URL in
                    if trash { try FileResultOperations.trash(target); return target.url }
                    return try FileResultOperations.duplicate(target)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.mutatingFiles.remove(url.path)
                    switch result {
                    case .success(let changed):
                        self.fileSearch.refreshAfterFileAction(changed, removed: trash)
                        self.fileActionFeedback(trash ? "已移到废纸篓" : "已创建「\(changed.lastPathComponent)」", style: .success)
                    case .failure(let error):
                        self.fileActionFeedback(error.localizedDescription, style: .failure)
                    }
                }
            }
        }
        if trash {
            guard let window = (NSApp.delegate as? Delegate)?.window, window.attachedSheet == nil else {
                mutatingFiles.remove(url.path)
                return
            }
            let alert = NSAlert()
            alert.messageText = "将「\(url.lastPathComponent)」移到废纸篓？"
            alert.informativeText = url.path
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertSecondButtonReturn { execute() }
                else { self?.mutatingFiles.remove(url.path) }
            }
        } else { execute() }
    }

    func fileActionFeedback(_ message: String, style: ToastStyle) {
        (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: style)
    }

    func chooseFileSearchFolder(returnToLauncher: Bool = false) {
        fileSearch.addScope()
        if returnToLauncher { (NSApp.delegate as? Delegate)?.revealLauncherDestination() }
    }
    func openFile(_ url: URL) {
        guard !fileSearch.isSearching else { return }
        do {
            let file = try fileSearch.inspect(url)
            guard NSWorkspace.shared.open(file.url) else { throw CocoaError(.fileReadUnknown) }
            fileSearch.rememberOpenedFile(file)
            (NSApp.delegate as? Delegate)?.hideLauncher()
        } catch {
            fileActionFeedback("无法打开文件。\(error.localizedDescription)", style: .failure)
            searchFiles()
        }
    }
    func launchFromHotkey(_ url: URL) {
        guard applicationsEnabled, !excluded.contains(url.path) else { return }
        if applicationHotkeyAction == "toggle",
           let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }), running.isActive {
            running.hide()
        } else { launch(url) }
    }
    var commands: [Entry] { commands(in: nil) }

    func commands(in namespace: LauncherCommandNamespace?) -> [Entry] {
        commands(in: namespace, query: query, page: pageID)
    }

    func commands(in namespace: LauncherCommandNamespace?, query: String, page: PageID) -> [Entry] {
        guard let launcherModules else { return [] }
        let input = LauncherCommandSearch.Input(query: query, page: page,
                                                aliases: aliases, favorites: favorites, usage: usage,
                                                favoriteOrder: orderedFavoriteIDs, history: page == .root ? searchUsage : .init(),
                                                sensitivity: rootSearchSensitivity, namespace: namespace,
                                                fallbackOrder: fallbackCommandOrder,
                                                allowsFallback: !searchesFilesHere ||
                                                    (!fileSearch.isSearching && fileSearch.lastPublishedQuery == query))
        return commandSearch.results(for: input, registry: launcherModules)
    }
}
final class LauncherPanel: NSPanel {
    var dragHandler: ((NSEvent) -> Void)?
    var cancelWithoutFocusedView: (() -> Bool)?

    var pageScrollHandler: ((NSEvent) -> Bool)?
    var isCompactShortcutPoint: ((CGPoint) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, pageScrollHandler?(event) == true { return }
        if event.type == .keyDown, event.keyCode == 53, isKeyWindow, attachedSheet == nil,
           event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty {
            if event.isARepeat { return }
            // Local event monitors have already run. An editor or focused control
            // still receives AppKit's Cancel command through its normal responder chain.
            if firstResponder === self || firstResponder == nil,
               cancelWithoutFocusedView?() == true { return }
        }
        // Keep a narrow drag area above the hosted search field.
        let point = event.locationInWindow
        if event.type == .leftMouseDown, dragHandler != nil,
           point.y >= frame.height - 10, point.y < frame.height,
           point.x >= 28, point.x <= frame.width - 28,
           isCompactShortcutPoint?(point) != true {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    override func performDrag(with event: NSEvent) {
        if let dragHandler { dragHandler(event) }
        else { super.performDrag(with: event) }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var previousApplication: NSRunningApplication?
    let toast = ToastPresenter()

    func rememberPreviousApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        previousApplication = app
        model.launcherModules?.applicationFocused(app)
    }
    var pasteTargetName: String? {
        guard let previousApplication, !previousApplication.isTerminated else { return nil }
        return previousApplication.localizedName
    }
    var pasteTargetIcon: NSImage? {
        guard let previousApplication, !previousApplication.isTerminated else { return nil }
        return previousApplication.icon
    }

    private var launcherPaste = LauncherPaste()

    private var pasteCompletion: (() -> Void)?

    private var canDispatchSequentialPaste: Bool {
        model.crossAppPaste.available && !IsSecureEventInputEnabled()
            && !model.disabledCommands.contains(ClipboardSequenceCommand.paste.rawValue)
            && model.launcherModules?.isCommandModuleEnabled(.init(rawValue: ClipboardSequenceCommand.paste.rawValue)) == true
    }

    func pasteClipboardSequentially() {
        let controller = model.clipboard
        guard !launcherPaste.isPending, !controller.isSequencePastePending else {
            showLauncherFeedback("正在处理上一次粘贴。", style: .neutral)
            return
        }
        guard model.crossAppPaste.available else {
            showLauncherFeedback("请先在设置中启用跨应用粘贴。", style: .failure,
                                 actionTitle: "粘贴设置…") { [weak self] in
                self?.model.openSettings(page: "permissions")
            }
            return
        }
        guard !IsSecureEventInputEnabled() else {
            showLauncherFeedback("当前输入处于安全模式，已停止顺序粘贴。", style: .failure)
            return
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ownPID
            ? (window.isVisible && window.isKeyWindow ? previousApplication : nil)
            : frontmost
        guard let target, !target.isTerminated, target.processIdentifier != ownPID else {
            showLauncherFeedback("没有可粘贴的目标应用。", style: .failure)
            return
        }
        let startedInLauncher = window.isVisible && window.isKeyWindow
        let focused = SnippetTextTarget.focused(in: target)
        let focusUnchanged = {
            guard !IsSecureEventInputEnabled() else { return false }
            guard let focused else { return true }
            guard let current = SnippetTextTarget.focused(in: target) else { return false }
            return CFEqual(focused, current)
        }

        controller.prepareSequentialPaste(target: target.processIdentifier, isTargetCurrent: { [weak self] in
            guard let self, self.canDispatchSequentialPaste, !self.launcherPaste.isPending,
                  !target.isTerminated else { return false }
            if self.pasteTargetIsFrontmost(target) { return focusUnchanged() }
            return startedInLauncher && self.window.isVisible && self.window.isKeyWindow
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID
        }, ready: { [weak self] paste in
            guard let self else { paste.finish(); return }
            self.dispatchPaste(to: target, keepOpen: false, isFile: paste.isFile, placeCursor: nil,
                               clipboardGeneration: paste.generation, validation: { [weak self] in
                                   self?.canDispatchSequentialPaste == true && paste.isCurrent() && focusUnchanged()
                               }, didDispatch: paste.dispatched, didFinish: paste.finish)
        }, failure: { [weak self] message in
            self?.showLauncherFeedback(message, style: .failure)
        })
    }

    func resetClipboardPasteSequence() {
        if pasteCompletion != nil { cancelLauncherPaste() }
        model.clipboard.resetPasteSequence()
        showLauncherFeedback("已重置粘贴顺序", style: .success)
    }

    func pasteClipboard(format: ClipboardReplayFormat = .preferred, keepOpen: Bool = false) {
        guard !launcherPaste.isPending else { return }
        let controller = model.clipboard
        let detail = controller.selectedDetail
        let format = controller.replayFormat(format, for: detail)
        let isFile = format == .original && detail?.item.kind == .files
        guard controller.copySelected(format: format) else {
            showPasteFailure(controller.status)
            return
        }
        pasteIntoPreviousApplication(keepOpen: keepOpen, isFile: isFile,
                                     clipboardGeneration: NSPasteboard.general.changeCount) { [weak controller] in
            controller?.recordReplay(of: detail?.item.id)
        }
    }

    func pasteIntoPreviousApplication(keepOpen: Bool = false, isFile: Bool = false,
                                      placeCursor: (text: String, offset: Int)? = nil,
                                      clipboardGeneration: Int? = nil, targetApplication: NSRunningApplication? = nil,
                                      validation: (() -> Bool)? = nil, didDispatch: (() -> Void)? = nil) {
        guard !launcherPaste.isPending else { return }
        guard model.crossAppPaste.available else {
            showLauncherFeedback("已复制，跨应用粘贴未启用", style: .failure, actionTitle: "粘贴设置…") { [weak self] in
                self?.model.openSettings(page: "permissions")
            }
            return
        }
        guard let target = targetApplication ?? previousApplication, !target.isTerminated else { showPasteFailure("已复制，但上一个应用已退出或不可用。"); return }

        dispatchPaste(to: target, keepOpen: keepOpen, isFile: isFile, placeCursor: placeCursor,
                      clipboardGeneration: clipboardGeneration, validation: validation, didDispatch: didDispatch)
    }

    private func dispatchPaste(to target: NSRunningApplication, keepOpen: Bool, isFile: Bool,
                               placeCursor: (text: String, offset: Int)?, clipboardGeneration: Int?,
                               validation: (() -> Bool)? = nil, didDispatch: (() -> Void)?,
                               didFinish: (() -> Void)? = nil) {
        let keepsLauncherOpen = keepOpen && window.isVisible
        if !keepsLauncherOpen {
            if validation == nil { hideLauncher() }
            else { hideLauncher(reason: "pasteDispatch") }
        }
        guard let request = launcherPaste.begin(keepingLauncherOpen: keepsLauncherOpen) else { didFinish?(); return }
        pasteCompletion = didFinish
        target.activate()

        if isFile {
            pasteFileIntoApplication(target, request: request, clipboardGeneration: clipboardGeneration,
                                     validation: validation, didDispatch: didDispatch)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.launcherPaste.isCurrent(request) else { return }
            guard self.pasteTargetIsFrontmost(target) else {
                self.finishPaste(request, target: target)
                self.showPasteFailure("已复制。目标应用未获得焦点，已停止自动粘贴。")
                return
            }
            guard validation?() != false, self.pasteTargetIsFrontmost(target),
                  clipboardGeneration.map({ self.model.crossAppPaste.available && NSPasteboard.general.changeCount == $0 }) != false else {
                self.finishPaste(request, target: target)
                self.showPasteFailure("剪贴板、目标选区、焦点或粘贴权限已变化，已停止自动粘贴。")
                return
            }
            let original = placeCursor == nil ? nil : SnippetTextTarget.position(in: target)
            guard self.postPasteShortcut() else {
                self.finishPaste(request, target: target)
                self.showPasteFailure("已复制，无法发送粘贴按键。")
                return
            }
            didDispatch?()
            if let placeCursor, let original {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard self?.pasteTargetIsFrontmost(target) == true,
                          let current = SnippetTextTarget.position(in: target),
                          CFEqual(original.element, current.element), current.range.length == 0,
                          current.range.location == original.range.location + placeCursor.text.utf16.count,
                          current.text == (original.text as NSString).replacingCharacters(
                              in: NSRange(location: original.range.location, length: original.range.length),
                              with: placeCursor.text) else { return }
                    _ = SnippetTextTarget.select(CFRange(location: original.range.location + placeCursor.offset, length: 0),
                                                 in: current.element)
                }
            }
            self.finishDispatchedPaste(request, target: target)
        }
    }

    private func pasteFileIntoApplication(_ target: NSRunningApplication, request: LauncherPaste.Request,
                                          clipboardGeneration: Int?, validation: (() -> Bool)?,
                                          didDispatch: (() -> Void)?) {
        let generation = clipboardGeneration ?? NSPasteboard.general.changeCount
        let isCurrent = { [weak self] in
            guard let self, self.launcherPaste.isCurrent(request) else { return false }
            return validation?() != false && self.model.crossAppPaste.available && self.pasteTargetIsFrontmost(target)
                && NSPasteboard.general.changeCount == generation
        }
        SystemNavigation.shared.pasteFile(in: target, isCurrent: isCurrent) { [weak self] result in
            guard let self, self.launcherPaste.isCurrent(request) else { return }
            let sent: Bool
            switch result {
            case .performed:
                sent = true
            case .useKeyboard:
                sent = isCurrent() && self.postPasteShortcut()
            case .cancelled, .failed:
                sent = false
            }
            if sent {
                didDispatch?()
                self.finishDispatchedPaste(request, target: target)
            } else {
                self.finishPaste(request, target: target)
                self.showPasteFailure("未能在目标应用中自动粘贴文件。")
            }
        }
    }

    private func postPasteShortcut() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        ModifierShortcuts.postWithoutHyperRemapping(down)
        ModifierShortcuts.postWithoutHyperRemapping(up)
        return true
    }

    private func pasteTargetIsFrontmost(_ target: NSRunningApplication) -> Bool {
        !target.isTerminated && NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func finishDispatchedPaste(_ request: LauncherPaste.Request, target: NSRunningApplication) {
        if request.keepsLauncherOpen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.finishPaste(request, target: target)
            }
        } else {
            completeLauncherPaste(request)
        }
    }

    private func completeLauncherPaste(_ request: LauncherPaste.Request) {
        guard launcherPaste.isCurrent(request) else { return }
        launcherPaste.finish(request)
        let completion = pasteCompletion
        pasteCompletion = nil
        completion?()
    }

    private func cancelLauncherPaste() {
        launcherPaste.cancel()
        let completion = pasteCompletion
        pasteCompletion = nil
        completion?()
    }

    private func finishPaste(_ request: LauncherPaste.Request, target: NSRunningApplication) {
        guard launcherPaste.isCurrent(request) else { return }
        defer { completeLauncherPaste(request) }
        guard request.keepsLauncherOpen else { return }
        if pasteTargetIsFrontmost(target), window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if !window.isKeyWindow {
            hideLauncher()
        }
    }

    private func showPasteFailure(_ message: String) {
        guard settingsWindow?.isKeyWindow != true else { return }
        showLauncherFeedback(message, style: .failure)
    }
    let model = Model()
    var settingsWindow: NSWindow?
    private var settingsToolbarSizing: AnyCancellable?
    private let onboarding = OnboardingWindowController()
    var window: NSWindow!
    let shortcuts = ShortcutManager()
    private var shortcutRegistrationChanges: Set<AnyCancellable> = []
    let modifiers = ModifierShortcuts()
    var outsideMonitor: Any?
    var localMonitor: Any?
    private var outsidePageScrollMonitor: Any?
    let windowDiagnostics = WindowDiagnostics()
    var hotkeyStatus: Int32 = 0
    private var errorSubscription: AnyCancellable?
    var appearanceSubscription: AnyCancellable?
    var geometrySubscription: AnyCancellable?
    private var dragGuides: LauncherDragGuides?
    private var resizeTimer: Timer?
    private var resizeTarget: NSRect?
    private var launcherHiddenAt: TimeInterval?
    private var idleMemoryTrim: DispatchWorkItem?
    private var restingLauncherFrame: NSRect?
    private var launcherGlassSubscription: AnyCancellable?
    private var pageScroll = HorizontalScrollSelection()
    private var pageScrollSample: TimeInterval?
    private var pageScrollVelocity: CGFloat = 0

    private func resetPageScroll() {
        pageScroll.reset()
        pageScrollSample = nil
        pageScrollVelocity = 0
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.model.aiSettings.startModelCatalogSync(runtime: self.model.aiRuntime)
        }
        FileActionsWindow.shared.onEscape = { [weak self] in self?.closeUtilityWindowOnEscape() }
        FileActionsWindow.shared.onActivate = { [weak self] window in
            self?.model.windowActivationBehavior.apply(to: window)
        }
        installApplicationMenu(settingsTarget: self, settingsAction: #selector(openLauncherSettings))
        window = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: VisualStyle.launcherWidth, height: 470), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Keylane · Developer Preview"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: Launcher(model: model))
        // The panel owns the viewport, including fractional interface scales.
        hosting.sizingOptions = []
        let backing = LauncherGlassHostView(content: hosting)
        launcherGlassSubscription = model.$presentedLauncherHeight.sink { [weak backing] height in
            backing?.glass.alphaValue = Model.launcherBackdropOpacity(at: height)
        }
        window.contentView = backing; window.isReleasedWhenClosed = false; window.center()
        window.delegate = self
        dragGuides = LauncherDragGuides(window: window)
        (window as? LauncherPanel)?.dragHandler = { [weak self] event in self?.dragGuides?.performDrag(with: event) }
        (window as? LauncherPanel)?.isCompactShortcutPoint = { [weak self] point in
            self?.compactShortcut(at: point) != nil
        }
        (window as? LauncherPanel)?.pageScrollHandler = { [weak self] event in
            self?.handlePageScroll(event) ?? false
        }
        window.autorecalculatesKeyViewLoop = true
        appearanceSubscription = model.$appearance.sink { [weak self] value in
            let appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
            self?.window.appearance = appearance; self?.settingsWindow?.appearance = appearance
            self?.model.dropShelf.applyAppearance(value)
        }
        errorSubscription = model.$error.filter { !$0.isEmpty }.sink { [weak self] message in
            self?.showLauncherFeedback(message, style: .failure)
        }
        // Observe geometry inputs only. Other model changes do not resize the window.
        geometrySubscription = Publishers.MergeMany([
            model.$interfaceSize.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$windowMode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$pageID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$query.map(\.isEmpty).removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.footerFeedback.$current.map { $0 != nil }.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$compactExpanded.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        .debounce(for: .zero, scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateLauncherGeometry() }
        updateLauncherGeometry()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.window.attachedSheet == nil else { return }
            if self.routeCompactShortcutClick(event, at: NSEvent.mouseLocation) { return }
            self.hideLauncher(reason: "outsideClick")
        }
        // Scroll events follow the pointer. A key launcher is often opened
        // by shortcut while the pointer is still over the previous app.
        outsidePageScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.window.isVisible, self.window.isKeyWindow else { return }
            _ = self.handlePageScroll(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.window, self.window.attachedSheet == nil,
               !FilePreview.shared.owns(event.window) {
                let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                if self.routeCompactShortcutClick(event, at: location) { return nil }
                self.hideLauncher(reason: "otherWindow")
            }
            return event
        }
        model.menuBar.register(id: "keylane.launcher", owner: "launcher", title: "Keylane", defaultVisible: true,
                               presentation: .init(symbol: "command", toolTip: "打开 Keylane")) { [weak self] in
            var commands: [MenuBarCommand] = [.init(title: "打开 Keylane", symbol: "command", action: { self?.revealLauncher() })]
            let calendar = CommandID(rawValue: "calendar")
            if self?.model.launcherModules?.isCommandModuleEnabled(calendar) == true {
                commands.append(.init(title: "我的日程", symbol: "calendar", action: { self?.model.runCommand(calendar, origin: .menu) }))
            }
            commands += [.init(title: "设置…", symbol: "gearshape", action: { self?.openLauncherSettings() }),
                         .separator, .init(title: "退出 Keylane", action: { NSApplication.shared.terminate(nil) })]
            return commands
        }
        shortcuts.scopeForAction = { [weak registry = model.launcherModules] action in
            registry?.shortcutScope(for: CommandID(rawValue: action)) ?? .native
        }
        if let registry = model.launcherModules {
            registry.activationRevocations.sink { [weak self] _ in
                self?.shortcuts.removeStaleRegistrations()
            }.store(in: &shortcutRegistrationChanges)
            registry.registrationUpdates.sink { [weak self] in
                guard let self else { return }
                do { try self.shortcuts.refreshExtensions() }
                catch { self.model.error = error.localizedDescription }
            }.store(in: &shortcutRegistrationChanges)
        }
        shortcuts.fired = { [weak self] action in
            guard let self else { return }
            if action == "launcher" { self.show() }
            else {
                let appKey = action.hasPrefix("app:") ? String(action.dropFirst("app:".count)) : nil
                self.model.runCommand(.init(rawValue: action), origin: .shortcut, usageKey: appKey)
            }
        }
        shortcuts.released = { [weak self] action in
            if ["dictate", "dictate-to-note", "dictate-to-ai"].contains(action) { self?.model.dictation.releaseShortcut() }
        }
        do { try shortcuts.restore(model.bindings); hotkeyStatus = 0 } catch { hotkeyStatus = -1; model.error = error.localizedDescription }
        modifiers.activate = { [weak self] in self?.show() }
        model.configureModifiers()
        model.launcherModules?.startServices()
        model.updates.start()
        if onboarding.isComplete { show() }
        else { showOnboarding() }
    }
    func showOnboarding() {
        hideLauncher()
        onboarding.show(model: model) { [weak self] in self?.revealLauncher() }
    }

    @objc func revealLauncher() { activateLauncher(toggle: false) }

    /// Explicit commands already chose a destination, so keep it when making the window visible.
    func revealLauncherDestination() {
        if onboarding.isVisible {
            onboarding.bringToFront()
            return
        }
        showCurrentLauncherPage()
    }

    private func showCurrentLauncherPage() {
        if !window.isVisible {
            presentLauncher()
        } else {
            cancelLauncherPaste()
            model.clipboard.cancelPendingSequentialPaste()
            rememberPreviousApplication()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .launcherShown, object: nil)
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let id = urls.compactMap(AIChatLink.parse).first else { return }
        model.openAIChatLink?(id)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding.isVisible { onboarding.bringToFront() }
        else if !window.isVisible { show() }
        else {
            cancelLauncherPaste()
            model.clipboard.cancelPendingSequentialPaste()
            window.makeKeyAndOrderFront(nil)
            windowDiagnostics.record("reopen", launcher: window, settings: settingsWindow, hotkeyStatus: hotkeyStatus)
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        guard let settings = notification.object as? NSWindow, settings === settingsWindow else { return }
        // AppKit is still completing the close. Detach on the next turn so
        // a closed settings window does not retain its SwiftUI pages and rows.
        DispatchQueue.main.async { [weak self, weak settings] in
            guard let self, let settings, settings === self.settingsWindow, !settings.isVisible else { return }
            self.settingsToolbarSizing = nil
            settings.contentView = nil
            settings.toolbar = nil
            for index in settings.titlebarAccessoryViewControllers.indices.reversed() {
                settings.removeTitlebarAccessoryViewController(at: index)
            }
            self.settingsWindow = nil
            self.scheduleIdleMemoryTrim()
        }
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let settingsWindow, notification.object as? NSWindow === settingsWindow else { return }
        toast.hide()
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let resigned = notification.object as? NSWindow, resigned === window, window.attachedSheet == nil,
              !FilePreview.shared.takesLauncherFocus, !launcherPaste.keepsLauncherOpen else { return }
        hideLauncher(reason: "resignKey")
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.launcherModules?.stopServices()
        model.focus.browser.flush()
        model.menuBar.shutdown()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let outsidePageScrollMonitor { NSEvent.removeMonitor(outsidePageScrollMonitor) }
        shortcuts.stop(); modifiers.stop()
        model.updates.installOnQuit()
    }
    @objc private func openLauncherSettings() {
        model.runCommand(.init(rawValue: "settings"), origin: .menu)
    }
    func closeUtilityWindowOnEscape() {
        guard model.escapeClosesUtilityWindows, !SearchField.isComposing, NSApp.modalWindow == nil,
              let keyWindow = NSApp.keyWindow, keyWindow !== window, keyWindow.attachedSheet == nil else { return }
        keyWindow.performClose(nil)
    }
    func showSettings() {
        if settingsWindow == nil {
            let state = SettingsWindowState(model: model)
            let view = NSHostingView(rootView: SettingsView(state: state))
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            settings.title = "Keylane 设置"; settings.titlebarAppearsTransparent = false; settings.titleVisibility = .visible; settings.isReleasedWhenClosed = false
            settings.appearance = window.appearance; settings.autorecalculatesKeyViewLoop = true
            settings.contentView = view
            let trailingActions = NSTitlebarAccessoryViewController()
            trailingActions.layoutAttribute = .right
            trailingActions.view = NSHostingView(rootView: SettingsWindowActions(state: state))
            trailingActions.view.frame.size.height = 44
            settings.addTitlebarAccessoryViewController(trailingActions)
            settingsToolbarSizing = state.$page.removeDuplicates().sink { [weak trailingActions, weak state] page in
                guard let trailingActions else { return }
                let width = SettingsWindowActions.width(for: state?.catalog.page(page),
                                                        hasExtensionSwitch: state?.extensionEnabled(for: page) != nil)
                trailingActions.view.frame.size.width = width
                trailingActions.isHidden = width == 0
            }
            settings.center()
            settings.setFrameAutosaveName("KeylaneSettings")
            // Restore the saved height and position, but always use the system settings width.
            settings.minSize = NSSize(width: 740, height: 600)
            settings.maxSize = NSSize(width: 740, height: CGFloat.greatestFiniteMagnitude)
            var settingsFrame = settings.frame
            settingsFrame.size.width = 740
            settings.setFrame(settingsFrame, display: false)
            settings.delegate = self
            settingsWindow = settings
        }
        hideLauncher()
        if let settingsWindow {
            model.windowActivationBehavior.apply(to: settingsWindow)
            settingsWindow.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func showLauncherFeedback(_ message: String, style: ToastStyle,
                              actionTitle: String? = nil, action: (() -> Void)? = nil) {
        if let window, window.isVisible {
            model.footerFeedback.show(message, style: style, in: window, actionTitle: actionTitle, action: action)
        } else {
            toast.show(message, style: style)
        }
    }

    func hideLauncher(reason: String = "command") {
        if window.isVisible || reason == "outsideClick" {
            cancelLauncherPaste()
            if reason != "pasteDispatch" { model.clipboard.cancelPendingSequentialPaste() }
        }
        dragGuides?.cancel()
        guard window.isVisible else { return }
        resizeTimer?.invalidate()
        resizeTimer = nil
        resizeTarget = nil
        if model.placement == "remember" { window.saveFrame(usingName: "KeylaneLauncher") }
        launcherHiddenAt = ProcessInfo.processInfo.systemUptime
        window.orderOut(nil)
        if model.windowMode == "compact", model.pageID == .root, model.query.isEmpty {
            model.compactExpanded = false
        }
        pageScroll.reset()
        model.footerFeedback.clear()
        NotificationCenter.default.post(name: .launcherHidden, object: nil)
        windowDiagnostics.record("hidden:" + reason, launcher: window, settings: settingsWindow, hotkeyStatus: hotkeyStatus)
        scheduleIdleMemoryTrim()
    }

    private func scheduleIdleMemoryTrim() {
        idleMemoryTrim?.cancel()
        let trim = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.idleMemoryTrim = nil
            guard !self.window.isVisible, self.settingsWindow?.isVisible != true else { return }
            if self.restingLauncherFrame == nil,
               self.model.pageID == .root || self.model.activeLauncherPage?.contentPlacement == .fileResults {
                // The released surface no longer needs a full-size window backing.
                self.restingLauncherFrame = self.window.frame
                self.window.setContentSize(NSSize(width: 1, height: 1))
            }
            WorkspaceItemIcon.discardCachedImages()
            // Let the hidden views finish releasing their objects before
            // returning unused allocator pages to the system.
            DispatchQueue.global(qos: .utility).async {
                _ = malloc_zone_pressure_relief(nil, 0)
            }
        }
        idleMemoryTrim = trim
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: trim)
    }

    private func compactShortcut(at windowPoint: CGPoint) -> CompactLauncherShortcut? {
        guard window.isVisible, model.isCompact,
              model.presentedLauncherHeight <= VisualStyle.launcherTopInset + 0.5 else { return nil }
        let scale = model.interfaceScale
        return CompactLauncherButtonGeometry.shortcut(at: CGPoint(
            x: windowPoint.x / scale, y: (window.frame.height - windowPoint.y) / scale
        ))
    }

    private func routeCompactShortcutClick(_ event: NSEvent, at screenPoint: CGPoint) -> Bool {
        // The WindowServer can assign a click on a glass rim to the window
        // behind it. Use the same circular geometry as the visible button.
        guard event.type == .leftMouseDown,
              let shortcut = compactShortcut(at: window.convertPoint(fromScreen: screenPoint)) else { return false }
        if model.launcherModules?.isRegisteredCommandEnabled(shortcut.id) == true {
            model.runCommand(shortcut.id, origin: .search, usageKey: shortcut.id.rawValue)
        }
        return true
    }

    private func handlePageScroll(_ event: NSEvent) -> Bool {
        guard !model.isCompact, model.presentedLauncherHeight > VisualStyle.launcherTopInset + 0.5,
              model.swipeDestinations.contains(where: { $0.page == model.pageID }),
              !SearchField.isComposing else {
            resetPageScroll()
            return false
        }
        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        let phase = event.phase
        let isHorizontal = HorizontalScrollSelection.isHorizontal(horizontal, vertical)
        if !event.momentumPhase.isEmpty { return isHorizontal }
        if phase.contains(.began) { resetPageScroll() }
        if phase.contains(.cancelled) {
            resetPageScroll()
            model.launcherPageSwipes.send(.finish(nil, velocity: 0))
            return isHorizontal
        }
        if phase.isEmpty {
            guard isHorizontal else { return false }
            let threshold: Double = event.hasPreciseScrollingDeltas ? 8 : 1
            if let distance = pageScroll.drag(horizontal: horizontal, vertical: vertical), abs(distance) >= threshold,
               let direction = pageScroll.finish(threshold: threshold) {
                model.launcherPageSwipes.send(.finish(direction, velocity: 0))
            }
            return true
        }
        if let distance = pageScroll.drag(horizontal: horizontal, vertical: vertical) {
            if let previous = pageScrollSample {
                let interval = max(1.0 / 120, event.timestamp - previous)
                pageScrollVelocity = pageScrollVelocity * 0.35 + horizontal / interval * 0.65
            }
            pageScrollSample = event.timestamp
            model.launcherPageSwipes.send(.drag(CGFloat(distance)))
        }
        if phase.contains(.ended) {
            let sampleAge = event.timestamp - (pageScrollSample ?? 0)
            let velocity = sampleAge < 0.08 ? pageScrollVelocity : 0
            let direction = pageScroll.finish(threshold: 32)
            resetPageScroll()
            model.launcherPageSwipes.send(.finish(direction, velocity: velocity))
        }
        return isHorizontal
    }

    func updateLauncherGeometry(animated: Bool = true) {
        guard window != nil, restingLauncherFrame == nil else { return }
        let backingScale = max(1, window.backingScaleFactor)
        // Align the requested size before comparing it with AppKit's frame.
        // A value like 760 * 1.1 can otherwise round up by an entire point.
        let size = NSSize(
            width: (VisualStyle.launcherWidth * model.interfaceScale * backingScale).rounded() / backingScale,
            height: (model.launcherHeight * model.interfaceScale * backingScale).rounded() / backingScale
        )
        let start = window.frame
        let tolerance = 1 / backingScale
        if animated, resizeTarget?.size == size { return }
        resizeTimer?.invalidate()
        resizeTimer = nil
        resizeTarget = nil

        var target = start
        target.origin.x += (start.width - size.width) / 2
        target.origin.y = start.maxY - size.height
        target.size = size
        if let area = window.screen?.visibleFrame {
            target.origin.x = max(area.minX, min(target.origin.x, area.maxX - size.width))
            target.origin.y = max(area.minY, min(target.origin.y, area.maxY - size.height))
        }
        guard abs(start.width - size.width) >= tolerance || abs(start.height - size.height) >= tolerance else {
            model.presentedLauncherHeight = model.launcherHeight
            model.compactBarMergeProgress = model.isCompact ? 0 : 1
            return
        }
        let scale = model.interfaceScale
        // AppKit may round a scaled hosting view's width by an extra point.
        let sameInterfaceWidth = abs(start.width - target.width) <= 1 + tolerance
        guard animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(start.height - target.height) > 1, sameInterfaceWidth else {
            model.presentedLauncherHeight = model.launcherHeight
            model.compactBarMergeProgress = model.isCompact ? 0 : 1
            window.setFrame(target, display: true)
            return
        }
        resizeTarget = target
        let expands = target.height > start.height
        let startsAtCompactHeight = start.height / scale <= VisualStyle.launcherTopInset + 0.5
        let initialMerge = model.compactBarMergeProgress
        let mergeDuration = expands && startsAtCompactHeight ? 0.16 * (1 - initialMerge) : 0
        let began = ProcessInfo.processInfo.systemUptime
        let duration = expands ? 0.34 : 0.23
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            if elapsed < mergeDuration {
                let phase = elapsed / mergeDuration
                self.model.compactBarMergeProgress = initialMerge + (1 - initialMerge) * phase
                return
            }
            let progress = min(1, (elapsed - mergeDuration) / duration)
            let merge: CGFloat = progress == 1 && self.model.isCompact ? 0 : 1
            if self.model.compactBarMergeProgress != merge {
                self.model.compactBarMergeProgress = merge
            }
            let eased = progress * progress * (3 - 2 * progress)
            let height = start.height + (target.height - start.height) * eased
            let top = start.maxY + (target.maxY - start.maxY) * eased
            let x = start.minX + (target.minX - start.minX) * eased
            let width = start.width + (target.width - start.width) * eased
            self.model.presentedLauncherHeight = progress == 1 ? self.model.launcherHeight : height / scale
            self.window.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: false)
            if progress == 1 {
                timer.invalidate()
                self.resizeTimer = nil
                self.resizeTarget = nil
                self.window.invalidateShadow()
            }
        }
        resizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc func show() { activateLauncher(toggle: true) }

    private func activateLauncher(toggle: Bool) {
        if onboarding.isVisible {
            onboarding.bringToFront()
            return
        }
        if toggle && window.isVisible && window.isKeyWindow { hideLauncher(); return }
        if !window.isVisible, let hiddenAt = launcherHiddenAt,
           model.launcherReturnDelay.shouldReturn(hiddenFor: ProcessInfo.processInfo.systemUptime - hiddenAt) {
            model.pageID = .root
            model.query = ""
            model.compactExpanded = false
            NotificationCenter.default.post(name: .launcherResetSearch, object: nil)
        }
        if toggle { presentLauncher() }
        else { showCurrentLauncherPage() }
    }
    /// Present the current destination without applying the launcher's compact-mode reset.
    private func presentLauncher() {
        cancelLauncherPaste()
        model.clipboard.cancelPendingSequentialPaste()
        if let frame = restingLauncherFrame {
            restingLauncherFrame = nil
            window.setFrame(frame, display: false)
        }
        launcherHiddenAt = nil
        updateLauncherGeometry(animated: false)
        rememberPreviousApplication()
        let screens = NSScreen.screens
        let pointerScreen = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let restored = model.placement == "remember" && window.setFrameUsingName("KeylaneLauncher")
        let restoredScreen = restored ? window.screen : nil
        let screen = model.placement == "primaryDisplay" ? screens.first : restoredScreen ?? pointerScreen
        if let area = screen?.visibleFrame {
            updateLauncherGeometry(animated: false)
            var frame = window.frame
            if restoredScreen == nil || !frame.intersects(area) {
                frame.origin = LauncherPositioning.target(size: frame.size, in: area).origin
            }
            frame.origin.x = max(area.minX, min(frame.origin.x, area.maxX - frame.width))
            frame.origin.y = max(area.minY, min(frame.origin.y, area.maxY - frame.height))
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.invalidateShadow()
        NotificationCenter.default.post(name: .launcherShown, object: nil)
        windowDiagnostics.record("shown", launcher: window, settings: settingsWindow, hotkeyStatus: hotkeyStatus)
        DispatchQueue.main.async { [weak self] in guard let self else { return }; self.windowDiagnostics.record("shownSettled", launcher: self.window, settings: self.settingsWindow, hotkeyStatus: self.hotkeyStatus) }
    }
}
// AppKit must exist before a pending restore can present its result. Keep all
// model/controller construction after restore so it reads the restored domain.
if CommandLine.arguments.dropFirst() == [DictionaryProcess.argument] { DictionaryProcess.run() }

let application = NSApplication.shared
#if DEBUG
if CommandLine.arguments.dropFirst() == ["--verify-dictation-ui"] {
    do { try DictationUIFixture.run(); exit(0) }
    catch { fputs("Dictation UI fixture failed: \(error)\n", stderr); exit(1) }
}
#endif
#if DEBUG
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inspect-raycast-import" {
    do { try RaycastMigrationFixture.inspect(URL(fileURLWithPath:CommandLine.arguments[2])); exit(0) }
    catch { fputs("Read-only Raycast inspection failed. No settings applied.\n", stderr); exit(1) }
}
if CommandLine.arguments.dropFirst() == ["--verify-raycast-migration"] {
    do { try RaycastMigrationFixture.run(); exit(0) }
    catch { fputs("Raycast migration fixture failed: \(error)\n", stderr); exit(1) }
}
#endif
ConfigurationTransfer.finishPending()
let delegate = Delegate()
application.delegate = delegate
application.run()
