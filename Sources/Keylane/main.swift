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
    @Published var windowMode = UserDefaults.standard.string(forKey: "windowMode") ?? "expanded" { didSet { UserDefaults.standard.set(windowMode, forKey: "windowMode") } }
    @Published var compactFavorites = (UserDefaults.standard.object(forKey: "compactFavorites") as? Bool) ?? true { didSet { UserDefaults.standard.set(compactFavorites, forKey: "compactFavorites") } }
    @Published var compactExpanded = false
    let footerFeedback = LauncherFooterFeedbackPresenter()
    var interfaceScale: CGFloat { interfaceSize == "small" ? 0.9 : interfaceSize == "large" ? 1.1 : 1 }
    var isCompact: Bool { windowMode == "compact" && pageID == .root && query.isEmpty && !compactExpanded && footerFeedback.current == nil }
    @Published var presentedLauncherHeight: CGFloat = 470
    var launcherHeight: CGFloat { isCompact ? (compactFavorites && !favorites.isEmpty ? 109 : 61) : 470 }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    @Published var query = ""
    @Published var pageID = PageID.root
    let fileAI = FileAIController()
    private var moduleSearchChanges: AnyCancellable?
    private var moduleActivationRevocations: AnyCancellable?
    private var registeredPageCleanup: (page: PageID, activation: LauncherModuleRegistry.Activation, leave: () -> Void)?
    let rootSearchUpdates = PassthroughSubject<Void, Never>()
    let clipboard = ClipboardController(startTimer: false, presentationActive: false, startStorage: false)
    let screenshots = ScreenshotLibrary()
    let systemShortcuts = SystemShortcutsController(active: false)
    let scripts = ScriptCommandsController()
    lazy var snippets = SnippetsController(storageURL: dataStoreURL)
    let quicklinks = QuicklinksController()
    let contacts = ContactsController()
    let dictionary = DictionaryController()
    let emoji = EmojiSearchController()
    let systemNavigation = NavigationController()
    let menuBar = MenuBarRegistry()
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
    let clipboardSpeech = PermissionFeature("clipboardSpeech.enabled", authorization: .persistentClipboard, observeImmediately: false)
    let applicationAutoQuit = ApplicationAutoQuit()
    private(set) lazy var applicationSettingsCatalog = ApplicationSettingsCatalog(model: self)
    @Published var runningPaths: Set<String> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    @Published var apps: [URL] = [] { didSet { applicationEntries = nil } }
    private var applicationEntries: (locale: Locale, rows: [Entry])?
    private let commandSearch = LauncherCommandSearch()
    private(set) lazy var launcherModules: LauncherModuleRegistry? = {
        do {
            let registry = try LauncherModuleRegistry(modules: BuiltinLauncherModules.make(model: self)) { [weak self] id in
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
        let owner = FilePresentationOwner.extensionActivation(activation.id)
        registeredPageCleanup = (page.id, activation, {
            page.leave()
            page.releasePreview?()
            FilePreview.shared.dismiss(owner: owner)
        })
    }

    func leaveRegisteredPage(_ page: PageID, activation: LauncherModuleRegistry.Activation) {
        guard let cleanup = registeredPageCleanup, cleanup.page == page, cleanup.activation == activation else { return }
        registeredPageCleanup = nil
        cleanup.leave()
    }
    lazy var activePageUpdates: AnyPublisher<Void, Never> = {
        $pageID.removeDuplicates().map { [weak self] pageID in
            self?.launcherModules?.page(pageID)?.updates ?? Empty().eraseToAnyPublisher()
        }.switchToLatest().receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }()

    private var appIdentities: [String: ApplicationIdentity] = [:] {
        didSet { applicationEntries = nil; commandSearch.invalidate() }
    }
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    @Published private(set) var favoriteOrder = UserDefaults.standard.stringArray(forKey: "favoriteOrder") ?? []

    func favoriteOrderActions(for id: String) -> [LauncherAction] {
        let order = orderedFavoriteIDs
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

    private func moveFavorite(_ id: String, by delta: Int) {
        var order = orderedFavoriteIDs
        guard let source = order.firstIndex(of: id), order.indices.contains(source + delta) else { return }
        order.swapAt(source, source + delta)
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
        moduleSearchChanges = launcherModules?.searchUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.commandSearch.invalidate()
                self?.rootSearchUpdates.send()
            }
    }
    func startApplicationDiscovery() {
        guard workspaceObservers.isEmpty else { return }
        applicationSettingsCatalog.start()
        reloadCatalog()
        refreshRunningApps()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshRunningApps() })
        }
    }
    func stopApplicationDiscovery() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        discovery.stop()
    }
    func releaseApplicationCatalog() {
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
        runCommand(entry.commandID, origin: .search, usageKey: entry.id)
    }
    func runCommand(_ id: CommandID, origin: LauncherCommandOrigin, usageKey: String? = nil, arguments: [String] = []) {
        let queryKey = usageKey != nil && pageID == .root && origin != .shortcut ? SearchUsageHistory.queryKey(query) : nil
        let admitted = launcherModules?.invoke(id, origin: origin, arguments: arguments) { destination in
            switch destination {
            case .action: break
            case let .page(page): openPage(page, origin: origin)
            case let .settings(page): openSettings(page: page)
            }
        }
        if admitted == true, let usageKey { recordUsage(for: usageKey, queryKey: queryKey) }
    }
    func openPage(_ page: PageID, origin: LauncherCommandOrigin) {
        guard launcherModules?.page(page) != nil else { return }
        pageID = page
        if origin != .search { (NSApp.delegate as? Delegate)?.revealLauncherDestination() }
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
        guard let launcherModules else { return [] }
        let input = LauncherCommandSearch.Input(query: query, page: pageID,
                                                aliases: aliases, favorites: favorites, usage: usage,
                                                favoriteOrder: orderedFavoriteIDs, history: pageID == .root ? searchUsage : .init(),
                                                sensitivity: rootSearchSensitivity, namespace: namespace)
        return commandSearch.results(for: input, registry: launcherModules)
    }
}
final class LauncherPanel: NSPanel {
    var dragHandler: ((NSEvent) -> Void)?
    override func sendEvent(_ event: NSEvent) {
        // Keep a narrow drag area above the hosted search field.
        let point = event.locationInWindow
        if event.type == .leftMouseDown, dragHandler != nil,
           point.y >= frame.height - 10, point.y < frame.height,
           point.x >= 28, point.x <= frame.width - 28 {
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
                                      clipboardGeneration: Int? = nil, didDispatch: (() -> Void)? = nil) {
        guard !launcherPaste.isPending else { return }
        guard model.crossAppPaste.available else {
            showLauncherFeedback("已复制，跨应用粘贴未启用", style: .failure, actionTitle: "粘贴设置…") { [weak self] in
                self?.model.openSettings(page: "permissions")
            }
            return
        }
        guard let target = previousApplication, !target.isTerminated else { showPasteFailure("已复制，但上一个应用已退出或不可用。"); return }

        let keepsLauncherOpen = keepOpen && window.isVisible
        if !keepsLauncherOpen { hideLauncher() }
        guard let request = launcherPaste.begin(keepingLauncherOpen: keepsLauncherOpen) else { return }
        target.activate()

        if isFile {
            pasteFileIntoApplication(target, request: request, didDispatch: didDispatch)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.launcherPaste.isCurrent(request) else { return }
            guard self.pasteTargetIsFrontmost(target) else {
                self.finishPaste(request, target: target)
                self.showPasteFailure("已复制。目标应用未获得焦点，已停止自动粘贴。")
                return
            }
            if let clipboardGeneration {
                guard self.model.crossAppPaste.available,
                      NSPasteboard.general.changeCount == clipboardGeneration else {
                    self.finishPaste(request, target: target)
                    self.showPasteFailure("剪贴板内容或粘贴权限已变化，已停止自动粘贴。")
                    return
                }
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
                                          didDispatch: (() -> Void)?) {
        let generation = NSPasteboard.general.changeCount
        let isCurrent = { [weak self] in
            guard let self, self.launcherPaste.isCurrent(request) else { return false }
            return self.model.crossAppPaste.available && self.pasteTargetIsFrontmost(target)
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
            launcherPaste.finish(request)
        }
    }

    private func finishPaste(_ request: LauncherPaste.Request, target: NSRunningApplication) {
        guard launcherPaste.isCurrent(request) else { return }
        defer { launcherPaste.finish(request) }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
        let glass = NSGlassEffectView()
        glass.style = .regular; glass.cornerRadius = 28
        // Clip the actual AppKit backing surface, including hosted overlays and key bindings.
        // A SwiftUI-only clip leaves the enclosing rectangular surface in the window shadow.
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 28
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 0
        // Detect the macOS 27 setter at runtime so the macOS 26 SDK can build this.
        if #available(macOS 27.0, *),
           glass.responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
            glass.setValue(false, forKey: "effectIsInteractive")
        }
        glass.contentView = NSHostingView(rootView: Launcher(model: model))
        window.contentView = glass; window.isReleasedWhenClosed = false; window.center()
        window.delegate = self
        dragGuides = LauncherDragGuides(window: window)
        (window as? LauncherPanel)?.dragHandler = { [weak self] event in self?.dragGuides?.performDrag(with: event) }
        window.autorecalculatesKeyViewLoop = true
        appearanceSubscription = model.$appearance.sink { [weak self] value in
            let appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
            self?.window.appearance = appearance; self?.settingsWindow?.appearance = appearance
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
            model.$compactExpanded.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$compactFavorites.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$favorites.map(\.isEmpty).removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        .debounce(for: .zero, scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateLauncherGeometry() }
        updateLauncherGeometry()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            guard let self, self.window.attachedSheet == nil else { return }
            self.hideLauncher(reason: "outsideClick")
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.window, self.window.attachedSheet == nil,
               !FilePreview.shared.owns(event.window) {
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
            launcherPaste.cancel()
            rememberPreviousApplication()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .launcherShown, object: nil)
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding.isVisible { onboarding.bringToFront() }
        else if !window.isVisible { show() }
        else {
            launcherPaste.cancel()
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
        model.menuBar.shutdown()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
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
        if window.isVisible || reason == "outsideClick" { launcherPaste.cancel() }
        dragGuides?.cancel()
        guard window.isVisible else { return }
        resizeTimer?.invalidate()
        resizeTimer = nil
        resizeTarget = nil
        if model.placement == "remember" { window.saveFrame(usingName: "KeylaneLauncher") }
        launcherHiddenAt = ProcessInfo.processInfo.systemUptime
        window.orderOut(nil)
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
            return
        }
        let scale = model.interfaceScale
        guard animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              abs(start.height - target.height) > 1, abs(start.width - target.width) < tolerance else {
            model.presentedLauncherHeight = model.launcherHeight
            window.setFrame(target, display: true)
            return
        }
        resizeTarget = target
        let began = ProcessInfo.processInfo.systemUptime
        let duration = target.height > start.height ? 0.22 : 0.18
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - began) / duration)
            let eased = 1 - pow(1 - progress, 3)
            let height = start.height + (target.height - start.height) * eased
            let top = start.maxY + (target.maxY - start.maxY) * eased
            let x = start.minX + (target.minX - start.minX) * eased
            self.model.presentedLauncherHeight = progress == 1 ? self.model.launcherHeight : height / scale
            self.window.setFrame(NSRect(x: x, y: top - height, width: target.width, height: height), display: true)
            if progress == 1 {
                timer.invalidate()
                self.resizeTimer = nil
                self.resizeTarget = nil
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
        launcherPaste.cancel()
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
let delegate = Delegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
