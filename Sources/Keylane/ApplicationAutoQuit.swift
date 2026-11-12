import AppKit
import Combine
import CoreAudio
import CoreMediaIO

final class ApplicationAutoQuit: ObservableObject {
    struct Rule: Codable {
        let bundleID: String
        let minutes: Int?
    }

    private struct Inactivity {
        let application: NSRunningApplication
        let since: TimeInterval
        var requested = false
    }

    static let intervals = [1, 3, 5, 10, 15, 30, 60, 120]
    static let useDefault = -1
    private static let defaultKey = "applicationAutoQuitDefaultMinutes"
    private static let key = "applicationAutoQuitRules"
    @Published private(set) var rules: [String: Rule]
    @Published private(set) var defaultMinutes: Int
    private let defaults: UserDefaults
    private let workspace = NSWorkspace.shared
    private var observations: [NSObjectProtocol] = []
    private var timer: Timer?
    private let protectionQueue = DispatchQueue(label: "org.keylane.applications.auto-quit.protection", qos: .utility)
    private var protectionRequest: DispatchWorkItem?
    private var checkAgain = false
    private var inactivity: [pid_t: Inactivity] = [:]
    private var sessionActive = true
    private var sleeping = false
    private let uptime: () -> TimeInterval
    private let protection: () -> ApplicationAutoQuitProtection
    private var enabled: () -> Bool = { false }

    init(defaults: UserDefaults = .standard, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         protection: @escaping () -> ApplicationAutoQuitProtection = ApplicationAutoQuitProtection.current) {
        self.defaults = defaults
        self.uptime = uptime
        self.protection = protection
        let savedDefault = defaults.integer(forKey: Self.defaultKey)
        defaultMinutes = Self.intervals.contains(savedDefault) ? savedDefault : 3
        rules = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: Rule].self, from: $0) } ?? [:]
    }

    func canConfigure(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath()
        guard let id = Bundle(url: path)?.bundleIdentifier else { return false }
        return id != Bundle.main.bundleIdentifier && id != "com.apple.finder"
    }

    func minutes(for url: URL) -> Int {
        let url = url.resolvingSymlinksInPath()
        guard let rule = rules[url.path], rule.bundleID == Bundle(url: url)?.bundleIdentifier,
              rule.minutes.map(Self.intervals.contains) ?? true else { return 0 }
        return rule.minutes ?? Self.useDefault
    }

    func setDefaultMinutes(_ minutes: Int) {
        guard Self.intervals.contains(minutes), minutes != defaultMinutes else { return }
        cancelProtectionCheck()
        defaultMinutes = minutes
        defaults.set(minutes, forKey: Self.defaultKey)
        inactivity = inactivity.filter {
            guard let path = $0.value.application.bundleURL?.resolvingSymlinksInPath().path else { return false }
            return rules[path]?.minutes != nil || $0.value.requested
        }
        updateTimer()
    }

    func setMinutes(_ minutes: Int, for url: URL) {
        let url = url.resolvingSymlinksInPath()
        if minutes == 0 {
            removeRule(at: url.path)
            return
        }
        guard (minutes == Self.useDefault || Self.intervals.contains(minutes)), canConfigure(url),
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        rules[url.path] = Rule(bundleID: id, minutes: minutes == Self.useDefault ? nil : minutes)
        rulesChanged(at: url.path)
    }

    func removeRule(at path: String) {
        guard rules.removeValue(forKey: path) != nil else { return }
        rulesChanged(at: path)
    }

    private func rulesChanged(at path: String) {
        cancelProtectionCheck()
        defaults.set(try? JSONEncoder().encode(rules), forKey: Self.key)
        inactivity = inactivity.filter {
            $0.value.application.bundleURL?.resolvingSymlinksInPath().path != path
                || (rules[path] != nil && $0.value.requested)
        }
        updateTimer()
    }

    func start(enabled: @escaping () -> Bool) {
        guard observations.isEmpty else { return }
        self.enabled = enabled
        let center = workspace.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    self?.inactivity.removeValue(forKey: app.processIdentifier)
                }
                self?.check()
            })
        }
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                self.cancelProtectionCheck()
                self.inactivity.removeAll()
                switch notification.name {
                case NSWorkspace.willSleepNotification: self.sleeping = true
                case NSWorkspace.didWakeNotification: self.sleeping = false
                case NSWorkspace.sessionDidResignActiveNotification: self.sessionActive = false
                default: self.sessionActive = true
                }
            })
        }
        updateTimer()
    }

    func stop() {
        cancelProtectionCheck()
        timer?.invalidate()
        timer = nil
        for observation in observations { workspace.notificationCenter.removeObserver(observation) }
        observations.removeAll()
        inactivity.removeAll()
        enabled = { false }
    }

    private func cancelProtectionCheck() {
        protectionRequest?.cancel()
        protectionRequest = nil
        checkAgain = false
    }

    private func updateTimer() {
        guard !observations.isEmpty, !rules.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }
        if timer == nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        check()
    }

    func check() {
        guard sessionActive, !sleeping, enabled(), !rules.isEmpty,
              let foregroundPID = workspace.frontmostApplication?.processIdentifier else {
            cancelProtectionCheck()
            inactivity.removeAll()
            return
        }
        if protectionRequest != nil {
            checkAgain = true
            return
        }
        let configuredBundleIDs = Set(rules.values.map(\.bundleID))
        let candidates = workspace.runningApplications.compactMap { app -> (NSRunningApplication, URL, Int)? in
            guard app.activationPolicy == .regular, !app.isTerminated, app.processIdentifier != foregroundPID,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundleID = app.bundleIdentifier, bundleID != "com.apple.finder", configuredBundleIDs.contains(bundleID),
                  let url = app.bundleURL?.resolvingSymlinksInPath(), let rule = rules[url.path],
                  rule.bundleID == bundleID, rule.minutes.map(Self.intervals.contains) ?? true else { return nil }
            return (app, url, rule.minutes ?? defaultMinutes)
        }
        let running = Set(candidates.map { $0.0.processIdentifier })
        inactivity = inactivity.filter { running.contains($0.key) }
        guard !candidates.isEmpty else { return }
        let request = DispatchWorkItem {}
        protectionRequest = request
        let protection = self.protection
        let now = uptime()
        protectionQueue.async { [weak self] in
            guard !request.isCancelled else { return }
            let media = protection()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.protectionRequest === request else { return }
                self.protectionRequest = nil
                let repeatCheck = self.checkAgain
                self.checkAgain = false
                self.apply(media, to: candidates, at: now)
                if repeatCheck { self.check() }
            }
        }
    }

    private func apply(_ media: ApplicationAutoQuitProtection, to candidates: [(NSRunningApplication, URL, Int)],
                       at now: TimeInterval) {
        guard sessionActive, !sleeping, enabled(),
              let foregroundPID = workspace.frontmostApplication?.processIdentifier else { return }
        for (app, url, minutes) in candidates {
            let pid = app.processIdentifier
            guard !app.isTerminated, !app.isActive, pid != foregroundPID else { continue }
            if media.protects(pid: pid, bundleID: app.bundleIdentifier) {
                if inactivity[pid]?.requested != true { inactivity.removeValue(forKey: pid) }
                continue
            }
            if inactivity[pid]?.application != app {
                inactivity[pid] = Inactivity(application: app, since: now)
            }
            guard var state = inactivity[pid], !state.requested,
                  now - state.since >= TimeInterval(minutes * 60),
                  !app.isActive, workspace.frontmostApplication?.processIdentifier != pid else { continue }
            state.requested = true
            inactivity[pid] = state
            if !app.terminate() {
                (NSApp.delegate as? Delegate)?.toast.show("无法自动退出「\(app.localizedName ?? url.lastPathComponent)」。", style: .failure)
            }
        }
    }
}


struct ApplicationAutoQuitProtection {
    var recording = false
    var outputPIDs: Set<pid_t> = []
    var outputBundleIDs: Set<String> = []

    func protects(pid: pid_t, bundleID: String?) -> Bool {
        if recording { return true }
        guard let bundleID, ["com.apple.Music", "com.spotify.client"].contains(bundleID) else { return false }
        return outputPIDs.contains(pid) || outputBundleIDs.contains {
            $0 == bundleID || $0.hasPrefix(bundleID + ".")
        }
    }

    static func current() -> Self {
        var result = Self(recording: cameraInUse())
        for process in (try? AudioHardwareSystem.shared.processes) ?? [] {
            if (try? process.isRunningInput) == true { result.recording = true }
            guard (try? process.isRunningOutput) == true else { continue }
            if let pid = try? process.pid { result.outputPIDs.insert(pid) }
            if let bundleID = try? process.bundleID { result.outputBundleIDs.insert(bundleID) }
        }
        return result
    }

    private static func cameraInUse() -> Bool {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyDevices),
                                                mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
                                                mElement: UInt32(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<CMIOObjectID>.stride else { return false }
        var devices = Array(repeating: CMIOObjectID(0), count: Int(size) / MemoryLayout<CMIOObjectID>.stride)
        var used: UInt32 = 0
        let status = devices.withUnsafeMutableBytes {
            CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, $0.baseAddress!)
        }
        guard status == noErr else { return false }
        address.mSelector = UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            var bytesRead: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &address, 0, nil, 4, &bytesRead, &running) == noErr && running != 0
        }
    }
}
