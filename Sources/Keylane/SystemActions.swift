import AppKit
import ApplicationServices
import AudioToolbox
import Carbon.HIToolbox
import CoreAudio
import IOKit.hidsystem

enum SystemActions {
    enum PowerAction: String {
        case sleep = "sleepnow"
        case sleepDisplays = "displaysleepnow"

        var failureMessage: String {
            switch self {
            case .sleep: "macOS 未能让 Mac 进入睡眠。"
            case .sleepDisplays: "macOS 未能让显示器进入睡眠。"
            }
        }
    }

    private static var delegate: Delegate? { NSApp?.delegate as? Delegate }

    enum AutomationAction {
        case emptyTrash, logOut, restart, shutDown, appearance

        var title: String {
            switch self {
            case .emptyTrash: "清空废纸篓"
            case .logOut: "注销"
            case .restart: "重启 Mac"
            case .shutDown: "关机"
            case .appearance: "切换系统外观"
            }
        }

        var confirmation: String? {
            switch self {
            case .emptyTrash: "废纸篓中的文件会被永久删除。"
            case .logOut, .restart, .shutDown: "macOS 会尝试关闭应用，应用可能提示保存文稿。"
            case .appearance: nil
            }
        }

        var script: String {
            switch self {
            case .emptyTrash: #"tell application id "com.apple.finder" to empty trash"#
            case .logOut: #"tell application id "com.apple.systemevents" to log out"#
            case .restart: #"tell application id "com.apple.systemevents" to restart"#
            case .shutDown: #"tell application id "com.apple.systemevents" to shut down"#
            case .appearance: """
                tell application id "com.apple.systemevents"
                    tell appearance preferences
                        set dark mode to not dark mode
                    end tell
                end tell
                """
            }
        }
    }

    static func runAutomation(_ action: AutomationAction) {
        if let confirmation = action.confirmation {
            delegate?.hideLauncher()
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "\(action.title)？"
            alert.informativeText = confirmation
            alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: action.title)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        var error: NSDictionary?
        guard let script = NSAppleScript(source: action.script) else {
            feedback("无法\(action.title)。", style: .failure)
            return
        }
        script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String
            feedback(message ?? "无法\(action.title)。", style: .failure)
        } else if action == .emptyTrash || action == .appearance {
            feedback(action == .emptyTrash ? "已清空废纸篓。" : "已切换系统外观。", style: .success)
        }
    }

    static func openTrash() {
        let trash = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path).appendingPathComponent(".Trash")
        if NSWorkspace.shared.open(trash) { delegate?.hideLauncher() }
        else { feedback("无法打开废纸篓。", style: .failure) }
    }

    static func ejectAllDisks() {
        let keys: [URLResourceKey] = [.volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeLocalizedNameKey]
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            let targets = volumes.compactMap { url -> (URL, String)? in
                guard url.path != "/", let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.volumeIsInternal != true,
                      values.volumeIsEjectable == true || values.volumeIsRemovable == true else { return nil }
                return (url, values.volumeLocalizedName ?? url.lastPathComponent)
            }
            var failed: [String] = []
            for (url, name) in targets {
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
                catch { failed.append(name) }
            }
            DispatchQueue.main.async {
                if targets.isEmpty { feedback("没有可推出的磁盘。") }
                else if failed.isEmpty { feedback("已推出外部磁盘。", style: .success) }
                else { feedback("无法推出 \(failed.joined(separator: "、"))。", style: .failure) }
            }
        }
    }

    static func showScreenSaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app", isDirectory: true)
        delegate?.hideLauncher()
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { DispatchQueue.main.async { feedback(error.localizedDescription, style: .failure) } }
        }
    }

    enum MediaKey {
        case playPause, next, previous, volumeUp, volumeDown

        var code: Int32 {
            switch self {
            case .playPause: NX_KEYTYPE_PLAY
            case .next: NX_KEYTYPE_FAST
            case .previous: NX_KEYTYPE_REWIND
            case .volumeUp: NX_KEYTYPE_SOUND_UP
            case .volumeDown: NX_KEYTYPE_SOUND_DOWN
            }
        }
    }

    static func postMediaKey(_ key: MediaKey, hideLauncher: Bool = true) {
        guard CGPreflightPostEventAccess() else {
            feedback("媒体快捷键需要辅助功能权限。", style: .failure)
            return
        }
        let events = [0xA00, 0xB00].compactMap { phase in
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
                               data1: Int(key.code) << 16 | phase, data2: -1)?.cgEvent
        }
        guard events.count == 2 else { feedback("无法发送媒体快捷键。", style: .failure); return }
        if hideLauncher { delegate?.hideLauncher() }
        events.forEach { ModifierShortcuts.postWithoutHyperRemapping($0) }
    }

    static func showDesktop() {
        delegate?.hideLauncher()
        if !postShortcut(CGKeyCode(kVK_F11), flags: .maskSecondaryFn) {
            feedback("无法发送显示桌面的系统快捷键。", style: .failure)
        }
    }

    static func toggleHiddenFiles() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            feedback("Finder 当前不可用。", style: .failure)
            return
        }
        delegate?.hideLauncher()
        finder.activate()
        sendFinderShortcut(finder, attempts: 8)
    }

    private static func sendFinderShortcut(_ finder: NSRunningApplication, attempts: Int) {
        if finder.isActive {
            if !postShortcut(CGKeyCode(kVK_ANSI_Period), flags: [.maskCommand, .maskShift]) {
                feedback("无法发送 Finder 的隐藏文件快捷键。", style: .failure)
            }
        } else if attempts > 0 && !finder.isTerminated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { sendFinderShortcut(finder, attempts: attempts - 1) }
        } else {
            feedback("无法将 Finder 切到前台。", style: .failure)
        }
    }

    static func postShortcut(_ key: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard CGPreflightPostEventAccess(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = flags
            ModifierShortcuts.postWithoutHyperRemapping(event)
        }
        return true
    }

    @discardableResult
    static func setOutputVolume(_ percent: Int) -> Bool {
        guard SystemOutputVolume.set(percent) else {
            feedback("当前音频输出设备不支持系统音量调节。", style: .failure)
            return false
        }
        feedback("音量已设为 \(percent)%。", style: .success)
        return true
    }

    static func requestPowerAction(_ action: PowerAction) {
        delegate?.hideLauncher()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = [action.rawValue]
        process.terminationHandler = { task in
            guard task.terminationReason != .exit || task.terminationStatus != 0 else { return }
            DispatchQueue.main.async { feedback(action.failureMessage, style: .failure) }
        }
        do {
            try process.run()
        } catch {
            feedback(action.failureMessage, style: .failure)
        }
    }

    static func lockScreen() {
        guard CGPreflightPostEventAccess() else {
            feedback("锁定屏幕需要辅助功能权限。请在 Keylane 设置的「权限」中授权。", style: .failure)
            return
        }
        let key = CGKeyCode(kVK_ANSI_Q)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
            feedback("无法发送锁屏快捷键。", style: .failure)
            return
        }
        down.flags = [.maskControl, .maskCommand]
        up.flags = down.flags
        delegate?.hideLauncher()
        ModifierShortcuts.postWithoutHyperRemapping(down)
        ModifierShortcuts.postWithoutHyperRemapping(up)
    }

    static func hideOtherApplications() {
        // Invoking from the launcher can make Keylane the frontmost process.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmost = NSWorkspace.shared.frontmostApplication
        let keep = frontmost?.processIdentifier == ownPID ? delegate?.previousApplication : frontmost
        guard let keep, !keep.isTerminated, keep.activationPolicy == .regular else {
            feedback("找不到要保留的前台应用。", style: .failure)
            return
        }
        let apps = regularApplications.filter { $0.processIdentifier != keep.processIdentifier && !$0.isHidden }
        delegate?.hideLauncher()
        changeVisibility(of: apps, hidden: true)
        keep.activate()
    }

    static func unhideApplications() {
        let apps = regularApplications.filter(\.isHidden)
        delegate?.hideLauncher()
        changeVisibility(of: apps, hidden: false)
    }

    static func quitApplications(keepingFrontmost: Bool) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? delegate?.previousApplication : frontmost
        if keepingFrontmost, target == nil || target?.isTerminated == true || target?.activationPolicy != .regular {
            feedback("找不到要保留的前台应用。", style: .failure)
            return
        }
        let applications = regularApplications.filter {
            $0.bundleIdentifier != "com.apple.finder"
                && (!keepingFrontmost || $0.processIdentifier != target?.processIdentifier)
        }
        guard !applications.isEmpty else {
            feedback("没有需要退出的应用。", style: .neutral)
            return
        }
        delegate?.hideLauncher()
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = keepingFrontmost ? "退出其他应用？" : "退出所有应用？"
        let names = applications.compactMap(\.localizedName).prefix(8).joined(separator: "、")
        alert.informativeText = "将请求 \(applications.count) 个应用正常退出。应用可能提示保存。\n\n" + names
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "退出应用")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        for application in applications where !application.isTerminated { application.terminate() }
        awaitApplicationExit(applications, deadline: ProcessInfo.processInfo.systemUptime + 15)
    }

    private static func awaitApplicationExit(_ applications: [NSRunningApplication], deadline: TimeInterval) {
        let remaining = applications.filter { !$0.isTerminated }
        if remaining.isEmpty {
            feedback("已退出 \(applications.count) 个应用。", style: .success)
        } else if ProcessInfo.processInfo.systemUptime >= deadline {
            feedback("已退出 \(applications.count - remaining.count) 个应用，\(remaining.count) 个仍在运行。请检查保存提示。", style: .failure)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                awaitApplicationExit(applications, deadline: deadline)
            }
        }
    }

    private static var regularApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated &&
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
    }

    private static func changeVisibility(of apps: [NSRunningApplication], hidden: Bool) {
        let verb = hidden ? "隐藏" : "显示"
        guard !apps.isEmpty else {
            feedback("没有需要\(verb)的应用。")
            return
        }
        for app in apps {
            if hidden { app.hide() }
            else { app.unhide() }
        }
        // AppKit can deliver the visibility change after returning from hide/unhide.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let count = apps.filter { !$0.isTerminated && $0.isHidden == hidden }.count
            if count == apps.count {
                feedback("已\(verb) \(count) 个应用。", style: .success)
            } else {
                feedback("已\(verb) \(count) 个应用，\(apps.count - count) 个应用未响应。", style: .failure)
            }
        }
    }

    static func toggleOutputMute() {
        let outcome = SystemOutputMute.toggle()
        switch outcome {
        case .muted:
            feedback("已静音。", style: .success)
        case .unmuted:
            feedback("已取消静音。", style: .success)
        case .unsupported:
            feedback("当前音频输出设备不支持系统静音。", style: .failure)
        case .failed:
            feedback("无法更改当前音频输出的静音状态。", style: .failure)
        }
    }

    static func feedback(_ message: String, style: ToastStyle = .neutral) {
        delegate?.showLauncherFeedback(message, style: style)
    }
}

enum SystemOutputMute {
    enum Outcome { case muted, unmuted, unsupported, failed }

    static func toggle() -> Outcome {
        guard let device = SystemOutputVolume.defaultDevice() else { return .failed }

        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var writable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &muteAddress),
              AudioObjectIsPropertySettable(device, &muteAddress, &writable) == noErr,
              writable.boolValue else { return .unsupported }

        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) == noErr else { return .failed }
        mute = mute == 0 ? 1 : 0
        guard AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &mute) == noErr else { return .failed }
        return mute == 0 ? .unmuted : .muted
    }
}

enum SystemOutputVolume {
    static func defaultDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func writableAddress(for device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var writable = DarwinBoolean(false)
            if AudioObjectHasProperty(device, &address),
               AudioObjectIsPropertySettable(device, &address, &writable) == noErr, writable.boolValue { return address }
        }
        return nil
    }

    static func current() -> Int? {
        guard let device = defaultDevice(), var address = writableAddress(for: device) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
              value.isFinite, (0...1).contains(value) else { return nil }
        return Int((value * 100).rounded())
    }

    static func set(_ percent: Int) -> Bool {
        guard (0...100).contains(percent), let device = defaultDevice(), var address = writableAddress(for: device) else { return false }
        var value = Float32(percent) / 100
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}
