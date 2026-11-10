import SwiftUI
import AppKit
import Carbon
import Combine
import ServiceManagement
import ApplicationServices
import KeylaneCore

struct Entry: Identifiable { let id: String; let name: String; let detail: String; let symbol: String; var aliases: [String] = []; let action: () -> Void }
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
    var isCompact: Bool { windowMode == "compact" && tab == "Commands" && query.isEmpty && !compactExpanded }
    var launcherHeight: CGFloat { isCompact ? (compactFavorites && !favorites.isEmpty ? 109 : 61) : 470 }
    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    @Published var savedNotes: [KeylaneCore.Record] = []
    @Published var noteID = "scratchpad"
    @Published var query = ""
    @Published var tab = "Commands"
    let fileAI = FileAIController()
    private var fileAIChanges: AnyCancellable?
    let clipboard = ClipboardController()
    private var clipboardChanges: AnyCancellable?
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
    private var fileSearchChanges: AnyCancellable?
    @Published var fileSearchFolder: URL?
    @Published var fileResults: [SpotlightFile] = []
    @Published var fileSearchStatus = "输入文件名，搜索Spotlight已索引的文件。"
    @Published var fileSearchScope = UserDefaults.standard.string(forKey: "fileSearchScope") ?? "local" { didSet { UserDefaults.standard.set(fileSearchScope, forKey: "fileSearchScope"); if tab == "Files" { searchFiles() } } }
    @Published var lastScanSeconds = 0.0
    @Published var loginStatus = ""
    @Published var loginEnabled = false
    let discovery = ApplicationDiscovery()
    @Published var runningPaths: Set<String> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    @Published var apps: [URL] = []
    private var appIdentities: [String: ApplicationIdentity] = [:]
    @Published var favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
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
        reloadCatalog()
        refreshLogin()
        refreshRunningApps()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshRunningApps(); self?.discovery.refresh() })
        }
        fileAIChanges = fileAI.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        fileSearchChanges = Publishers.Merge(fileSearch.$options.removeDuplicates().map { _ in () }, fileSearch.$isSearching.removeDuplicates().map { _ in () }).sink { [weak self] _ in self?.objectWillChange.send() }
        clipboardChanges = clipboard.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    deinit { workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) } }
    func refreshRunningApps() { runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }) }
    func reloadCatalog() {
        UserDefaults.standard.set(roots, forKey: "applicationRoots"); UserDefaults.standard.set(Array(excluded), forKey: "excludedApps")
        scanStatus = "正在扫描…"; discovery.configure(roots: roots, excluded: excluded)
    }
    func addRoot() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url, !roots.contains(url.path) { roots.append(url.path); reloadCatalog() } }
    func setAlias(_ id: String, value: String) { aliases[id] = value.trimmingCharacters(in: .whitespacesAndNewlines); UserDefaults.standard.set(aliases, forKey: "aliases") }
    func perform(_ entry: Entry) { usage[entry.id, default: 0] += 1; UserDefaults.standard.set(usage, forKey: "usage"); entry.action() }
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
    func appName(_ url: URL) -> String { appIdentities[url.path]?.displayName ?? url.deletingPathExtension().lastPathComponent }
    var searchesFilesHere: Bool { fileSearch.options.enabled && (tab == "Files" || (tab == "Commands" && fileSearch.options.searchFromLauncher)) }
    func searchFiles() { fileSearch.search(query) }
    func chooseFileSearchFolder(returnToLauncher: Bool = false) {
        fileSearch.addScope()
        if returnToLauncher { (NSApp.delegate as? Delegate)?.revealLauncher() }
    }
    func clearFileSearchFolder() { fileSearchFolder = nil; UserDefaults.standard.removeObject(forKey: "fileSearchBookmark") }
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
        var rows = [
            Entry(id: "clipboard", name: "剪贴板历史", detail: "本地文字、图片和文件历史", symbol: "clipboard", aliases: ["Clipboard History", "剪切板", "剪贴板", "复制历史"], action: { self.tab = "Clipboard" }),
            Entry(id: "notes", name: "便笺", detail: "本地便笺", symbol: "note.text", aliases: ["Notes", "便签", "笔记"], action: { self.tab = "Notes" }),
            Entry(id: "quicklink", name: "快捷链接", detail: link, symbol: "link", aliases: ["Quick Link", "快速链接", "网址"], action: { if let url = URL(string: self.link), ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) } }),
            Entry(id: "settings", name: "Keylane 设置", detail: "偏好设置与隐私", symbol: "gearshape", aliases: ["Settings", "Preferences", "设置", "偏好设置"], action: { self.openSettings() })]
        rows += [
            Entry(id: "file-search", name: "搜索文件", detail: "Spotlight", symbol: "doc.text.magnifyingglass", aliases: ["File Search", "Spotlight"], action: { self.tab = "Files" }),
            Entry(id: "screenshot", name: "Screenshot / 截图", detail: "Select region · copy image", symbol: "camera.viewfinder", action: { NSApp.keyWindow?.orderOut(nil); DispatchQueue.main.asyncAfter(deadline: .now()+0.25) { SystemTools.shared.screenshot() } }),
            Entry(id: "color", name: "Pick Color / 取色", detail: "Copy hex color", symbol: "eyedropper", action: { SystemTools.shared.colorPicker() }),
            Entry(id: "speak", name: "Read Clipboard / 朗读", detail: "System text to speech", symbol: "speaker.wave.2", action: { SystemTools.shared.readClipboard() }),
            Entry(id: "stop-speaking", name: "Stop Reading / 停止朗读", detail: "Stop speech playback", symbol: "stop.circle", action: { SystemTools.shared.stopReading() }),
            Entry(id: "finder", name: "Open Home / 个人文件夹", detail: "Finder", symbol: "folder", action: { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser) })
        ]
        if fileAI.commandsEnabled["ask-files"] != false { rows.append(Entry(id:"ask-files",name:"询问文件搜索",detail:"AI",symbol:"sparkles",aliases:["Ask File Search"],action:{ self.fileAI.present(self.fileResults.map(\.url)) })) }
        if fileAI.commandsEnabled["ask-finder"] != false { rows.append(Entry(id:"ask-finder",name:"询问 Finder",detail:"AI",symbol:"sparkles",aliases:["Ask Finder"],action:{ self.fileAI.presentFinder() })) }
        rows += (applicationsEnabled ? apps : []).map { url in
            let identity = appIdentities[url.path] ?? ApplicationIdentity(url: url)
            return Entry(id: url.path, name: identity.displayName, detail: "Application", symbol: "app", aliases: identity.aliases, action: { self.launch(url) })
        }
        if tab == "Commands", fileSearch.options.enabled, fileSearch.options.searchFromLauncher, !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            rows += fileResults.filter { $0.url.pathExtension.lowercased() != "app" }.prefix(10).map { file in
                Entry(id:file.id,name:file.name,detail:"File",symbol:"doc",action:{ if !self.fileSearch.isSearching { self.openFile(file.url) } })
            }
        }
        if let value = Calculator.evaluate(query), query.contains(where: { "+-*/".contains($0) }) {
            let result = String(format: "%.12g", value)
            rows.insert(Entry(id: "calculator", name: result, detail: "Calculator · copy result", symbol: "equal", action: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string) }), at: 0)
        }
        if !fileSearch.options.enabled { rows.removeAll { $0.id == "file-search" } }
        return rows.compactMap { row -> (Entry, Int)? in
            if row.id == "calculator" { return (row, 2000) }
            if row.detail == "File" { return (row,FileSearchRules.rank(row.name,query:query)) }
            let alias = aliases[row.id] ?? ""
            let aliasScore = !alias.isEmpty && alias.localizedCaseInsensitiveCompare(query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame ? 1500 : (SearchRanker.score(alias, query: query) ?? -1)
            guard let normal = ([row.name] + row.aliases).compactMap({ SearchRanker.score($0, query: query) }).max() ?? (aliasScore >= 0 ? aliasScore : nil) else { return nil }; return (row, max(normal,aliasScore))
        }.sorted { lhs, rhs in
            SearchResultRank(score: lhs.1, favorite: favorites.contains(lhs.0.id), uses: usage[lhs.0.id, default: 0], title: lhs.0.name, id: lhs.0.id).precedes(SearchResultRank(score: rhs.1, favorite: favorites.contains(rhs.0.id), uses: usage[rhs.0.id, default: 0], title: rhs.0.name, id: rhs.0.id))
        }.map { $0.0 }
    }
}
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var previousApplication: NSRunningApplication?
    private func rememberPreviousApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApplication = app }
    }
    func pasteClipboard(plainText: Bool = false) {
        guard model.clipboard.copySelected(plainText:plainText) else { return }
        guard AXIsProcessTrusted() else { model.clipboard.feedback("已复制。粘贴到其他应用需要在系统设置中授予辅助功能权限。"); return }
        guard let target = previousApplication, !target.isTerminated else { model.clipboard.feedback("已复制，但上一个应用已退出或不可用。"); return }
        hideLauncher(); target.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier, !target.isTerminated else { self.model.clipboard.feedback("已复制。目标应用未获得焦点，已停止自动粘贴。"); return }
            let source = CGEventSource(stateID: .combinedSessionState)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { self.model.clipboard.feedback("已复制，无法发送粘贴按键。"); return }
            down.flags = .maskCommand; up.flags = .maskCommand; down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }
    let model = Model()
    var settingsWindow: NSWindow?
    var window: NSWindow!
    var status: NSStatusItem!
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
        installApplicationMenu(settingsTarget: self, settingsAction: #selector(showSettings))
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
        // Glass remains noninteractive by default; keep compatibility with the macOS 26 SDK.
        glass.contentView = NSHostingView(rootView: Launcher(model: model))
        window.contentView = glass; window.isReleasedWhenClosed = false; window.center()
        window.delegate = self
        window.autorecalculatesKeyViewLoop = true
        appearanceSubscription = model.$appearance.sink { [weak self] value in
            let appearance = value == "dark" ? NSAppearance(named: .darkAqua) : value == "light" ? NSAppearance(named: .aqua) : nil
            self?.window.appearance = appearance; self?.settingsWindow?.appearance = appearance
        }
        geometrySubscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateLauncherGeometry() }
        }
        updateLauncherGeometry()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.hideLauncher(reason: "outsideClick")
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.window { self.hideLauncher(reason: "otherWindow") }
            return event
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength); status.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Open launcher")
        let menu = NSMenu(); menu.addItem(withTitle: "Open Launcher", action: #selector(show), keyEquivalent: ""); menu.addItem(.separator()); menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.items.first?.target = self; status.menu = menu
        shortcuts.fired = { [weak self] action in
            guard let self else { return }
            if action == "launcher" { self.show() }
            else if action == "settings" { self.showSettings() }
            else if action == "clipboard" { self.model.tab = "Clipboard"; self.revealLauncher() }
            else if action == "file-search", self.model.fileSearch.options.enabled { self.model.tab = "Files"; self.revealLauncher() }
            else if action == "ask-files", self.model.fileAI.commandsEnabled[action] != false { self.hideLauncher(); self.model.fileAI.present(self.model.fileResults.map(\.url)) }
            else if action == "ask-finder", self.model.fileAI.commandsEnabled[action] != false { self.hideLauncher(); self.model.fileAI.presentFinder() }
            else if action.hasPrefix("app:") { let path = String(action.dropFirst(4)); self.model.usage[path, default: 0] += 1; UserDefaults.standard.set(self.model.usage, forKey: "usage"); self.model.launchFromHotkey(URL(fileURLWithPath: path)) }
        }
        do { try shortcuts.apply(model.bindings); hotkeyStatus = 0 } catch { hotkeyStatus = -1; model.error = error.localizedDescription }
        modifiers.activate = { [weak self] in self?.show() }
        model.configureModifiers()
        show()
    }
    @objc func revealLauncher() {
        rememberPreviousApplication()
        if !window.isVisible { show() }
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
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        shortcuts.stop(); modifiers.stop(); model.discovery.stop()
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let view = NSHostingView(rootView: SettingsView(model: model))
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 730), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            settings.title = "Keylane 设置"; settings.titlebarAppearsTransparent = false; settings.titleVisibility = .visible; settings.isReleasedWhenClosed = false
            settings.appearance = window.appearance; settings.autorecalculatesKeyViewLoop = true
            settings.contentView = view
            let trailingActions = NSTitlebarAccessoryViewController()
            trailingActions.layoutAttribute = .right
            trailingActions.view = NSHostingView(rootView: SettingsWindowActions(model: model))
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
        let size = NSSize(width: 760 * model.interfaceScale, height: model.launcherHeight * model.interfaceScale)
        guard window.frame.size != size else { return }
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
            model.tab = "Commands"; model.query = ""; model.compactExpanded = false
        }
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
