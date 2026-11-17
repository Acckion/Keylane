import AppKit
import ScreenCaptureKit

enum KeylaneToolActions {
    static let website = URL(string: "https://acckion.github.io/Keylane/")!
    static let repository = URL(string: "https://github.com/Acckion/Keylane")!
    private static var sharePicker: NSSharingServicePicker?
    private static var isCapturing = false
    private static let defaults = UserDefaults.standard

    static var copiesCapture: Bool {
        get { defaults.object(forKey: "keylaneCapture.copy") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keylaneCapture.copy") }
    }

    static var revealsCapture: Bool {
        get { defaults.bool(forKey: "keylaneCapture.reveal") }
        set { defaults.set(newValue, forKey: "keylaneCapture.reveal") }
    }

    private static var version: String {
        let bundle = Bundle.main
        let release = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "Keylane \(release)（构建 \($0)）" } ?? "Keylane \(release)"
    }

    static func copyVersion() { copy(version, success: "已复制 Keylane 版本") }

    static func copyLogs() {
        guard let logs = try? String(contentsOf: WindowDiagnostics.fileURL, encoding: .utf8) else {
            feedback("没有可复制的 Keylane 日志", success: false)
            return
        }
        copy(logs, success: "已复制 Keylane 日志")
    }

    static func revealLogs() {
        if FileManager.default.fileExists(atPath: WindowDiagnostics.fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([WindowDiagnostics.fileURL])
        } else {
            feedback("没有可显示的 Keylane 日志", success: false)
        }
    }

    static func sendFeedback() {
        (NSApp.delegate as? Delegate)?.hideLauncher()
        let alert = NSAlert()
        alert.messageText = "在 GitHub 提交反馈"
        alert.informativeText = "GitHub Issue 对外公开。可以附上近期窗口诊断，提交前可在 GitHub 检查或移除。"
        alert.addButton(withTitle: "包含诊断并继续")
        alert.addButton(withTitle: "仅继续")
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }

        let logs = choice == .alertFirstButtonReturn ? WindowDiagnostics.recentEventsForFeedback() : nil
        var issue = URLComponents(url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        issue.queryItems = [
            URLQueryItem(name: "template", value: "feedback.yml"),
            URLQueryItem(name: "keylane-version", value: version),
            URLQueryItem(name: "macos-version", value: ProcessInfo.processInfo.operatingSystemVersionString)
        ]
        if let logs {
            issue.queryItems?.append(URLQueryItem(name: "evidence", value: "```json\n\(logs)\n```"))
        }
        if let url = issue.url { open(url) }
    }

    static func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { feedback("无法打开链接", success: false) }
    }

    static func share() {
        guard let delegate = NSApp.delegate as? Delegate else { return }
        if delegate.settingsWindow?.isKeyWindow != true { delegate.revealLauncher() }
        guard let view = (delegate.settingsWindow?.isKeyWindow == true ? delegate.settingsWindow : delegate.window)?.contentView else { return }
        let picker = NSSharingServicePicker(items: [website])
        sharePicker = picker
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view,
                    preferredEdge: .minY)
    }

    static func captureWindow(permission: PermissionFeature) {
        guard !isCapturing, permission.available, let delegate = NSApp.delegate as? Delegate else { return }
        let settings = delegate.settingsWindow
        if settings?.isKeyWindow != true, delegate.window?.isVisible != true { delegate.revealLauncher() }
        guard let window = settings?.isKeyWindow == true ? settings : delegate.window, window.isVisible else {
            feedback("没有可截取的 Keylane 窗口", success: false)
            return
        }
        let number = window.windowNumber
        let scale = window.backingScaleFactor
        isCapturing = true
        Task { @MainActor in
            defer { isCapturing = false }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let ownWindow = content.windows.first(where: {
                    Int($0.windowID) == number && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                }), permission.available else {
                    feedback("无法找到可截取的 Keylane 窗口", success: false)
                    return
                }
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int((ownWindow.frame.width * scale).rounded()))
                configuration.height = max(1, Int((ownWindow.frame.height * scale).rounded()))
                configuration.showsCursor = false
                configuration.ignoreShadowsSingleWindow = true
                let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard permission.available else { return }
                try deliverCapture(image, scale: scale)
            } catch {
                feedback("无法截取或保存 Keylane 窗口", success: false)
            }
        }
    }

    private static func deliverCapture(_ image: CGImage, scale: CGFloat) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        bitmap.size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let copyImage = copiesCapture
        if revealsCapture || !copyImage {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            let url = desktop.appendingPathComponent("Keylane-\(UUID().uuidString.prefix(8)).png")
            try png.write(to: url, options: .atomic)
            if revealsCapture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if copyImage {
            let picture = NSImage(size: bitmap.size)
            picture.addRepresentation(bitmap)
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.writeObjects([picture]) else { throw CocoaError(.fileWriteUnknown) }
        }
        feedback(copyImage ? "已复制 Keylane 窗口" : "已将 Keylane 窗口保存到桌面", success: true)
    }

    private static func copy(_ text: String, success: String) {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(text, forType: .string)
        feedback(copied ? success : "无法写入剪贴板", success: copied)
    }

    private static func feedback(_ message: String, success: Bool) {
        (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: success ? .success : .failure)
    }
}
