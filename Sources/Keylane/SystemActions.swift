import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio

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

    private static var delegate: Delegate? { NSApp.delegate as? Delegate }

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

    private static func feedback(_ message: String, style: ToastStyle = .neutral) {
        delegate?.showLauncherFeedback(message, style: style)
    }
}

enum SystemOutputMute {
    enum Outcome { case muted, unmuted, unsupported, failed }

    static func toggle() -> Outcome {
        var outputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil,
                                         &size, &device) == noErr, device != kAudioObjectUnknown else { return .failed }

        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var writable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &muteAddress),
              AudioObjectIsPropertySettable(device, &muteAddress, &writable) == noErr,
              writable.boolValue else { return .unsupported }

        var mute: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &mute) == noErr else { return .failed }
        mute = mute == 0 ? 1 : 0
        guard AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &mute) == noErr else { return .failed }
        return mute == 0 ? .unmuted : .muted
    }
}
