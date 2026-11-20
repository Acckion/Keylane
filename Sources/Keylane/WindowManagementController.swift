import AppKit
import Combine
import KeylaneCore
import UniformTypeIdentifiers

final class WindowManagementController: ObservableObject {
    static let editorPage = PageID(rawValue: "WindowActionEditor")
    static let layoutPage = PageID(rawValue: "WindowLayoutEditor")
    static let coordinatesPage = PageID(rawValue: "WindowCoordinates")
    static let customPrefix = "window-custom:"

    let preferences = WindowManagementPreferences()
    @Published private(set) var actions: [CustomWindowAction] = []
    @Published var draft = CustomWindowAction()
    @Published var layoutDraft = CustomWindowAction(windows: [])
    @Published var layoutHasInvalidMeasurements = false
    private(set) var layoutEditorID = UUID()
    var layoutIsValid: Bool { layoutDraft.isValid && !layoutHasInvalidMeasurements }
    @Published var coordinates = WindowCoordinates()
    @Published var error = ""

    struct WindowCoordinates: Equatable {
        var resize = false
        var first = ""
        var second = ""

        var placement: WindowPlacement? {
            guard let a = Double(first), let b = Double(second), a.isFinite, b.isFinite else { return nil }
            if resize {
                guard a > 0, b > 0 else { return nil }
                return .resize(CGSize(width: a, height: b))
            }
            return .move(CGPoint(x: a, y: b))
        }
    }

    private weak var model: Model?
    private var permission: PermissionFeature
    private var requests: [UUID: NavigationScanRequest] = [:]
    private var layoutPathPanel: NSOpenPanel?
    private var grid: WindowGridPanel?
    private var gridRequest: NavigationScanRequest?
    private var syncChanges: AnyCancellable?
    private let storageKey = "windowManagement.customActions"

    init(model: Model, permission: PermissionFeature) {
        self.model = model
        self.permission = permission
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let archive = try? JSONDecoder().decode(WindowActionsArchive.self, from: data), archive.isValid {
            actions = archive.actions
        }
        syncChanges = NotificationCenter.default.publisher(for: .keylaneSyncApplied).sink { [weak self] note in
            guard let self, let categories = note.userInfo?["categories"] as? Set<SyncCategory>, categories.contains(.layouts),
                  let data = UserDefaults.standard.data(forKey: self.storageKey),
                  let archive = try? JSONDecoder().decode(WindowActionsArchive.self, from: data), archive.isValid else { return }
            self.actions = archive.actions
        }
    }

    func run(_ command: WindowCommand, origin: LauncherCommandOrigin) {
        guard let delegate = NSApp.delegate as? Delegate, permission.available else { return }
        if origin == .shortcut { delegate.rememberPreviousApplication() }
        let app = delegate.previousApplication
        let options = preferences.options(for: command)
        switch command.action {
        case .place(let placement): manage(.place(placement), app: app)
        case .half(let edge): manage(.half(edge), app: app)
        case .almostMaximize: manage(.place(.proportional(Double(options.percentage) / 100)), app: app)
        case .adjustSize(let direction): manage(.place(.grow(CGFloat(direction * options.step))), app: app)
        case .edge(let edge): manage(.place(.moveEdge(edge, centered: options.center)), app: app)
        case .display(let step): manage(.place(.displayStep(step, wrap: options.wrap, keepAspectRatio: options.aspect)), app: app)
        case .minimize: manage(.minimize, app: app)
        case .fullscreen: manage(.fullscreen, app: app)
        case .minimizeDisplay:
            let center = (delegate.window?.isVisible == true ? delegate.window?.screen?.frame.center : nil) ?? NSEvent.mouseLocation
            let point = CGPoint(x: center.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - center.y)
            manage(.minimizeDisplay, app: app, displayAt: point)
        case .coordinate(let resize):
            error = ""
            coordinates = .init(resize: resize)
        case .grid:
            showGrid(for: app)
        case .createCommand:
            draft = .init()
            error = ""
        case .createLayout: prepareLayout(.init(windows: []))
        case .saveLayout: captureCurrentLayout(origin: origin)
        case .importLayouts: importActions()
        case .switchSpace(let direction):
            delegate.hideLauncher()
            WindowSpaces.switchSpace(direction, animate: options.animateSpace, completion: { [weak self] failure in
                if let failure { self?.feedback(failure) }
            })
        case .moveToSpace(let direction):
            guard let app else { feedback("没有可移动的聚焦窗口。"); return }
            let request = NavigationScanRequest()
            let id = UUID()
            requests[id] = request
            SystemNavigation.shared.windowTarget(in: app, options: .init(), request: request) { [weak self, weak delegate] target in
                guard let self, self.requests.removeValue(forKey: id) != nil else { return }
                guard let target else { self.feedback("没有可移动的聚焦窗口。"); return }
                delegate?.hideLauncher()
                if !app.isActive {
                    NSApp.yieldActivation(to: app)
                    _ = app.activate(from: .current)
                }
                WindowSpaces.moveWindow(target, app: app, direction: direction) { [weak self] failure in
                    if let failure { self?.feedback(failure) }
                }
            }
        }
    }

    func submitCoordinates() {
        guard let placement = coordinates.placement else { error = "请输入有效的数字。"; return }
        manage(.place(placement), app: (NSApp.delegate as? Delegate)?.previousApplication)
    }

    func run(_ item: CustomWindowAction, origin: LauncherCommandOrigin) {
        guard permission.available, let delegate = NSApp.delegate as? Delegate else { return }
        if origin == .shortcut { delegate.rememberPreviousApplication() }
        if let geometry = item.geometry { manage(.place(.custom(geometry)), app: delegate.previousApplication) }
        else if let windows = item.windows { applyLayout(windows, layout: item) }
    }

    private func manage(_ operation: SystemNavigation.WindowOperation, app: NSRunningApplication?,
                        expected: SystemNavigation.WindowTarget? = nil, displayAt point: CGPoint? = nil) {
        guard permission.available else { return }
        let request = NavigationScanRequest()
        let id = UUID()
        requests[id] = request
        SystemNavigation.shared.manageWindow(operation, in: app, options: preferences.placementOptions,
                                             expected: expected, displayAt: point, request: request) { [weak self] failure in
            guard let self, self.requests.removeValue(forKey: id) != nil else { return }
            if let failure {
                self.error = failure
                self.feedback(failure)
            } else if let delegate = NSApp.delegate as? Delegate {
                delegate.hideLauncher()
            }
        }
    }

    private func showGrid(for app: NSRunningApplication?) {
        if grid != nil || gridRequest != nil { dismissGrid(); return }
        guard let app, let delegate = NSApp.delegate as? Delegate else { feedback("没有可调整的聚焦窗口。"); return }
        let request = NavigationScanRequest()
        gridRequest = request
        SystemNavigation.shared.windowTarget(in: app, options: preferences.placementOptions, request: request) { [weak self, weak delegate] target in
            guard let self, self.gridRequest === request else { return }
            guard let target else {
                self.gridRequest = nil
                self.feedback("没有可调整的聚焦窗口。")
                return
            }
            delegate?.hideLauncher()
            if !app.isActive {
                NSApp.yieldActivation(to: app)
                _ = app.activate(from: .current)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.75
            func presentWhenFocused() {
                guard self.gridRequest === request else { return }
                if !app.isActive {
                    if !app.isTerminated, ProcessInfo.processInfo.systemUptime < deadline {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: presentWhenFocused)
                    } else {
                        self.gridRequest = nil
                        self.feedback("目标窗口未能获得焦点。")
                    }
                    return
                }
                self.gridRequest = nil
                let grid = WindowGridPanel(display: target.display, options: self.preferences.placementOptions) { [weak self] region in
                    self?.grid = nil
                    guard let region else { return }
                    guard app.isActive else {
                        self?.feedback("焦点窗口已变化。")
                        return
                    }
                    self?.manage(.place(.region(region)), app: app, expected: target)
                }
                self.grid = grid
                grid.show()
            }
            presentWhenFocused()
        }
    }

    private func dismissGrid() {
        gridRequest?.cancel()
        gridRequest = nil
        grid?.dismiss()
        grid = nil
    }

    func cancel() {
        for request in requests.values { request.cancel() }
        requests.removeAll()
        dismissGrid()
        leaveLayout()
        if model?.pageID == Self.layoutPage { model?.pageID = .root }
    }

    func edit(_ item: CustomWindowAction, origin: LauncherCommandOrigin = .menu) {
        if item.windows != nil {
            guard permission.available else { return }
            prepareLayout(item)
            model?.openPage(Self.layoutPage, origin: origin == .search ? .menu : origin)
            return
        }
        draft = item
        error = ""
        model?.openPage(Self.editorPage, origin: origin == .search ? .menu : origin)
    }

    func duplicate(_ item: CustomWindowAction) {
        var duplicate = item
        duplicate.id = UUID()
        duplicate.name += " 副本"
        edit(duplicate)
    }

    func saveDraft() {
        guard save(draft) else { error = "请填写名称并检查窗口尺寸和位置。"; return }
        model?.pageID = .root
        feedback("已保存「\(draft.name)」。", succeeded: true)
    }

    private func save(_ draft: CustomWindowAction) -> Bool {
        var item = draft
        item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = actions
        if let index = next.firstIndex(where: { $0.id == item.id }) { next[index] = item }
        else { next.append(item) }
        return persist(next)
    }

    private func prepareLayout(_ item: CustomWindowAction) {
        leaveLayout()
        layoutDraft = item
    }

    func leaveLayout() {
        layoutEditorID = UUID()
        layoutPathPanel?.cancel(nil)
        layoutPathPanel = nil
        layoutHasInvalidMeasurements = false
    }

    func saveLayoutDraft() {
        guard permission.available, model?.pageID == Self.layoutPage, layoutIsValid else { return }
        guard save(layoutDraft) else { feedback("无法保存布局。请检查名称和窗口设置。"); return }
        model?.pageID = .root
        feedback("已保存「\(layoutDraft.name)」。", succeeded: true)
    }

    func captureLayoutEditorWindows(completion: @escaping ([WindowLayoutEntry]) -> Void) {
        let session = layoutEditorID
        captureVisibleWindows { [weak self] entries in
            guard let self, self.layoutEditorID == session, self.model?.pageID == Self.layoutPage else { return }
            completion(entries)
        }
    }

    func chooseLayoutPath(folder: Bool, completion: @escaping (String) -> Void) {
        guard model?.pageID == Self.layoutPage, layoutPathPanel == nil,
              let window = (NSApp.delegate as? Delegate)?.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        layoutPathPanel = panel
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.layoutPathPanel === panel else { return }
            self.layoutPathPanel = nil
            if response == .OK, self.model?.pageID == Self.layoutPage, let url = panel.url {
                completion(url.path)
            }
        }
    }

    func remove(_ item: CustomWindowAction) {
        let next = actions.filter { $0.id != item.id }
        if persist(next) {
            let id = item.commandID
            model?.setShortcut(id, value: nil)
            model?.setAlias(id, value: "")
            model?.disabledCommands.remove(id)
        }
    }

    private func persist(_ next: [CustomWindowAction]) -> Bool {
        let archive = WindowActionsArchive(actions: next)
        guard archive.isValid, let data = try? JSONEncoder().encode(archive) else { return false }
        UserDefaults.standard.set(data, forKey: storageKey)
        actions = next
        return true
    }

    private func captureCurrentLayout(origin: LauncherCommandOrigin) {
        captureVisibleWindows { [weak self] entries in
            guard !entries.isEmpty else { self?.feedback("当前空间没有可保存的窗口。"); return }
            var item = CustomWindowAction(windows: entries)
            item.name = "当前窗口布局"
            item.usesPreferredGaps = false
            self?.edit(item, origin: origin)
        }
    }

    private func captureVisibleWindows(completion: @escaping ([WindowLayoutEntry]) -> Void) {
        guard permission.available else { completion([]); return }
        let id = UUID()
        let request = NavigationScanRequest()
        requests[id] = request
        SystemNavigation.shared.snapshotLayout(options: preferences.placementOptions, request: request) { [weak self] entries in
            guard self?.requests.removeValue(forKey: id) != nil else { return }
            completion(entries)
        }
    }

    func importActions() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 4 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let archive = try JSONDecoder().decode(WindowActionsArchive.self, from: Data(contentsOf: url))
                guard archive.isValid else { throw CocoaError(.fileReadCorruptFile) }
                let ids = Set(self.actions.map(\.id))
                let new = archive.actions.filter { !ids.contains($0.id) }
                guard self.persist(self.actions + new) else { throw CocoaError(.fileReadCorruptFile) }
                self.feedback("已导入 \(new.count) 项，跳过 \(archive.actions.count - new.count) 项重复记录。", succeeded: true)
            } catch { self.feedback("无法导入窗口命令和布局。请检查 JSON 格式和内容。") }
        }
    }

    func exportActions() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Keylane Window Layouts.json"
        panel.begin { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(WindowActionsArchive(actions: self.actions)).write(to: url, options: .atomic)
                self.feedback("已导出窗口命令和布局。", succeeded: true)
            } catch { self.feedback("无法导出窗口命令和布局。\(error.localizedDescription)") }
        }
    }

    private func applyLayout(_ windows: [WindowLayoutEntry], layout: CustomWindowAction) {
        let id = UUID()
        let request = NavigationScanRequest()
        requests[id] = request
        (NSApp.delegate as? Delegate)?.hideLauncher()
        openLayoutEntries(windows[...], opened: [], failures: 0, request: request) { [weak self] opened, failures in
            guard let self, self.requests[id] != nil else { return }
            SystemNavigation.shared.applyLayout(opened, layout: layout, otherWindows: failures == 0 ? layout.otherWindows : .keep,
                                                options: self.preferences.placementOptions, request: request) { [weak self] rejected in
                guard let self, self.requests.removeValue(forKey: id) != nil else { return }
                let total = rejected + failures
                self.feedback(total == 0 ? "已应用窗口布局。" : "\(total) 个窗口无法应用布局。", succeeded: total == 0)
            }
        }
    }

    private func openLayoutEntries(_ entries: ArraySlice<WindowLayoutEntry>, opened: [(WindowLayoutEntry, pid_t)], failures: Int,
                                   request: NavigationScanRequest, completion: @escaping ([(WindowLayoutEntry, pid_t)], Int) -> Void) {
        guard !request.isCancelled else { return }
        guard let entry = entries.first else { completion(opened, failures); return }
        let finish: (pid_t?) -> Void = { [weak self] pid in
            self?.openLayoutEntries(entries.dropFirst(), opened: opened + (pid.map { [(entry, $0)] } ?? []),
                                   failures: failures + (pid == nil ? 1 : 0), request: request, completion: completion)
        }
        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: entry.bundleID) else { finish(nil); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let onOpen: (NSRunningApplication?, Error?) -> Void = { app, _ in
            DispatchQueue.main.async { finish(app?.processIdentifier) }
        }
        switch entry.argument {
        case .none:
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: entry.bundleID).first(where: { !$0.isTerminated }) {
                finish(app.processIdentifier)
            } else { workspace.openApplication(at: appURL, configuration: config, completionHandler: onOpen) }
        case .file(let path):
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { finish(nil); return }
            workspace.open([url], withApplicationAt: appURL, configuration: config, completionHandler: onOpen)
        case .url(let raw):
            guard let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty else { finish(nil); return }
            workspace.open([url], withApplicationAt: appURL, configuration: config, completionHandler: onOpen)
        case .quicklink(let link):
            guard let model, let url = try? model.quicklinks.resolvedLayoutURL(id: link) else { finish(nil); return }
            workspace.open([url], withApplicationAt: appURL, configuration: config, completionHandler: onOpen)
        case .arguments(let raw):
            guard let arguments = try? ArgumentParser.parse(raw), !arguments.isEmpty else { finish(nil); return }
            config.arguments = arguments
            config.createsNewApplicationInstance = true
            workspace.openApplication(at: appURL, configuration: config, completionHandler: onOpen)
        }
    }

    func feedback(_ message: String, succeeded: Bool = false) {
        if !succeeded { model?.error = message }
        (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: succeeded ? .success : .failure)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension CustomWindowAction {
    var commandID: String { WindowManagementController.customPrefix + id.uuidString }
    var displaySymbol: String {
        if windows == nil { return "rectangle.inset.filled" }
        return icon.flatMap { symbol in WindowLayoutEditor.symbols.contains(symbol) ? symbol : nil } ?? "square.grid.2x2"
    }
}
