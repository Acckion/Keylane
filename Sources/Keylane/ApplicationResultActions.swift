import AppKit
import KeylaneCore

final class ApplicationResultActions {
    private let workspace = NSWorkspace.shared
    private var restarting = Set<String>()

    func actions(for entry: Entry, model: Model) -> [LauncherAction] {
        let url = URL(fileURLWithPath: entry.id)
        let path = url.resolvingSymlinksInPath().path
        let running = !instances(at: path).isEmpty && !restarting.contains(path)
        let bundleID = Bundle(url: url)?.bundleIdentifier
        let favorite = model.favorites.contains(entry.id)
        return [
            .init(id: "open", title: "打开应用", icon: "arrow.up.forward.app", keys: ["↩"]) { [weak model] in
                model?.runCommand(entry.commandID, origin: .menu, usageKey: entry.id)
            },
            .init(id: "finder-reveal", title: "在 Finder 中显示", icon: "folder") {
                self.reveal(url)
            },
            .init(id: "finder-info", title: "在 Finder 中显示信息", icon: "info.circle") {
                self.showFinderInfo(url)
            },
            .init(id: "package-contents", title: "显示包内容", icon: "shippingbox") {
                self.reveal(url.appendingPathComponent("Contents", isDirectory: true))
            },
            .init(id: "favorite", title: favorite ? "取消收藏" : "添加到收藏",
                  icon: favorite ? "star.fill" : "star", group: 1) { [weak model] in
                model?.toggleFavorite(entry.id)
            },
            .init(id: "copy-path", title: "复制路径", icon: "doc.on.doc", group: 2) { UtilityActions.copy(url.path) },
            .init(id: "copy-name", title: "复制名称", icon: "textformat", group: 2) { UtilityActions.copy(entry.name) },
            .init(id: "copy-bundle-id", title: "复制 Bundle Identifier", icon: "number", group: 2, enabled: bundleID != nil) {
                if let bundleID { UtilityActions.copy(bundleID) }
            },
            .init(id: "command-settings", title: "命令设置", icon: "keyboard", group: 3) { [weak model] in
                model?.openApplicationCommandSettings(path: entry.id)
            },
            .init(id: "extension-settings", title: "扩展设置", icon: "gearshape", group: 3) { [weak model] in
                model?.openSettings(page: "applications")
            },
            .init(id: "reset-ranking", title: "重置优先级", icon: "arrow.counterclockwise", group: 3) { [weak model] in
                model?.resetUsage(for: entry.id)
                self.feedback("已重置「\(entry.name)」的使用频率", style: .success)
            },
            .init(id: "hide-app", title: "隐藏应用", icon: "eye.slash", group: 4, enabled: running) {
                self.apply(to: path, failure: "无法隐藏应用。") { $0.hide() }
            },
            .init(id: "quit-app", title: "退出应用", icon: "rectangle.portrait.and.arrow.right", group: 4, enabled: running) {
                self.apply(to: path, failure: "无法请求应用退出。") { $0.terminate() }
            },
            .init(id: "force-quit-app", title: "强制退出应用", icon: "xmark.octagon", group: 4, enabled: running) {
                self.forceQuit(at: path, name: entry.name)
            },
            // TODO: Add opt-in, per-application inactivity tracking and automatic quit rules.
            .init(id: "auto-quit-app", title: "自动退出（待实现）", icon: "app.badge.clock", group: 4, enabled: false),
            .init(id: "restart-app", title: "重启应用", icon: "arrow.clockwise", group: 4, enabled: running) { [weak model] in
                guard let model else { return }
                self.restart(url, path: path, model: model)
            },
            .init(id: "hide-command", title: "隐藏命令", icon: "eye.slash", group: 4, destructive: true) { [weak model] in
                model?.setApplicationEnabled(false, path: entry.id)
                self.feedback("已隐藏「\(entry.name)」。可在应用程序设置中重新启用。", style: .success)
            },
            // TODO: Confirm the selected bundle and move it to the Trash using NSWorkspace.
            .init(id: "uninstall-app", title: "卸载应用（待实现）", icon: "trash", group: 4, enabled: false, destructive: true)
        ]
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
        (NSApp.delegate as? Delegate)?.toast.show(message, style: style)
    }
}
