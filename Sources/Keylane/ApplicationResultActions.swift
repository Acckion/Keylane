import AppKit
import Combine
import KeylaneCore
import UniformTypeIdentifiers

final class ApplicationResultActions {
    let commandEditor = ApplicationCommandEdit()
    let uninstallSelection = ApplicationUninstallSelection()
    let uninstallReview = ApplicationUninstallReview()
    private let workspace = NSWorkspace.shared
    private var restarting = Set<String>()
    private var uninstalling = Set<String>()
    private let uninstallQueue = DispatchQueue(label: "org.keylane.applications.uninstall", qos: .userInitiated)
    private var uninstallCatalogChanges: AnyCancellable?
    private var uninstallLoad: DispatchWorkItem?

    private static let directShortcuts: [(String, [String])] = [
        ("finder-reveal", ["⌘", "⇧", "F"]),
        ("finder-info", ["⌘", "⇧", "I"]),
        ("copy-path", ["⌘", "⌥", "C"]),
        ("edit-app-command", ["⌘", "⇧", "E"]),
        ("restart-app", ["⌘", "⇧", "R"])
    ]

    func shortcutActions(for entry: Entry, model: Model) -> [LauncherAction] {
        Self.directShortcuts.map { id, keys in
            LauncherAction(id: id, title: "", icon: "", keys: keys) { [weak model] in
                guard let model, model.isApplicationCommandAvailable(at: entry.id),
                      let action = self.actions(for: entry, model: model).first(where: { $0.id == id }),
                      action.enabled else { return }
                action.perform()
            }
        }
    }

    private func keys(_ id: String) -> [String] {
        Self.directShortcuts.first(where: { $0.0 == id })?.1 ?? []
    }

    func actions(for entry: Entry, model: Model) -> [LauncherAction] {
        let url = URL(fileURLWithPath: entry.id)
        let path = url.resolvingSymlinksInPath().path
        let running = !instances(at: path).isEmpty && !restarting.contains(path)
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let favorite = model.favorites.contains(entry.id)
        let autoQuitEnabled = model.applicationAutoQuit.minutes(for: url) != 0
        return [
            .init(id: "open", title: "打开应用", icon: "arrow.up.forward.app", keys: ["↩"]) { [weak model] in
                model?.runCommand(entry.commandID, origin: .menu, usageKey: entry.id)
            },
            .init(id: "finder-reveal", title: "在 Finder 中显示", icon: "folder", keys: keys("finder-reveal")) {
                self.reveal(url)
            },
            .init(id: "finder-info", title: "在 Finder 中显示信息", icon: "info.circle", keys: keys("finder-info")) { [weak model] in
                guard let permission = model?.finderAutomation else { return }
                permission.activate { allowed in
                    if allowed { self.showFinderInfo(url) }
                    else { self.feedback(permission.guidance) }
                }
            },
            .init(id: "package-contents", title: "显示包内容", icon: "shippingbox") {
                self.reveal(url.appendingPathComponent("Contents", isDirectory: true))
            },
            .init(id: "favorite", title: favorite ? "取消收藏" : "添加到收藏",
                  icon: favorite ? "star.fill" : "star", group: 1) { [weak model] in
                model?.toggleFavorite(entry.id, showsFeedback: true)
            },
            .init(id: "copy-path", title: "复制路径", icon: "doc.on.doc", keys: keys("copy-path"), group: 2) { UtilityActions.copy(url.path, feedback: "已复制路径") },
            .init(id: "copy-name", title: "复制名称", icon: "textformat", group: 2) { UtilityActions.copy(entry.name, feedback: "已复制名称") },
            .init(id: "copy-bundle-id", title: "复制 Bundle Identifier", icon: "number", group: 2, enabled: bundleID != nil) {
                if let bundleID { UtilityActions.copy(bundleID, feedback: "已复制 Bundle Identifier") }
            },
            .init(id: "edit-app-command", title: "编辑别名与快捷键…", icon: "keyboard", keys: keys("edit-app-command"), group: 3) { [weak model] in
                guard let model, model.isApplicationCommandAvailable(at: entry.id) else { return }
                self.commandEditor.prepare(entry, model: model, isAvailable: { [weak model] in
                    model?.isApplicationCommandAvailable(at: entry.id) == true
                })
                model.openPage(ApplicationCommandEdit.pageID, origin: .search)
            },
            .init(id: "command-settings", title: "命令设置", icon: "gearshape", group: 3) { [weak model] in
                model?.openApplicationCommandSettings(path: entry.id)
            },
            .init(id: "extension-settings", title: "扩展设置", icon: "gearshape", group: 3) { [weak model] in
                model?.openSettings(page: "applications")
            },
            model.resetRankingAction(for: entry),
            .init(id: "hide-app", title: "隐藏应用", icon: "eye.slash", group: 4, enabled: running) {
                self.apply(to: path, failure: "无法隐藏应用。") { $0.hide() }
            },
            .init(id: "quit-app", title: "退出应用", icon: "rectangle.portrait.and.arrow.right", group: 4, enabled: running) {
                self.apply(to: path, failure: "无法请求应用退出。") { $0.terminate() }
            },
            .init(id: "force-quit-app", title: "强制退出应用", icon: "xmark.octagon", group: 4, enabled: running) {
                self.forceQuit(at: path, name: entry.name)
            },
            .init(id: "auto-quit-app", title: autoQuitEnabled ? "关闭自动退出" : "启用自动退出", icon: "app.badge.clock", group: 4,
                  enabled: model.applicationAutoQuit.canConfigure(url)) { [weak model] in
                guard let autoQuit = model?.applicationAutoQuit else { return }
                let enabling = autoQuit.minutes(for: url) == 0
                autoQuit.setMinutes(enabling ? ApplicationAutoQuit.useDefault : 0, for: url)
                self.feedback(enabling ? "已启用自动退出（\(autoQuit.defaultMinutes) 分钟）" : "已关闭自动退出", style: .success)
            },
            .init(id: "restart-app", title: "重启应用", icon: "arrow.clockwise", keys: keys("restart-app"), group: 4, enabled: running) { [weak model] in
                guard let model else { return }
                self.restart(url, path: path, model: model)
            },
            .init(id: "hide-command", title: "隐藏命令", icon: "eye.slash", group: 4, destructive: true) { [weak model] in
                model?.setApplicationEnabled(false, path: entry.id)
                self.feedback("已隐藏「\(entry.name)」。可在应用程序设置中重新启用。", style: .success)
            },
            .init(id: "uninstall-app", title: "卸载应用…", icon: "trash", group: 4,
                  enabled: Self.uninstallCandidate(url) != nil, destructive: true) { [weak model] in
                guard let model else { return }
                self.uninstall(url, model: model)
            }
        ] + model.favoriteOrderActions(for: entry.id)
    }

    func restartFrontmost(model: Model) {
        let frontmost = workspace.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? (NSApp.delegate as? Delegate)?.previousApplication : frontmost
        guard let target, target.activationPolicy == .regular, !target.isTerminated,
              target.bundleIdentifier != "com.apple.finder", let url = target.bundleURL else {
            feedback("找不到可重启的前台应用。")
            return
        }
        (NSApp.delegate as? Delegate)?.hideLauncher()
        restart(url, path: url.resolvingSymlinksInPath().path, model: model)
    }

    func startUninstallSelection(catalog: ApplicationSettingsCatalog, query: String) {
        uninstallSelection.filter(query)
        guard uninstallCatalogChanges == nil else { return }
        uninstallCatalogChanges = catalog.$items.sink { [weak self] items in
            self?.loadUninstallCandidates(items)
        }
    }

    private func loadUninstallCandidates(_ items: [ApplicationPreferenceItem]) {
        uninstallLoad?.cancel()
        let request = DispatchWorkItem {}
        uninstallLoad = request
        uninstallSelection.isLoading = true
        uninstallQueue.async { [weak self] in
            var candidates: [ApplicationPreferenceItem] = []
            for item in items {
                guard !request.isCancelled else { return }
                if Self.uninstallCandidate(item.url) != nil { candidates.append(item) }
            }
            let result = candidates
            DispatchQueue.main.async { [weak self] in
                guard let self, self.uninstallLoad === request else { return }
                self.uninstallLoad = nil
                self.uninstallSelection.load(result)
                self.uninstallSelection.isLoading = false
            }
        }
    }

    func stopUninstallSelection() {
        uninstallCatalogChanges?.cancel()
        uninstallCatalogChanges = nil
        uninstallLoad?.cancel()
        uninstallLoad = nil
        uninstallSelection.clear()
    }

    func uninstall(_ url: URL, model: Model, keepLauncher: Bool = false) {
        guard let candidate = Self.uninstallCandidate(url) else {
            feedback("无法卸载所选项目。请选择仍存在且可移除的应用。")
            return
        }
        let name = model.appName(candidate.url)
        guard instances(at: candidate.url.path).isEmpty else {
            feedback("请先退出「\(name)」，然后重新卸载。")
            return
        }
        let operation = candidate.identifier.lowercased()
        guard uninstalling.insert(operation).inserted else { return }
        let page = model.pageID
        let knownApps = knownCopies(of: candidate, in: model)
        let window = (NSApp.delegate as? Delegate)?.window
        let launchedFromVisibleWindow = window?.isVisible == true
        uninstallQueue.async { [weak model, weak window] in
            let shared = self.hasOtherCopy(of: candidate, knownApps: knownApps)
            let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
            let leftovers = shared ? [] : ApplicationLeftovers.find(bundleIdentifier: candidate.identifier, in: library)
            DispatchQueue.main.async { [weak model, weak window] in
                guard let model, model.pageID == page,
                      !launchedFromVisibleWindow || window?.isVisible == true,
                      !keepLauncher || window?.attachedSheet == nil else {
                    self.uninstalling.remove(operation)
                    return
                }
                self.confirmUninstall(url, candidate: candidate, operation: operation, name: name,
                                      leftovers: leftovers, shared: shared, model: model)
            }
        }
    }

    private struct UninstallCandidate {
        let url: URL
        let identity: NSObject
        let identifier: String
    }

    private func knownCopies(of candidate: UninstallCandidate, in model: Model) -> [URL] {
        model.apps.filter {
            model.discoveredIdentity(for: $0)?.bundleIdentifier?.lowercased() == candidate.identifier.lowercased()
        }
    }

    private func hasOtherCopy(of candidate: UninstallCandidate, knownApps: [URL]) -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: candidate.identifier)
        if running.contains(where: { !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path != candidate.url.path }) {
            return true
        }
        let registered = workspace.urlsForApplications(withBundleIdentifier: candidate.identifier)
        return (registered + knownApps).contains { url in
            let resolved = url.resolvingSymlinksInPath()
            return resolved.path != candidate.url.path &&
                Bundle(url: resolved)?.bundleIdentifier?.lowercased() == candidate.identifier.lowercased() &&
                FileManager.default.fileExists(atPath: resolved.path)
        }
    }

    private func confirmUninstall(_ url: URL, candidate: UninstallCandidate, operation: String, name: String,
                                  leftovers: [ApplicationLeftovers.Item], shared: Bool, model: Model) {
        guard model.applicationsEnabled, model.launcherModules?.page(ApplicationUninstallReview.pageID) != nil else {
            uninstalling.remove(operation)
            return
        }
        let detail: String
        if shared {
            detail = "检测到同一应用的其他副本，将保留可能共用的文件。"
        } else if leftovers.isEmpty {
            detail = "在常见位置没有找到与此应用标识匹配的文件。"
        } else {
            detail = "关联文件默认保留，请勾选需要一并移除的项目。"
        }
        uninstallReview.prepare(name: name, detail: detail,
                                items: [.init(url: candidate.url, isApplication: true)] + leftovers.map { .init(url: $0.url) },
                                confirm: { [weak self, weak model] selected in
            guard let self else { return }
            self.trashApplication(url, candidate: candidate, operation: operation, name: name,
                                  leftovers: leftovers.filter { selected.contains($0.url.path) }, model: model)
        }, cancel: { [weak self] in self?.uninstalling.remove(operation) })
        model.openPage(ApplicationUninstallReview.pageID, origin: .menu)
    }

    private func trashApplication(_ url: URL, candidate: UninstallCandidate, operation: String, name: String,
                                  leftovers: [ApplicationLeftovers.Item], model: Model?) {
        let knownApps = model.map { knownCopies(of: candidate, in: $0) } ?? []
        uninstallQueue.async { [weak model] in
            let outcome = Result {
                guard self.instances(at: candidate.url.path).isEmpty else {
                    throw UninstallFailure.running
                }
                guard let current = Self.uninstallCandidate(url),
                      current.url == candidate.url, current.identity == candidate.identity,
                      current.identifier == candidate.identifier else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let shared = !leftovers.isEmpty && self.hasOtherCopy(of: candidate, knownApps: knownApps)
                try FileManager.default.trashItem(at: candidate.url, resultingItemURL: nil)
                return leftovers.compactMap { item -> (URL, Error)? in
                    do {
                        guard !shared else {
                            throw UninstallFailure.shared
                        }
                        try ApplicationLeftovers.trash(item)
                        return nil
                    } catch {
                        return (item.url, error)
                    }
                }
            }
            DispatchQueue.main.async { [weak model] in
                self.uninstalling.remove(operation)
                if self.uninstallReview.items.first?.id == candidate.url.path {
                    self.uninstallReview.clear()
                    if model?.pageID == ApplicationUninstallReview.pageID {
                        model?.pageID = PageID(rawValue: "ApplicationUninstall")
                    }
                }
                switch outcome {
                case .success(let failures):
                    self.uninstallSelection.remove(candidate.url.path)
                    model?.applicationAutoQuit.removeRule(at: candidate.url.path)
                    model?.discovery.refresh()
                    if let (path, error) = failures.first {
                        let shortPath = path.deletingLastPathComponent().lastPathComponent + "/" + path.lastPathComponent
                        self.feedback("已卸载「\(name)」。\(failures.count) 项关联文件未移除（\(shortPath)：\(error.localizedDescription)）")
                    } else if leftovers.isEmpty {
                        self.feedback("已将「\(name)」移到废纸篓。", style: .success)
                    } else {
                        self.feedback("已将「\(name)」和 \(leftovers.count) 项关联文件移到废纸篓。", style: .success)
                    }
                case .failure(let error):
                    self.feedback("无法卸载「\(name)」：\(error.localizedDescription)")
                }
            }
        }
    }

    private enum UninstallFailure: LocalizedError {
        case running, shared
        var errorDescription: String? {
            switch self {
            case .running: "应用正在运行，请先退出再重试。"
            case .shared: "检测到同一应用的其他副本，已保留可能共用的文件。"
            }
        }
    }

    private static func uninstallCandidate(_ url: URL) -> UninstallCandidate? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let original = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), original.isSymbolicLink == false else { return nil }
        let target = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
        guard !target.path.hasPrefix("/System/"),
              !target.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
              let identifier = Bundle(url: target)?.bundleIdentifier,
              identifier != Bundle.main.bundleIdentifier,
              let values = try? target.resourceValues(forKeys: [.isApplicationKey, .fileResourceIdentifierKey]),
              values.isApplication == true, let identity = values.fileResourceIdentifier as? NSObject else { return nil }
        return UninstallCandidate(url: target, identity: identity, identifier: identifier)
    }

    private func reveal(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            feedback("所选应用或包内容已不可用。")
            return
        }
        workspace.activateFileViewerSelecting([url])
    }

    private func showFinderInfo(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            feedback("应用已移走或删除。")
            return
        }
        let path = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let script = NSAppleScript(source: """
        with timeout of 5 seconds
            set appFile to POSIX file "\(path)" as alias
            tell application id "com.apple.finder"
                open information window of appFile
                activate
            end tell
        end timeout
        """)
        guard let script else { feedback("无法打开 Finder 信息窗口。"); return }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            feedback(code == -1743 ? "请在系统设置的「隐私与安全性 → 自动化」中允许 Keylane 访问 Finder。" :
                        "无法打开 Finder 信息窗口。")
        }
    }

    private func instances(at path: String) -> [NSRunningApplication] {
        workspace.runningApplications.filter {
            !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
                $0.bundleURL?.resolvingSymlinksInPath().path == path
        }
    }

    private func apply(to path: String, failure: String, operation: (NSRunningApplication) -> Bool) {
        let applications = instances(at: path)
        guard !applications.isEmpty else { feedback("应用已退出。"); return }
        let outcomes = applications.map(operation)
        if outcomes.contains(false) { feedback(failure) }
    }

    private func forceQuit(at path: String, name: String) {
        let applications = instances(at: path)
        guard !applications.isEmpty else { feedback("应用已退出。"); return }
        let alert = NSAlert()
        alert.messageText = "强制退出「\(name)」？"
        alert.informativeText = "未保存的更改可能丢失。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "强制退出").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let outcomes = applications.filter { !$0.isTerminated }.map { $0.forceTerminate() }
        if outcomes.contains(false) { feedback("无法强制退出应用。") }
    }

    private func restart(_ url: URL, path: String, model: Model) {
        let applications = instances(at: path)
        guard !applications.isEmpty else { feedback("应用已退出，请使用「打开应用」。"); return }
        guard restarting.insert(path).inserted else { return }
        let outcomes = applications.map { $0.terminate() }
        if outcomes.contains(false) {
            restarting.remove(path)
            feedback("无法请求应用退出，已取消重启。")
            return
        }
        waitForExit(url, path: path, deadline: ProcessInfo.processInfo.systemUptime + 15, model: model)
    }

    private func waitForExit(_ url: URL, path: String, deadline: TimeInterval, model: Model) {
        if instances(at: path).isEmpty {
            restarting.remove(path)
            model.launch(url)
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            restarting.remove(path)
            feedback("应用仍在运行，已取消重启。请处理应用中的保存提示后重试。")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak model] in
                guard let self, let model else { return }
                self.waitForExit(url, path: path, deadline: deadline, model: model)
            }
        }
    }

    private func feedback(_ message: String, style: ToastStyle = .failure) {
        (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: style)
    }
}
