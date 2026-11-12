import AppKit
import KeylaneCore
import UniformTypeIdentifiers

final class ApplicationResultActions {
    let commandEditor = ApplicationCommandEdit()
    let uninstallSelection = ApplicationUninstallSelection()
    private let workspace = NSWorkspace.shared
    private var restarting = Set<String>()
    private var uninstalling = Set<String>()

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
                guard let model, let action = self.actions(for: entry, model: model).first(where: { $0.id == id }),
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
                guard let model else { return }
                self.commandEditor.prepare(entry, model: model)
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
                  enabled: uninstallCandidate(url) != nil, destructive: true) { [weak model] in
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

    func loadUninstallCandidates(_ items: [ApplicationPreferenceItem]) {
        uninstallSelection.load(items.filter { uninstallCandidate($0.url) != nil })
    }

    func uninstall(_ url: URL, model: Model, keepLauncher: Bool = false) {
        guard let candidate = uninstallCandidate(url) else {
            feedback("无法卸载所选项目。请选择仍存在且可移除的应用。")
            return
        }
        let name = model.appName(candidate.url)
        guard instances(at: candidate.url.path).isEmpty else {
            feedback("请先退出「\(name)」，然后重新卸载。")
            return
        }
        guard uninstalling.insert(candidate.url.path).inserted else { return }

        let alert = NSAlert()
        alert.messageText = "卸载「\(name)」？"
        alert.informativeText = "将应用程序移到废纸篓。应用的文档、设置和其他支持文件会保留。\n\n\(candidate.url.path)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移到废纸篓").hasDestructiveAction = true
        let confirm: (NSApplication.ModalResponse) -> Void = { [weak model] response in
            guard response == .alertSecondButtonReturn else {
                self.uninstalling.remove(candidate.url.path)
                return
            }
            guard self.instances(at: candidate.url.path).isEmpty else {
                self.uninstalling.remove(candidate.url.path)
                self.feedback("请先退出「\(name)」，然后重新卸载。")
                return
            }
            self.trashApplication(url, candidate: candidate, name: name, model: model)
        }
        if keepLauncher, let window = (NSApp.delegate as? Delegate)?.window, window.isVisible {
            guard window.attachedSheet == nil else {
                uninstalling.remove(candidate.url.path)
                return
            }
            alert.beginSheetModal(for: window, completionHandler: confirm)
        } else {
            (NSApp.delegate as? Delegate)?.hideLauncher()
            NSApp.activate()
            confirm(alert.runModal())
        }
    }

    private func trashApplication(_ url: URL, candidate: (url: URL, identity: NSObject), name: String, model: Model?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak model] in
            let outcome = Result {
                guard let current = self.uninstallCandidate(url),
                      current.url == candidate.url, current.identity == candidate.identity else {
                    throw CocoaError(.fileNoSuchFile)
                }
                try FileManager.default.trashItem(at: candidate.url, resultingItemURL: nil)
            }
            DispatchQueue.main.async { [weak model] in
                self.uninstalling.remove(candidate.url.path)
                switch outcome {
                case .success:
                    self.uninstallSelection.remove(candidate.url.path)
                    model?.applicationAutoQuit.removeRule(at: candidate.url.path)
                    model?.discovery.refresh()
                    self.feedback("已将「\(name)」移到废纸篓。", style: .success)
                case .failure(let error):
                    self.feedback("无法卸载「\(name)」：\(error.localizedDescription)")
                }
            }
        }
    }

    private func uninstallCandidate(_ url: URL) -> (url: URL, identity: NSObject)? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let original = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), original.isSymbolicLink == false else { return nil }
        let target = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
        guard !target.path.hasPrefix("/System/"),
              !target.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
              let identifier = Bundle(url: target)?.bundleIdentifier,
              identifier != Bundle.main.bundleIdentifier,
              let values = try? target.resourceValues(forKeys: [.isApplicationKey, .fileResourceIdentifierKey]),
              values.isApplication == true, let identity = values.fileResourceIdentifier as? NSObject else { return nil }
        return (target, identity)
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
