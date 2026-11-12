import AppKit
import Combine

final class ApplicationAutoQuit: ObservableObject {
    struct Rule: Codable {
        let bundleID: String
        let minutes: Int
    }

    private struct Inactivity {
        let application: NSRunningApplication
        let since: TimeInterval
        var requested = false
    }

    static let intervals = [5, 10, 15, 30, 60, 120]
    private static let key = "applicationAutoQuitRules"
    @Published private(set) var rules: [String: Rule]
    private let defaults: UserDefaults
    private let workspace = NSWorkspace.shared
    private var observations: [NSObjectProtocol] = []
    private var timer: Timer?
    private var inactivity: [pid_t: Inactivity] = [:]
    private var sessionActive = true
    private var sleeping = false
    private let uptime: () -> TimeInterval
    private var enabled: () -> Bool = { false }

    init(defaults: UserDefaults = .standard, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.uptime = uptime
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
              Self.intervals.contains(rule.minutes) else { return 0 }
        return rule.minutes
    }

    func setMinutes(_ minutes: Int, for url: URL) {
        let url = url.resolvingSymlinksInPath()
        if minutes == 0 {
            removeRule(at: url.path)
            return
        }
        guard Self.intervals.contains(minutes), canConfigure(url),
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        rules[url.path] = Rule(bundleID: id, minutes: minutes)
        rulesChanged(at: url.path)
    }

    func removeRule(at path: String) {
        guard rules.removeValue(forKey: path) != nil else { return }
        rulesChanged(at: path)
    }

    private func rulesChanged(at path: String) {
        defaults.set(try? JSONEncoder().encode(rules), forKey: Self.key)
        inactivity = inactivity.filter { $0.value.application.bundleURL?.resolvingSymlinksInPath().path != path }
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
        timer?.invalidate()
        timer = nil
        for observation in observations { workspace.notificationCenter.removeObserver(observation) }
        observations.removeAll()
        inactivity.removeAll()
        enabled = { false }
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
            inactivity.removeAll()
            return
        }
        let now = uptime()
        let candidates = workspace.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != foregroundPID
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleIdentifier != "com.apple.finder"
        }
        let running = Set(candidates.map(\.processIdentifier))
        inactivity = inactivity.filter { running.contains($0.key) }
        for app in candidates {
            let pid = app.processIdentifier
            guard let url = app.bundleURL?.resolvingSymlinksInPath(), let rule = rules[url.path],
                  rule.bundleID == app.bundleIdentifier, Self.intervals.contains(rule.minutes) else {
                inactivity.removeValue(forKey: pid)
                continue
            }
            if inactivity[pid]?.application != app {
                inactivity[pid] = Inactivity(application: app, since: now)
            }
            guard var state = inactivity[pid], !state.requested,
                  now - state.since >= TimeInterval(rule.minutes * 60),
                  !app.isActive, workspace.frontmostApplication?.processIdentifier != pid else { continue }
            state.requested = true
            inactivity[pid] = state
            if !app.terminate() {
                (NSApp.delegate as? Delegate)?.toast.show("无法自动退出「\(app.localizedName ?? url.lastPathComponent)」。", style: .failure)
            }
        }
    }
}
