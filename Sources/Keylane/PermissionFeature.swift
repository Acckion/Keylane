import AppKit
import AVFoundation
import Carbon
import Combine
import Contacts
import EventKit

struct SettingsPermissionStatus: Equatable {
    var requesting = false
    var message: String? = nil
}

/// Persists the user's opt-in independently of the OS permission.
final class PermissionFeature {
    struct Authorization {
        /// nil means the target is unavailable for a passive check.
        let check: () -> Bool?
        let request: (@escaping (Bool) -> Void) -> Void
        let guidance: String
        var checkWhenTargetUnavailable: ((@escaping (Bool) -> Void) -> Void)?
        var enableOnReturn = false
        var privacyPane: String?
    }

    @Published private(set) var enabled: Bool
    @Published private var status = SettingsPermissionStatus()
    private let authorization: Authorization
    private let defaults: UserDefaults
    private let key: String
    private var revision = 0
    private var awaitingPermission = false
    private var activation: AnyCancellable?

    init(_ key: String, authorization: Authorization, defaults: UserDefaults = .standard) {
        self.key = key
        self.authorization = authorization
        self.defaults = defaults
        enabled = defaults.bool(forKey: key) && authorization.check() != false
        if !enabled && defaults.bool(forKey: key) { defaults.set(false, forKey: key) }
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.recheck() }
    }

    var available: Bool { enabled && authorization.check() != false }
    var updates: AnyPublisher<Void, Never> {
        $enabled.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
    }
    var settingsStatus: AnyPublisher<SettingsPermissionStatus, Never> { $status.removeDuplicates().eraseToAnyPublisher() }
    var guidance: String { authorization.guidance }
    var requesting: Bool { status.requesting }
    var canOpenPrivacySettings: Bool { authorization.privacyPane != nil }

    func openPrivacySettings() {
        guard let pane = authorization.privacyPane,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else { return }
        // A manual settings visit can finish the enable request. It does not
        // resume the earlier command after a potentially long interruption.
        if !enabled { awaitingPermission = true }
        NSWorkspace.shared.open(url)
    }

    func verifyForUse(_ completion: @escaping (Bool) -> Void) {
        guard enabled else { completion(false); return }
        if let current = authorization.check() {
            if !current { recheck() }
            completion(current)
            return
        }
        guard let check = authorization.checkWhenTargetUnavailable else { completion(false); return }
        let ticket = revision
        check { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.revision == ticket, self.enabled else { completion(false); return }
                if !allowed { self.recheck() }
                completion(allowed)
            }
        }
    }

    func setEnabled(_ value: Bool) {
        if value {
            activate { _ in }
        } else {
            revision += 1
            awaitingPermission = false
            status = .init()
            persist(false)
        }
    }

    func activate(_ completion: @escaping (Bool) -> Void) {
        if enabled && available { completion(true); return }
        guard !status.requesting else { completion(false); return }
        revision += 1
        let ticket = revision
        awaitingPermission = false
        if authorization.check() == true {
            status = .init()
            persist(true)
            completion(true)
            return
        }
        if enabled { persist(false) }
        status = .init(requesting: true)
        authorization.request { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.revision == ticket else { return }
                let confirmed = self.authorization.check() ?? granted
                self.awaitingPermission = !confirmed && self.authorization.enableOnReturn
                self.status = confirmed ? .init() : .init(message: self.authorization.guidance)
                self.persist(confirmed)
                completion(confirmed)
            }
        }
    }

    func recheck() {
        guard !status.requesting, enabled || awaitingPermission,
              let permitted = authorization.check() else { return }
        if permitted {
            awaitingPermission = false
            status = .init()
            persist(true)
        } else if enabled {
            status = .init(message: authorization.guidance)
            persist(false)
        }
    }

    private func persist(_ value: Bool) {
        if enabled != value { enabled = value }
        if defaults.bool(forKey: key) != value { defaults.set(value, forKey: key) }
    }
}

extension PermissionFeature.Authorization {
    static var calendar: Self {
        .init(check: { EKEventStore.authorizationStatus(for: .event) == .fullAccess }, request: { complete in
            switch EKEventStore.authorizationStatus(for: .event) {
            case .notDetermined, .writeOnly:
                let store = EKEventStore()
                store.requestFullAccessToEvents { [store] allowed, _ in
                    withExtendedLifetime(store) { complete(allowed) }
                }
            default: complete(EKEventStore.authorizationStatus(for: .event) == .fullAccess)
            }
        }, guidance: "请在「系统设置 → 隐私与安全性 → 日历」允许 Keylane 完全访问。", privacyPane: "Calendars")
    }

    static var contacts: Self {
        .init(check: { CNContactStore.authorizationStatus(for: .contacts) == .authorized }, request: { complete in
            if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
                CNContactStore().requestAccess(for: .contacts) { allowed, _ in complete(allowed) }
            } else {
                complete(CNContactStore.authorizationStatus(for: .contacts) == .authorized)
            }
        }, guidance: "请在「系统设置 → 隐私与安全性 → 联系人」允许 Keylane 访问。", privacyPane: "Contacts")
    }

    static var camera: Self {
        .init(check: { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }, request: { complete in
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video, completionHandler: complete)
            } else {
                complete(AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
            }
        }, guidance: "请在「系统设置 → 隐私与安全性 → 相机」允许 Keylane 访问。", privacyPane: "Camera")
    }

    static var accessibility: Self {
        .init(check: { AXIsProcessTrusted() }, request: { complete in
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            complete(AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary))
        }, guidance: "请在「系统设置 → 隐私与安全性 → 辅助功能」允许 Keylane 访问，然后返回 Keylane。", enableOnReturn: true, privacyPane: "Accessibility")
    }

    static var persistentClipboard: Self {
        .init(check: { NSPasteboard.general.accessBehavior == .alwaysAllow }, request: { complete in
            let board = NSPasteboard.general
            if board.accessBehavior == .default || board.accessBehavior == .ask {
                // Request read access without storing the contents in history.
                _ = board.types
            }
            complete(board.accessBehavior == .alwaysAllow)
        }, guidance: "请在「系统设置 → 隐私与安全性 → 剪贴板」选择始终允许 Keylane 读取，然后返回 Keylane。", enableOnReturn: true, privacyPane: "Pasteboard")
    }

    static var postEvent: Self {
        .init(check: { CGPreflightPostEventAccess() }, request: { complete in complete(CGRequestPostEventAccess()) },
              guidance: "请在「系统设置 → 隐私与安全性 → 辅助功能」允许 Keylane 发送键盘事件。", enableOnReturn: true, privacyPane: "Accessibility")
    }

    static var screenCapture: Self {
        .init(check: { CGPreflightScreenCaptureAccess() }, request: { complete in complete(CGRequestScreenCaptureAccess()) },
              guidance: "请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」允许 Keylane 访问。", enableOnReturn: true, privacyPane: "ScreenCapture")
    }

    static func automation(_ bundleID: String, appName: String) -> Self {
        func permission(prompt: Bool) -> OSStatus {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            // core/getd is the Apple Event used for the permission probe.
            return AEDeterminePermissionToAutomateTarget(target.aeDesc, 0x636F7265, 0x67657464, prompt)
        }
        func request(prompt: Bool, _ complete: @escaping (Bool) -> Void) {
            let ask = {
                DispatchQueue.global(qos: .userInitiated).async { complete(permission(prompt: prompt) == noErr) }
            }
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                ask()
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                    if app != nil { ask() }
                    else { complete(false) }
                }
            } else {
                complete(false)
            }
        }
        return .init(check: {
            let result = permission(prompt: false)
            return result == procNotFound ? nil : result == noErr
        }, request: { request(prompt: true, $0) },
        guidance: "请在「系统设置 → 隐私与安全性 → 自动化」允许 Keylane 控制\(appName)。",
        checkWhenTargetUnavailable: { request(prompt: false, $0) }, privacyPane: "Automation")
    }
}
