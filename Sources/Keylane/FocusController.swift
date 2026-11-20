import AppKit
import Combine
import KeylaneCore
import UniformTypeIdentifiers

final class FocusController: ObservableObject {
    @Published private(set) var archive: FocusArchive
    @Published var draft = FocusConfiguration()
    @Published var durationText = ""
    @Published var categoryDraft = FocusCategory(name: "")
    @Published var editingCategory: UUID?
    @Published var editingSession = false
    @Published var categoryQuery = ""
    @Published var selectedCategory: UUID?
    @Published var message = ""
    @Published private(set) var now = Date()
    @Published private(set) var starting = false
    @Published private(set) var blockedTarget: FocusApplication?
    let permission: PermissionFeature
    private let store: FocusStore
    let browser: FocusBrowser
    private let registry: MenuBarRegistry
    private var running = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var restorePending: [pid_t: URL] = [:]
    private var requestedApplications: [pid_t: URL] = [:]
    private var quitRequested: [pid_t: Date] = [:]
    private var deferredQuit = Set<String>()
    private var permissionObservation: AnyCancellable?
    @Published private(set) var browserMessage = ""
    private var beforeSleepRunning = false
    private var revision = 0
    private var loaded = false
    private(set) lazy var windows = FocusWindows(controller: self)
    var edit: (() -> Void)?
    var openSettings: (() -> Void)?
    static let owner = "keylane.focus"

    init(registry: MenuBarRegistry, defaults: UserDefaults = .standard, directory: URL? = nil,
         authorization: PermissionFeature.Authorization = .accessibility) {
        self.registry = registry
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/Focus", isDirectory: true)
        store = FocusStore(url: root.appendingPathComponent("state.json"))
        browser = FocusBrowser(directory: root)
        permission = PermissionFeature("focus.enabled", authorization: authorization, defaults: defaults, observeImmediately: false)
        do { archive = try store.load() }
        catch { archive = FocusArchive(); message = "专注数据读取失败，请检查数据文件后重试。"; loaded = false; return }
        loaded = true
        // Process restarts require explicit resume; downtime never counts as work.
        if archive.session != nil {
            let checkpoint = archive.checkpoint ?? Date()
            archive.session?.pause(at: checkpoint)
        }
    }

    var session: FocusSession? { archive.session }
    var preferences: FocusPreferences {
        get { archive.preferences }
        set {
            let previous = archive.preferences; archive.preferences = newValue
            if !persist() { archive.preferences = previous }
            else if newValue.inMenuBar && !previous.inMenuBar { registry.setEnabled(Self.owner, true) }
            refreshPresentation()
        }
    }
    var categories: [FocusCategory] { archive.categories + FocusCategory.builtIn }
    var visibleCategories: [FocusCategory] {
        categories.filter {
            categoryQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(categoryQuery)
                || $0.symbol.localizedCaseInsensitiveContains(categoryQuery)
                || $0.websites.contains { $0.localizedCaseInsensitiveContains(categoryQuery) }
                || $0.applications.contains { $0.name.localizedCaseInsensitiveContains(categoryQuery) || $0.id.localizedCaseInsensitiveContains(categoryQuery) }
                || FocusCategory.englishName(for: $0.id)?.localizedCaseInsensitiveContains(categoryQuery) == true
        }
    }
    var chosenCategory: FocusCategory? { categories.first { $0.id == selectedCategory } }
    var isCustomCategory: Bool { archive.categories.contains { $0.id == selectedCategory } }
    var status: String {
        guard let session else { return "没有进行中的专注" }
        let seconds = session.remaining(at: now) ?? session.effectiveElapsed(at: now)
        let minutes = Int(max(0, seconds)) / 60, remainder = Int(max(0, seconds)) % 60
        return (session.paused ? "已暂停 · " : "") + String(format: "%02d:%02d", minutes, remainder)
    }
    var canSaveCategory: Bool { !categoryDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canStart: Bool { !draft.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !starting && loaded }

    func startService() {
        guard !running else { return }
        running = true; permission.startObserving()
        registry.register(id: Self.owner, owner: Self.owner, title: "专注", defaultVisible: true,
                          presentation: .init(symbol: "target", toolTip: "Keylane Focus", isVisible: session != nil && preferences.inMenuBar),
                          commands: { [weak self] in self?.menuCommands() ?? [] })
        browser.restore()
        permissionObservation = permission.updates.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self else { return }
            if !self.permission.available { self.revision += 1; self.starting = false; self.pause() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                             NSWorkspace.didTerminateApplicationNotification, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                switch note.name {
                case NSWorkspace.willSleepNotification:
                    self.beforeSleepRunning = self.session?.paused == false
                    if self.beforeSleepRunning { self.pause() }
                case NSWorkspace.didWakeNotification:
                    if self.beforeSleepRunning { self.resume() }
                    self.beforeSleepRunning = false
                case NSWorkspace.didTerminateApplicationNotification:
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       let url = self.restorePending.removeValue(forKey: app.processIdentifier) {
                        self.restoreApplication(url)
                    }
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       let url = self.requestedApplications.removeValue(forKey: app.processIdentifier),
                       !self.archive.terminatedApplications.contains(url) { self.archive.terminatedApplications.append(url); self.persist() }
                default:
                    let launchedBrowser = note.name == NSWorkspace.didLaunchApplicationNotification &&
                        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier.map { FocusBrowser.supported[$0] != nil } == true
                    if self.session?.paused != false || launchedBrowser { self.browser.restore() }
                    self.enforce()
                }
            })
        }
        startTimerIfNeeded()
        refreshPresentation()
    }

    private func startTimerIfNeeded() {
        guard running, session != nil, timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func cancelPreparation() { if starting { revision += 1; starting = false } }

    func stopService() {
        revision += 1; running = false; starting = false
        pause()
        timer?.invalidate(); timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); observers = []
        browser.restore()
        registry.unregister(owner: Self.owner)
        permissionObservation?.cancel(); permissionObservation = nil
        permission.stopObserving()
        windows.close()
    }

    func prepareSession(editing: Bool = false) {
        cancelPreparation()
        editingSession = editing && session != nil
        draft = editingSession ? session!.configuration : archive.lastConfiguration
        durationText = draft.duration.map { "\(Int($0 / 60)) min" } ?? ""
        message = loaded ? "" : "专注数据读取失败，请检查数据文件后重试。"
    }
    func saveSession(completion: @escaping () -> Void) {
        do {
            draft.goal = draft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.duration = try FocusDuration.parse(durationText)
            let validated = try FocusCategory(name: draft.goal, applications: draft.applications, websites: draft.websites).validated()
            draft.applications = validated.applications; draft.websites = validated.websites
            guard canStart else { return }
        } catch { message = error.localizedDescription; return }
        guard running, permission.available else { message = permission.guidance; return }
        starting = true
        let candidate = draft, ticket = revision, editing = editingSession
        let needsWebsites = requiresWebsiteBlocking(candidate)
        if needsWebsites, let unavailable = unsupportedBrowser(candidate) {
            starting = false; message = "\(unavailable) 暂不支持网站屏蔽。请使用 Safari 或 Chromium 系浏览器，或将该浏览器加入屏蔽列表。"; return
        }
        let browsers = needsWebsites ? NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
            .filter { FocusBrowser.supported[$0] != nil && !candidate.blocks(application: $0) } : []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let denied = browsers.filter { FocusBrowser.permission($0, prompt: true) != noErr }
            DispatchQueue.main.async {
                guard let self, self.revision == ticket, self.running else { return }
                self.starting = false
                guard denied.isEmpty, self.permission.available else {
                    self.message = "需要允许 Keylane 控制使用中的浏览器，才能开始网站屏蔽。"
                    return
                }
                let previousArchive = self.archive
                if editing, var active = self.session {
                    active.configuration = candidate; self.archive.session = active
                } else {
                    guard self.session == nil else { self.message = "已有专注会话，请先完成或编辑。"; return }
                    self.archive.session = FocusSession(configuration: candidate, now: Date())
                    self.archive.terminatedApplications = []; self.quitRequested = [:]; self.deferredQuit = []; self.restorePending = [:]; self.requestedApplications = [:]
                }
                self.archive.lastConfiguration = candidate
                guard self.persist() else { self.archive = previousArchive; return }
                self.message = ""; self.browserMessage = ""
                if editing { self.browser.restore() }
                self.startTimerIfNeeded(); completion(); self.tick()
            }
        }
    }
    func toggle() {
        if session != nil { finish(completed: true) }
        else {
            prepareSession()
            if canStart { saveSession { (NSApp.delegate as? Delegate)?.hideLauncher() } }
            else { edit?() }
        }
    }
    func pause(minutes: Int? = nil) {
        guard archive.session != nil else { return }
        archive.session?.pause(at: Date(), breakDuration: minutes.map { Double($0 * 60) })
        blockedTarget = nil; windows.dismissNotice(); browser.restore(); persist(); refreshPresentation()
    }
    func resume() {
        guard running, permission.available, session != nil else { return }
        archive.session?.resume(at: Date()); persist(); startTimerIfNeeded(); tick()
    }
    func restart() {
        guard let configuration = session?.configuration else { return }
        archive.session = FocusSession(configuration: configuration, now: Date()); persist(); tick()
    }
    func finish(completed: Bool) {
        guard let previous = session else { return }
        revision += 1; starting = false
        timer?.invalidate(); timer = nil
        let previousArchive = archive
        archive.history.append(.init(session: previous, ended: Date(), completed: completed))
        archive.history = Array(archive.history.suffix(200))
        archive.session = nil; blockedTarget = nil
        guard persist() else {
            archive = previousArchive; archive.session?.pause(at: Date())
            browser.restore(); startTimerIfNeeded(); refreshPresentation()
            windows.notify(title: "无法保存专注结果", detail: message, success: false)
            return
        }
        browser.restore()
        if preferences.restoreApplications {
            restorePending.merge(requestedApplications.filter { NSRunningApplication(processIdentifier: $0.key)?.isTerminated == false }) { _, new in new }
            for url in archive.terminatedApplications { restoreApplication(url) }
        }
        archive.terminatedApplications = []; quitRequested = [:]; requestedApplications = [:]; deferredQuit = []; persist()
        refreshPresentation()
        if completed {
            windows.notify(title: "专注已完成", detail: previous.configuration.goal, success: true)
        }
    }
    private func restoreApplication(_ url: URL) {
        guard url.isFileURL, url.pathExtension == "app",
              !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == url }) else { return }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    func applicationURL(_ id: String) -> URL? {
        let workspace = NSWorkspace.shared
        if let url = workspace.runningApplications.first(where: { $0.bundleIdentifier == id })?.bundleURL { return url }
        for url in Array(requestedApplications.values) + archive.terminatedApplications {
            if Bundle(url: url)?.bundleIdentifier == id { return url }
        }
        return workspace.urlForApplication(withBundleIdentifier: id)
    }
    func snooze(target: FocusApplication? = nil) {
        guard let target = target ?? blockedTarget, session != nil, session?.paused == false, preferences.snoozeMinutes > 0 else { return }
        archive.session?.snooze(target.id, at: Date(), duration: Double(preferences.snoozeMinutes * 60))
        browser.restore(host: target.id)
        if let url = applicationURL(target.id) {
            let sessionID = session?.id
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async {
                    guard let self, self.session?.id == sessionID else { return }
                    self.message = error.localizedDescription
                    self.windows.notify(title: "无法重新打开应用", detail: self.message, success: false)
                }
            }
        }
        blockedTarget = nil; deferredQuit.remove(target.id); windows.dismissNotice(); persist(); refreshPresentation()
    }

    private func tick() {
        now = Date()
        guard running, session != nil else { return }
        if !permission.available { if session?.paused == false { pause() }; message = permission.guidance; return }
        if let end = session?.breakEnds, end <= now {
            archive.session?.pause(at: now)
            windows.notify(title: "休息结束", detail: "准备好后恢复专注", success: false)
            persist()
        }
        if session?.remaining(at: now) == 0 { finish(completed: true); return }
        if let active = session, let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let until = active.snoozes[id], until <= now { deferredQuit.insert(id) }
        if session?.snoozes.contains(where: { $0.value <= now }) == true { archive.session?.expireSnoozes(at: now) }
        if Int(now.timeIntervalSince1970) % 10 == 0 { persist() }
        enforce(); refreshPresentation()
    }
    func enforce() {
        guard running, permission.available, let active = session, !active.paused else { return }
        let workspace = NSWorkspace.shared
        for (pid, url) in requestedApplications where NSRunningApplication(processIdentifier: pid)?.isTerminated != false {
            if !archive.terminatedApplications.contains(url) { archive.terminatedApplications.append(url); persist() }
            requestedApplications.removeValue(forKey: pid)
        }
        let current = workspace.frontmostApplication
        for app in workspace.runningApplications {
            guard app.activationPolicy == .regular, !app.isTerminated, let id = app.bundleIdentifier,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier, id != Bundle.main.bundleIdentifier,
                  !["com.apple.finder", "com.apple.systempreferences", "com.apple.loginwindow"].contains(id),
                  active.configuration.blocks(application: id), !active.snoozed(id, at: now) else { continue }
            if current?.processIdentifier == app.processIdentifier {
                let target = FocusApplication(id: id, name: app.localizedName ?? id)
                if blockedTarget != target {
                    blockedTarget = target
                    windows.notify(title: target.name + " 已被屏蔽", detail: "Keylane Focus 正在保护你的专注", success: false)
                }
            }
            // When a snooze expires, keep the active app available to save work;
            // show its blocking overlay and quit after focus leaves it.
            if deferredQuit.contains(id), current?.bundleIdentifier == id { continue }
            deferredQuit.remove(id)
            if now.timeIntervalSince(quitRequested[app.processIdentifier] ?? .distantPast) >= 10 {
                quitRequested[app.processIdentifier] = now
                if let url = app.bundleURL, app.terminate() { requestedApplications[app.processIdentifier] = url }
            }
        }
        if let current, current.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           !active.configuration.blocks(application: current.bundleIdentifier ?? "") { blockedTarget = nil }
        if requiresWebsiteBlocking(active.configuration) {
            if let unavailable = unsupportedBrowser(active.configuration) {
                pause(); browserMessage = "\(unavailable) 暂不支持网站屏蔽，请编辑会话或更换浏览器。"
                windows.notify(title: "专注已暂停", detail: browserMessage, success: false); return
            }
            let snoozes = active.snoozeKeys(at: now)
            browser.poll(configuration: active.configuration, preferences: preferences, snoozes: snoozes) { [weak self] error, host in
                guard let self, self.session?.id == active.id, self.session?.paused == false else { return }
                self.browserMessage = error ?? ""
                if let error {
                    self.pause(); self.message = error
                    self.windows.notify(title: "网站屏蔽需要处理", detail: error, success: false)
                    return
                }
                if let host {
                    self.blockedTarget = FocusApplication(id: host, name: host)
                    self.windows.notify(title: host + " 已被屏蔽", detail: "可临时放行或暂停专注", success: false)
                    self.refreshPresentation()
                }
            }
        }
    }

    private func requiresWebsiteBlocking(_ configuration: FocusConfiguration) -> Bool {
        !configuration.websites.isEmpty || (configuration.mode == .allow && !preferences.allowAllWebsites)
    }
    private func unsupportedBrowser(_ configuration: FocusConfiguration) -> String? {
        NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard let id = app.bundleIdentifier, !configuration.blocks(application: id) else { return nil }
            return FocusBrowser.unsupported[id]
        }.first
    }
    func prepareCategory(_ category: FocusCategory? = nil, duplicate: Bool = false) {
        categoryDraft = category ?? FocusCategory(name: "")
        editingCategory = duplicate ? nil : category?.id
        if duplicate { categoryDraft.id = UUID(); categoryDraft.name += " 副本" }
        message = loaded ? "" : "专注数据读取失败，请检查数据文件后重试。"
    }
    func saveCategory() -> Bool {
        do {
            let value = try categoryDraft.validated()
            var categories = archive.categories
            if let index = categories.firstIndex(where: { $0.id == editingCategory }) { categories[index] = value }
            else { categories.append(value) }
            guard categories.count <= 200 else { throw FocusError.invalidImport }
            let previous = archive.categories
            archive.categories = categories
            guard persist() else { archive.categories = previous; return false }
            message = ""; selectedCategory = value.id; return true
        } catch { message = error.localizedDescription; return false }
    }
    func moveCategory(_ delta: Int) {
        let rows = visibleCategories
        guard !rows.isEmpty else { selectedCategory = nil; return }
        let index = rows.firstIndex { $0.id == selectedCategory } ?? 0
        selectedCategory = rows[NavigationBounds.move(index, by: delta, count: rows.count)].id
    }
    func deleteCategory() {
        guard isCustomCategory, let category = chosenCategory else { return }
        let alert = NSAlert(); alert.messageText = "删除「\(category.name)」？"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        let remove: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let previous = self.archive.categories
            self.archive.categories.removeAll { $0.id == category.id }
            guard self.persist() else { self.archive.categories = previous; return }
            self.selectedCategory = self.visibleCategories.first?.id
        }
        if let window = (NSApp.delegate as? Delegate)?.window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: remove) }
        else { remove(alert.runModal()) }
    }

    func importCategories() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        choose(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_000_000 else { throw FocusError.invalidImport }
                let imported = try FocusStore.decodeCategories(Data(contentsOf: url))
                var merged = self.archive.categories
                for var category in imported { category.id = UUID(); merged.append(category) }
                guard merged.count <= 200 else { throw FocusError.invalidImport }
                let previous = self.archive.categories; self.archive.categories = merged
                if !self.persist() { self.archive.categories = previous }
                else { self.message = "已导入 \(imported.count) 个分类。" }
            } catch { self.message = error.localizedDescription }
        }
    }
    func exportCategory() {
        guard let category = chosenCategory else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "Focus Category.json"
        choose(panel) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do { try FocusStore.encodeCategories([category]).write(to: url, options: .atomic) }
            catch { self?.message = error.localizedDescription }
        }
    }
    private func choose(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = (NSApp.delegate as? Delegate)?.window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(panel.runModal()) }
    }

    @discardableResult private func persist() -> Bool {
        guard loaded else { return false }
        do {
            archive.checkpoint = Date()
            try store.save(archive)
            return true
        } catch {
            message = FocusError.storage.localizedDescription; return false
        }
    }
    func refreshPresentation() {
        guard running else { return }
        registry.update(id: Self.owner, presentation: .init(
            title: session == nil ? "" : status, symbol: "target", toolTip: session?.configuration.goal ?? "Keylane Focus",
            isVisible: session != nil && preferences.inMenuBar))
        windows.update()
    }
    func menuCommands() -> [MenuBarCommand] {
        guard let session else { return [] }
        return [.heading(session.configuration.goal), .separator,
                session.paused ? .init(title: "恢复", action: { [weak self] in self?.resume() }) :
                    .init(title: "暂停", children: pauseCommands()),
                .init(title: "编辑", action: { [weak self] in self?.edit?() }),
                .init(title: "完成", action: { [weak self] in self?.finish(completed: true) }),
                .init(title: "取消", action: { [weak self] in self?.finish(completed: false) }),
                .separator,
                .init(title: preferences.inMenuBar ? "从菜单栏分离" : "移到菜单栏", action: { [weak self] in
                    guard let self else { return }; self.preferences.inMenuBar.toggle()
                }),
                .init(title: "专注设置…", action: { [weak self] in self?.openSettings?() })]
    }
    private func pauseCommands() -> [MenuBarCommand] {
        [MenuBarCommand(title: "直到手动恢复", action: { [weak self] in self?.pause() })] +
            [1, 3, 5, 10, 15, 30].map { minutes in
                MenuBarCommand(title: "\(minutes) 分钟", action: { [weak self] in self?.pause(minutes: minutes) })
            }
    }
}
