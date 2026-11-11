import SwiftUI
import AppKit
import Carbon
import Combine
import ServiceManagement
import ApplicationServices
import KeylaneCore

final class Model: ObservableObject {
    let store: Store?
    @Published var error = ""
    @Published var settingsPage = "applications"
    @Published var appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system" { didSet { UserDefaults.standard.set(appearance, forKey: "appearance") } }
    @Published var placement = UserDefaults.standard.string(forKey: "placement") ?? "activeScreen" { didSet { UserDefaults.standard.set(placement, forKey: "placement") } }
    @Published var interfaceSize = UserDefaults.standard.string(forKey: "interfaceSize") ?? "medium" { didSet { UserDefaults.standard.set(interfaceSize, forKey: "interfaceSize") } }
    @Published var windowMode = UserDefaults.standard.string(forKey: "windowMode") ?? "expanded" { didSet { UserDefaults.standard.set(windowMode, forKey: "windowMode") } }
    @Published var compactFavorites = (UserDefaults.standard.object(forKey: "compactFavorites") as? Bool) ?? true { didSet { UserDefaults.standard.set(compactFavorites, forKey: "compactFavorites") } }
    @Published var compactExpanded = false
    var interfaceScale: CGFloat { interfaceSize == "small" ? 0.9 : interfaceSize == "large" ? 1.1 : 1 }
    var isCompact: Bool { windowMode == "compact" && pageID == .root && query.isEmpty && !compactExpanded }
    var launcherHeight: CGFloat { isCompact ? (compactFavorites && !favorites.isEmpty ? 109 : 61) : 470 }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    @Published var savedNotes: [KeylaneCore.Record] = []
    @Published var noteID = "scratchpad"
    @Published var query = ""
    @Published var pageID = PageID.root
    let fileAI = FileAIController()
    private var moduleSearchChanges: AnyCancellable?
    let rootSearchUpdates = PassthroughSubject<Void, Never>()
    let clipboard = ClipboardController(startTimer: false, presentationActive: false)
    let screenshots = ScreenshotLibrary()
    let systemShortcuts = SystemShortcutsController()
    let contacts = ContactsController()
    let dictionary = DictionaryController()
    let emoji = EmojiSearchController()
    let systemNavigation = NavigationController()
    let menuBar = MenuBarRegistry()
    lazy var calendar = CalendarController(registry: menuBar)
    @Published var notes: String = UserDefaults.standard.string(forKey: "notes") ?? "" { didSet { saveNote() } }
    @Published var link: String = UserDefaults.standard.string(forKey: "link") ?? "https://github.com/Acckion/Keylane" { didSet { UserDefaults.standard.set(link, forKey: "link") } }
    @Published var roots = UserDefaults.standard.stringArray(forKey: "applicationRoots") ?? ApplicationCatalog.defaultRoots
    @Published var excluded = Set(UserDefaults.standard.stringArray(forKey: "excludedApps") ?? [])
    @Published var applicationsEnabled = (UserDefaults.standard.object(forKey: "applicationsEnabled") as? Bool) ?? true { didSet { UserDefaults.standard.set(applicationsEnabled, forKey: "applicationsEnabled") } }
    @Published var applicationHotkeyAction = UserDefaults.standard.string(forKey: "applicationHotkeyAction") ?? "activate" { didSet { UserDefaults.standard.set(applicationHotkeyAction, forKey: "applicationHotkeyAction") } }
    @Published var aliases = UserDefaults.standard.dictionary(forKey: "aliases") as? [String:String] ?? [:]
    @Published var usage = UserDefaults.standard.dictionary(forKey: "usage") as? [String:Int] ?? [:]
    @Published var bindings: [String:Shortcut] = (UserDefaults.standard.data(forKey: "shortcuts").flatMap { try? JSONDecoder().decode([String:Shortcut].self, from: $0) }) ?? ["launcher": .launcher]
    @Published var navigation = UserDefaults.standard.string(forKey: "navigation") ?? "arrows" { didSet { UserDefaults.standard.set(navigation, forKey: "navigation") } }
    @Published var doubleTap = UserDefaults.standard.string(forKey: "doubleTap") ?? "off"
    @Published var hyperkey = UserDefaults.standard.bool(forKey: "hyperkey")
    @Published var modifierStatus = ""
    @Published var scanStatus = "正在扫描…"
    let fileSearch = FileSearchController()
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
    private(set) lazy var applicationSettingsCatalog = ApplicationSettingsCatalog(model: self)
    @Published var runningPaths: Set<String> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    @Published var apps: [URL] = []
    private let commandSearch = LauncherCommandSearch()
    private(set) lazy var launcherModules: LauncherModuleRegistry? = {
        do { return try LauncherModuleRegistry(modules: BuiltinLauncherModules.make(model: self)) }
        catch {
            NSLog("Keylane: invalid built-in module catalog: %@", String(describing: error))
            return nil
        }
    }()
    var activeLauncherPage: LauncherPage? { launcherModules?.page(pageID) }
    lazy var activePageUpdates: AnyPublisher<Void, Never> = {
        $pageID.removeDuplicates().map { [weak self] pageID in
            self?.launcherModules?.page(pageID)?.updates ?? Empty().eraseToAnyPublisher()
        }.switchToLatest().receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }()

    private var appIdentities: [String: ApplicationIdentity] = [:] {
        didSet { commandSearch.invalidate() }
    }
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
    func favoriteAction(for entry: Entry) -> LauncherAction {
        let favorite = favorites.contains(entry.id)
        return .init(id: "favorite", title: favorite ? "取消收藏" : "加入收藏", icon: favorite ? "star.fill" : "star") { [weak self] in
            self?.toggleFavorite(entry.id)
        }
    }
    func toggleFavorite(_ id: String) { if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }; UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    func openSettings(page: String? = nil) { if let page { settingsPage = page }; (NSApp.delegate as? Delegate)?.showSettings() }
    func saveNote() { do { try store?.save(KeylaneCore.Record(id: noteID, kind: "note", title: String(notes.prefix(60)), body: notes)); savedNotes = try store?.records(kind: "note") ?? [] } catch { self.error = error.localizedDescription } }
    func newNote() { noteID = UUID().uuidString; notes = "" }
    func exportData() { let panel = NSSavePanel(); panel.nameFieldStringValue = "Keylane-backup.json"; if panel.runModal() == .OK, let url = panel.url { do { try store?.export(to: url) } catch { self.error = error.localizedDescription } } }
    init() {
        do { store = try Store(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/data.sqlite")) } catch { store = nil; self.error = error.localizedDescription }
        do { savedNotes = try store?.records(kind: "note") ?? []; if let note = savedNotes.first { noteID = note.id; notes = note.body } } catch { self.error = error.localizedDescription }

        discovery.updated = { [weak self] records, elapsed in
            guard let self else { return }
            self.appIdentities = Dictionary(uniqueKeysWithValues: records.map { ($0.id,$0.identity) })
            self.apps = records.map(\.url); self.lastScanSeconds = elapsed
            self.scanStatus = "已索引 \(records.count) 个应用"
        }
        discovery.failed = { [weak self] text in self?.error = text }
        fileSearch.updated = { [weak self] files, status in
            guard let self else { return }; if self.fileResults != files { self.fileResults = files }; if self.fileSearchStatus != status { self.fileSearchStatus = status }
        }
        refreshLogin()
        moduleSearchChanges = launcherModules?.searchUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.commandSearch.invalidate()
                self?.rootSearchUpdates.send()
            }
    }
    func startApplicationDiscovery() {
        guard workspaceObservers.isEmpty else { return }
        _ = applicationSettingsCatalog
        reloadCatalog()
        refreshRunningApps()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshRunningApps(); self?.discovery.refresh() })
        }
    }
    func stopApplicationDiscovery() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        discovery.stop()
    }
    deinit { stopApplicationDiscovery() }
    func refreshRunningApps() { runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }) }
    func reloadCatalog() {
        UserDefaults.standard.set(roots, forKey: "applicationRoots"); UserDefaults.standard.set(Array(excluded), forKey: "excludedApps")
        scanStatus = "正在扫描…"; discovery.configure(roots: roots, excluded: excluded)
    }
    func addRoot() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url, !roots.contains(url.path) { roots.append(url.path); reloadCatalog() } }
    func setAlias(_ id: String, value: String) { aliases[id] = value.trimmingCharacters(in: .whitespacesAndNewlines); UserDefaults.standard.set(aliases, forKey: "aliases") }
    func perform(_ entry: Entry) {
        runCommand(entry.commandID, origin: .search, usageKey: entry.id)
    }
    func runCommand(_ id: CommandID, origin: LauncherCommandOrigin, usageKey: String? = nil) {
        guard let action = launcherModules?.resolve(id, origin: origin, navigate: { [weak self] destination in
            guard let self else { return }
            switch destination {
            case .action: break
            case let .page(page):
                self.openPage(page, origin: origin)
            case let .settings(page): self.openSettings(page: page)
            }
        }) else { return }
        if let usageKey {
            usage[usageKey, default: 0] += 1
            UserDefaults.standard.set(usage, forKey: "usage")
        }
        action()
    }
    func openPage(_ page: PageID, origin: LauncherCommandOrigin) {
        guard launcherModules?.page(page) != nil else { return }
        pageID = page
        if origin != .search { (NSApp.delegate as? Delegate)?.revealLauncher() }
    }
    func launch(_ url: URL) {
        if NSWorkspace.shared.open(url) { (NSApp.delegate as? Delegate)?.hideLauncher() }
        else { error = "无法打开应用，路径可能已经失效。"; discovery.refresh() }
    }
    func launch(_ url: URL, arguments: [String]) {
        let configuration = NSWorkspace.OpenConfiguration(); configuration.arguments = arguments; configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async { if let error { self?.error = error.localizedDescription } else { self?.usage[url.path, default: 0] += 1; UserDefaults.standard.set(self?.usage, forKey: "usage"); (NSApp.delegate as? Delegate)?.hideLauncher() } }
        }
    }
    func setShortcut(_ action: String, value: Shortcut?) {
        var proposed = bindings; proposed[action] = value
        do {
            try (NSApp.delegate as? Delegate)?.shortcuts.apply(proposed)
            bindings = proposed; UserDefaults.standard.set(try JSONEncoder().encode(proposed), forKey: "shortcuts"); error = ""
        } catch { self.error = error.localizedDescription }
    }
    func configureModifiers() {
        guard let delegate = NSApp.delegate as? Delegate else { return }
        if let issue = delegate.modifiers.configure(doubleTap: doubleTap, hyper: hyperkey) {
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
    func discoveredIdentity(for url: URL) -> ApplicationIdentity? { appIdentities[url.path] }
    func appName(_ url: URL) -> String { appIdentities[url.path]?.displayName ?? url.deletingPathExtension().lastPathComponent }
    var searchesFilesHere: Bool { fileSearch.options.enabled && (activeLauncherPage?.contentPlacement == .fileResults || (pageID == .root && fileSearch.options.searchFromLauncher)) }
    func searchFiles() { fileSearch.search(query) }
    func chooseFileSearchFolder(returnToLauncher: Bool = false) {
        fileSearch.addScope()
        if returnToLauncher { (NSApp.delegate as? Delegate)?.revealLauncher() }
    }
    func openFile(_ url: URL) {
        guard !fileSearch.isSearching else { return }
        guard FileManager.default.fileExists(atPath: url.path), NSWorkspace.shared.open(url) else { error = "文件无法打开，可能已移走、删除或没有访问权限。"; searchFiles(); return }
        (NSApp.delegate as? Delegate)?.hideLauncher()
    }
    func launchFromHotkey(_ url: URL) {
        guard applicationsEnabled, !excluded.contains(url.path) else { return }
        if applicationHotkeyAction == "toggle",
           let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }), running.isActive {
            running.hide()
        } else { launch(url) }
    }
    var commands: [Entry] {
        guard let launcherModules else { return [] }
        let input = LauncherCommandSearch.Input(query: query, page: pageID,
                                                aliases: aliases, favorites: favorites, usage: usage)
        return commandSearch.results(for: input, registry: launcherModules)
    }
}
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var previousApplication: NSRunningApplication?
    let navigationToast = ToastPresenter()

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
    func pasteClipboard(plainText: Bool = false) {
        guard model.clipboard.copySelected(plainText:plainText) else { return }
        pasteIntoPreviousApplication(feedback: model.clipboard.feedback)
    }
    func pasteIntoPreviousApplication(feedback: @escaping (String) -> Void) {
        guard AXIsProcessTrusted() else { feedback("已复制。粘贴到其他应用需要在系统设置中授予辅助功能权限。"); return }
        guard let target = previousApplication, !target.isTerminated else { feedback("已复制，但上一个应用已退出或不可用。"); return }
        hideLauncher(); target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier, !target.isTerminated else { feedback("已复制。目标应用未获得焦点，已停止自动粘贴。"); return }
            let source = CGEventSource(stateID: .combinedSessionState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { feedback("已复制，无法发送粘贴按键。"); return }
            down.flags = .maskCommand; up.flags = .maskCommand; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }
    let model = Model()
    var settingsWindow: NSWindow?
    var window: NSWindow!
    let shortcuts = ShortcutManager()
    let modifiers = ModifierShortcuts()
    var outsideMonitor: Any?
    var localMonitor: Any?
    let windowDiagnostics = WindowDiagnostics()
    var hotkeyStatus: Int32 = 0
    var appearanceSubscription: AnyCancellable?
    var geometrySubscription: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installApplicationMenu(settingsTarget: self, settingsAction: #selector(openLauncherSettings))
        window = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 470), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        window.autorecalculatesKeyViewLoop = true
        appearanceSubscription = model.$appearance.sink { [weak self] value in
            let appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
            self?.window.appearance = appearance; self?.settingsWindow?.appearance = appearance
        }
        // Observe geometry inputs only. Other model changes do not resize the window.
        geometrySubscription = Publishers.MergeMany([
            model.$interfaceSize.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$windowMode.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$pageID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$query.map(\.isEmpty).removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$compactExpanded.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$compactFavorites.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$favorites.map(\.isEmpty).removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        .debounce(for: .zero, scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.updateLauncherGeometry() }
        updateLauncherGeometry()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.hideLauncher(reason: "outsideClick")
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.window { self.hideLauncher(reason: "otherWindow") }
            return event
        }
        model.menuBar.register(id: "keylane.launcher", owner: "launcher", title: "Keylane", defaultVisible: true,
                               presentation: .init(symbol: "command", toolTip: "打开 Keylane")) { [weak self] in
            [.init(title: "打开 Keylane", symbol: "command", action: { self?.revealLauncher() }),
             .init(title: "我的日程", symbol: "calendar", action: { self?.model.runCommand(.init(rawValue: "calendar"), origin: .menu) }),
             .init(title: "设置…", symbol: "gearshape", action: { self?.openLauncherSettings() }),
             .separator, .init(title: "退出 Keylane", action: { NSApplication.shared.terminate(nil) })]
        }
        shortcuts.fired = { [weak self] action in
            guard let self else { return }
            if action == "launcher" { self.show() }
            else {
                let appKey = action.hasPrefix("app:") ? String(action.dropFirst("app:".count)) : nil
                self.model.runCommand(.init(rawValue: action), origin: .shortcut, usageKey: appKey)
            }
        }
        do { try shortcuts.apply(model.bindings); hotkeyStatus = 0 } catch { hotkeyStatus = -1; model.error = error.localizedDescription }
        modifiers.activate = { [weak self] in self?.show() }
        model.configureModifiers()
        model.launcherModules?.startServices()
        show()
    }
    @objc func revealLauncher() {
        rememberPreviousApplication()
        if !window.isVisible { presentLauncher() }
        else { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); NotificationCenter.default.post(name: .launcherShown, object: nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !window.isVisible { show() }
        else { window.makeKeyAndOrderFront(nil); windowDiagnostics.record("reopen", launcher: window, settings: settingsWindow, hotkeyStatus: hotkeyStatus) }
        return false
    }
    func windowDidResignKey(_ notification: Notification) {
        guard let resigned = notification.object as? NSWindow, resigned === window else { return }
        hideLauncher(reason: "resignKey")
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.launcherModules?.stopServices()
        model.menuBar.shutdown()
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        shortcuts.stop(); modifiers.stop()
    }
    @objc private func openLauncherSettings() {
        model.runCommand(.init(rawValue: "settings"), origin: .menu)
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
            trailingActions.view.frame = NSRect(x: 0, y: 0, width: 106, height: 44)
            settings.addTitlebarAccessoryViewController(trailingActions)
            settings.center()
            settings.setFrameAutosaveName("KeylaneSettings")
            // Restore the saved height and position, but always use the system settings width.
            settings.minSize = NSSize(width: 740, height: 600)
            settings.maxSize = NSSize(width: 740, height: CGFloat.greatestFiniteMagnitude)
            var settingsFrame = settings.frame
            settingsFrame.size.width = 740
            settings.setFrame(settingsFrame, display: false)
            settingsWindow = settings
        }
        hideLauncher(); settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func hideLauncher(reason: String = "command") {
        guard window.isVisible else { return }
        if model.placement == "remember" { window.saveFrame(usingName: "KeylaneLauncher") }
        window.orderOut(nil)
        NotificationCenter.default.post(name: .launcherHidden, object: nil)
        windowDiagnostics.record("hidden:" + reason, launcher: window, settings: settingsWindow, hotkeyStatus: hotkeyStatus)
    }
    func updateLauncherGeometry() {
        guard window != nil else { return }
        let backingScale = max(1, window.backingScaleFactor)
        // Align the requested size before comparing it with AppKit's frame.
        // A value like 760 * 1.1 can otherwise round up by an entire point.
        let size = NSSize(
            width: (760 * model.interfaceScale * backingScale).rounded() / backingScale,
            height: (model.launcherHeight * model.interfaceScale * backingScale).rounded() / backingScale
        )
        let current = window.frame.size
        let tolerance = 1 / backingScale
        guard abs(current.width - size.width) >= tolerance || abs(current.height - size.height) >= tolerance else { return }
        var frame = window.frame
        frame.origin.x += (frame.width - size.width) / 2
        frame.origin.y += frame.height - size.height
        frame.size = size
        if let area = window.screen?.visibleFrame {
            frame.origin.x = max(area.minX, min(frame.origin.x, area.maxX - size.width))
            frame.origin.y = max(area.minY, min(frame.origin.y, area.maxY - size.height))
        }
        window.setFrame(frame, display: true)
    }
    @objc func show() {
        if window.isVisible && window.isKeyWindow { hideLauncher(); return }
        if model.windowMode == "compact" {
            model.pageID = .root; model.query = ""; model.compactExpanded = false
        }
        presentLauncher()
    }
    /// Present the current destination without applying the launcher's compact-mode reset.
    private func presentLauncher() {
        updateLauncherGeometry()
        rememberPreviousApplication()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            if model.placement == "remember" { _ = window.setFrameUsingName("KeylaneLauncher") }; updateLauncherGeometry()
            var frame = window.frame
            if model.placement != "remember" || !frame.intersects(area) { frame.origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY + 235 * model.interfaceScale - frame.height) }
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
