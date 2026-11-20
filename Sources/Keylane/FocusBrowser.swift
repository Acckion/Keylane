import AppKit
import Carbon
import Darwin
import KeylaneCore

/// Serial browser automation. Every write compares the tab's current URL with
/// the value just observed; restoration never replaces a tab the user changed.
final class FocusBrowser {
    static let recoveryCapacity = 4_000
    static let supported: [String: String] = [
        "com.apple.Safari": "Safari", "com.google.Chrome": "Chrome",
        "com.microsoft.edgemac": "Edge", "com.brave.Browser": "Brave",
        "com.vivaldi.Vivaldi": "Vivaldi", "com.operasoftware.Opera": "Opera",
        "com.google.Chrome.canary": "Chrome Canary", "org.chromium.Chromium": "Chromium",
        "company.thebrowser.Browser": "Arc"
    ]
    static let unsupported: [String: String] = [
        "org.mozilla.firefox": "Firefox", "org.mozilla.nightly": "Firefox Nightly",
        "app.zen-browser.zen": "Zen", "one.ablaze.floorp": "Floorp", "com.kagi.kagimacOS": "Orion"
    ]
    struct Tab: Codable {
        let window: Int
        let index: Int
        let url: String
        var identity: String? = nil
    }
    struct Redirect: Codable {
        let browser: String
        let pid: Int32
        let original: String
        let blocked: String
        var window: Int? = nil
        var index: Int? = nil
        var identity: String? = nil
        var created: Date? = nil
        var restoreAttempts: Int? = nil
        var nextRestore: Date? = nil
        var suspended: Bool? = nil
    }
    struct RecoveryPolicy {
        var attempts = 20
        var interval: TimeInterval = 2
        var lifetime: TimeInterval = 7 * 24 * 3600
    }
    struct Driver {
        var browsers: () -> [(String, Int32)]
        var authorized: (String) -> Bool
        var read: (String) throws -> [Tab]
        var write: (String, Tab, String, String) throws -> Bool
    }
    private(set) var restorationError: String?
    var onRestorationIssue: ((String?) -> Void)?
    private let driver: Driver?
    private let recovery: RecoveryPolicy
    private var loadIssue: String?
    private let queue = DispatchQueue(label: "org.keylane.focus.browser", qos: .utility)
    private let journal: URL
    private var redirects: [Redirect] = []
    private let lock = NSLock()
    private var generation = 0
    private var checkpoint: Int { lock.lock(); defer { lock.unlock() }; return generation }
    private var busy = false

    init(directory: URL, driver: Driver? = nil, recovery: RecoveryPolicy = .init()) {
        self.driver = driver
        self.recovery = recovery
        journal = directory.appendingPathComponent("browser-recovery.json")
        if FileManager.default.fileExists(atPath: journal.path) {
            do {
                guard (try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw FocusError.storage }
                redirects = try JSONDecoder().decode([Redirect].self, from: Data(contentsOf: journal))
                guard redirects.count <= Self.recoveryCapacity, redirects.allSatisfy({ record in
                    guard let original = URL(string: record.original), let blocked = URL(string: record.blocked) else { return false }
                    return ["http", "https"].contains(original.scheme ?? "") && Self.supported[record.browser] != nil && blocked.isFileURL
                        && blocked.deletingLastPathComponent() == directory.appendingPathComponent("Blocked")
                }) else { throw FocusError.storage }
            } catch { loadIssue = "网站恢复记录读取失败，请先检查专注数据。" }
        }
    }
    static func permission(_ id: String, prompt: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: id)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, 0x636F7265, 0x67657464, prompt)
    }

    func poll(configuration: FocusConfiguration, preferences: FocusPreferences, snoozes: [String],
              report: @escaping (String?, String?) -> Void) {
        if let loadIssue { report(loadIssue, nil); return }
        guard !busy else { return }
        let browsers = driver?.browsers() ?? NSWorkspace.shared.runningApplications.compactMap { app -> (String, Int32)? in
            guard let id = app.bundleIdentifier, Self.supported[id] != nil, !configuration.blocks(application: id) else { return nil }
            return (id, app.processIdentifier)
        }
        guard !browsers.isEmpty else { return }
        busy = true
        let ticket = checkpoint
        queue.async { [weak self] in
            guard let self else { return }
            var notice: String?
            var blockedHost: String?
            browserLoop: for (id, pid) in browsers {
                guard self.checkpoint == ticket else { break }
                guard browsers.filter({ $0.0 == id }).count == 1 else { notice = "浏览器进程身份不唯一，已跳过写入。"; continue }
                guard self.authorized(id) else {
                    notice = "网站屏蔽需要允许 Keylane 自动化控制 \(Self.supported[id] ?? id)。"
                    continue
                }
                do {
                    let tabs = try self.tabs(id)
                    for tab in tabs {
                        guard self.checkpoint == ticket else { break browserLoop }
                        guard let url = URL(string: tab.url), let host = url.host,
                              configuration.blocks(website: url, allowAllWebsites: preferences.allowAllWebsites),
                              !snoozes.contains(where: { FocusWebsite.matches(host, rule: $0) }) else { continue }
                        guard self.redirects.count < Self.recoveryCapacity else {
                            notice = "网页恢复记录已满，不能继续屏蔽。专注已暂停，现有恢复记录已保留。"
                            break browserLoop
                        }
                        guard Self.unique(tab, in: tabs) else {
                            notice = "无法安全识别 \(Self.supported[id] ?? id) 的标签，已跳过网站写入。"
                            continue
                        }
                        let blocked = try self.blockPage(host: host)
                        let record = Redirect(browser: id, pid: pid, original: tab.url, blocked: blocked.absoluteString, window: tab.window, index: tab.index, identity: tab.identity, created: Date())
                        self.redirects.append(record)
                        do {
                            // Persist recovery before redirecting a browser.
                            try self.save()
                            guard self.checkpoint == ticket else { break }
                            if try self.setURL(id, tab: tab, expected: tab.url, replacement: blocked.absoluteString, ticket: ticket, pid: pid) {
                                blockedHost = host
                            } else {
                                self.redirects.removeAll { $0.blocked == blocked.absoluteString }
                                try self.save(); try? FileManager.default.removeItem(at: blocked)
                            }
                        } catch {
                            notice = error.localizedDescription
                        }
                    }
                } catch {
                    if self.driver == nil, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier != id { continue }
                    notice = "无法检查 \(Self.supported[id] ?? id) 的网页，请检查自动化权限。" }
            }
            DispatchQueue.main.async {
                self.busy = false
                if self.checkpoint == ticket { report(notice, blockedHost) }
            }
        }
    }

    func restore(host: String? = nil, report: ((String?) -> Void)? = nil, completion: @escaping () -> Void = {}) {
        lock.lock(); generation += 1; let ticket = generation; lock.unlock()
        guard loadIssue == nil else {
            restorationError = loadIssue; onRestorationIssue?(loadIssue); report?(loadIssue); completion(); return
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.restoreAttempt(host: host, ids: Set(self.redirects.map(\.blocked)), ticket: ticket, report: report, completion: completion)
        }
    }
    private func restoreAttempt(host: String?, ids: Set<String>, ticket: Int, report: ((String?) -> Void)?, completion: @escaping () -> Void) {
        guard checkpoint == ticket else { DispatchQueue.main.async { report?("网页恢复请求已被更新，记录已保留。"); completion() }; return }
        var keep: [Redirect] = []
        var snapshots: [String: [Tab]] = [:]
        var failedBrowsers = Set<String>()
        let running = driver?.browsers() ?? NSWorkspace.shared.runningApplications.compactMap { app -> (String, Int32)? in
            guard let id = app.bundleIdentifier else { return nil }; return (id, app.processIdentifier)
        }
        var retry = false
        var problem: String?
        let now = Date()
        for var record in redirects {
            guard ids.contains(record.blocked) else { keep.append(record); continue }
            if let host, let originalHost = URL(string: record.original)?.host,
               !FocusWebsite.matches(originalHost, rule: host) { keep.append(record); continue }
            record.created = record.created ?? now
            if (record.restoreAttempts ?? 0) >= recovery.attempts || now.timeIntervalSince(record.created!) >= recovery.lifetime {
                // Expiry stops automation, never discards the original URL or marker.
                record.suspended = true
            }
            guard record.suspended != true else { problem = "部分网页未恢复，已停止自动重试；原始网址及屏蔽页记录已保留。"; keep.append(record); continue }
            let processes = running.filter { $0.0 == record.browser }
            guard processes.count == 1 else { problem = "网页等待浏览器恢复；原始网址及屏蔽页记录已保留。"; keep.append(record); continue }
            if let next = record.nextRestore, next > now { problem = "部分网页尚未恢复；已保留记录并等待重试。"; keep.append(record); retry = true; continue }
            record.restoreAttempts = (record.restoreAttempts ?? 0) + 1
            record.nextRestore = now.addingTimeInterval(recovery.interval)
            var restored = false
            do {
                if !failedBrowsers.contains(record.browser), authorized(record.browser) {
                    if snapshots[record.browser] == nil { snapshots[record.browser] = try tabs(record.browser) }
                    let observed = snapshots[record.browser] ?? []
                    let matches = observed.filter { $0.url == record.blocked }
                    if record.identity != nil, matches.count == 1, let tab = matches.first, Self.unique(tab, in: observed) {
                        // In the original process, movement or identity changes invalidate
                        // the locator. After relaunch, only the unique app-owned marker
                        // can rebind to a fresh stable identity, never the original URL.
                        let sameProcess = processes[0].1 == record.pid
                        let originalLocator = record.identity != nil && tab.identity == record.identity && tab.window == record.window && tab.index == record.index
                        if (!sameProcess || originalLocator), checkpoint == ticket {
                            restored = try setURL(record.browser, tab: tab, expected: record.blocked, replacement: record.original, ticket: ticket, pid: processes[0].1)
                        }
                    }
                }
            } catch { failedBrowsers.insert(record.browser) }
            if !restored { problem = "部分网页未恢复，请检查浏览器权限或标签身份；已保留记录并将有限重试。"; keep.append(record); retry = true }
        }
        let retained = Set(keep.map(\.blocked))
        for record in redirects where !retained.contains(record.blocked) {
            if let url = URL(string: record.blocked), url.isFileURL,
               url.deletingLastPathComponent() == journal.deletingLastPathComponent().appendingPathComponent("Blocked") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        redirects = keep
        do { try save() } catch { retry = false; problem = "无法保存网页恢复状态，请检查专注数据。" }
        let result = problem
        DispatchQueue.main.async {
            guard self.checkpoint == ticket else { report?("网页恢复请求已被更新，记录已保留。"); completion(); return }
            if self.restorationError != result { self.restorationError = result; self.onRestorationIssue?(result) }
            report?(result); completion()
        }
        if retry, checkpoint == ticket {
            queue.asyncAfter(deadline: .now() + recovery.interval) { [weak self] in
                self?.restoreAttempt(host: host, ids: ids, ticket: ticket, report: nil, completion: {})
            }
        }
    }

    /// On process exit, give pending restoration a bounded chance to finish.
    /// Remaining entries stay journaled for the next launch.
    @discardableResult func flush(timeout: TimeInterval = 8) -> Bool {
        let completion = DispatchGroup(); completion.enter()
        queue.async { completion.leave() }
        return completion.wait(timeout: .now() + timeout) == .success
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(redirects)
        guard data.count <= 8_000_000 else { throw FocusError.storage }
        try data.write(to: journal, options: .atomic)
    }
    private func blockPage(host: String) throws -> URL {
        let directory = journal.deletingLastPathComponent().appendingPathComponent("Blocked")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent(UUID().uuidString + ".html")
        let escaped = host.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <!doctype html><meta charset="utf-8"><title>Keylane Focus</title>
        <style>body{font:20px system-ui;background:#151918;color:#eee;display:grid;place-content:center;height:90vh;text-align:center}p{color:#aaa}</style>
        <h1>正在专注</h1><p>\(escaped) 已被屏蔽</p><p>可在 Keylane 专注条中临时放行，或暂停本次会话。</p>
        """
        try html.write(to: page, atomically: true, encoding: .utf8)
        return page
    }
    /// Stable ID, original position and unique URL must agree. Legacy records
    /// without identity remain journaled; never infer identity from URL alone.
    static func unique(_ tab: Tab, in tabs: [Tab]) -> Bool {
        guard let identity = tab.identity, !identity.isEmpty else { return false }
        return tabs.filter { $0.identity == identity }.count == 1 && tabs.filter { $0.url == tab.url }.count == 1
    }
    private func authorized(_ id: String) -> Bool { driver?.authorized(id) ?? (Self.permission(id, prompt: false) == noErr) }
    private func tabs(_ id: String) throws -> [Tab] {
        if let driver { return try driver.read(id) }
        let source = """
        const a = Application(\(Self.literal(id)));
        let result = [];
        for (const w of a.windows()) {
          const urls = w.tabs.url();
          for (let i = 0; i < urls.length; i++) {
            const u = urls[i];
            let identity = null, currentURL = u;
            try {
              const value = w.tabs()[i].id();
              if (value !== undefined && value !== null && Number.isFinite(Number(value))) {
                const target = w.tabs.byId(Number(value));
                currentURL = target.url();
                if (String(target.id()) === String(value) && String(w.tabs()[i].id()) === String(value)) identity = String(value);
              }
            } catch (_) {}
            if (currentURL) result.push({window:w.id(),index:i,url:currentURL,identity:identity});
          }
        }
        JSON.stringify(result);
        """
        return try JSONDecoder().decode([Tab].self, from: execute(source))
    }
    private func setURL(_ id: String, tab: Tab, expected: String, replacement: String, ticket: Int, pid: Int32) throws -> Bool {
        guard checkpoint == ticket else { return false }
        let processes = driver?.browsers() ?? NSWorkspace.shared.runningApplications.compactMap { app -> (String, Int32)? in
            guard let id = app.bundleIdentifier else { return nil }; return (id, app.processIdentifier)
        }
        guard processes.filter({ $0.0 == id }).count == 1, processes.contains(where: { $0.0 == id && $0.1 == pid }) else { return false }
        if let driver {
            let latest = try driver.read(id)
            guard checkpoint == ticket, Self.unique(tab, in: latest), latest.contains(where: { $0.identity == tab.identity && $0.window == tab.window && $0.index == tab.index && $0.url == expected }) else { return false }
            return try driver.write(id, tab, expected, replacement)
        }
        let data = try execute("""
        const a = Application(\(Self.literal(id)));
        const windows = a.windows();
        const observed = [];
        for (const w of windows) {
          const tabs = w.tabs();
          for (let i = 0; i < tabs.length; i++) {
            let identity = null;
            try { const value = tabs[i].id(); if (value !== undefined && value !== null) identity = String(value); } catch (_) {}
            observed.push({w:w.id(),i:i,t:tabs[i],identity:identity,url:tabs[i].url()});
          }
        }
        const identity = \(tab.identity.map(Self.literal) ?? "null");
        const matches = observed.filter(x => x.identity === identity);
        const urls = observed.filter(x => x.url === \(Self.literal(expected)));
        let changed = false;
        if (identity !== null && matches.length === 1 && urls.length === 1) {
          const x = matches[0];
          if (x.w === \(tab.window) && x.i === \(tab.index) && x.url === \(Self.literal(expected)) && x.t.url() === \(Self.literal(expected))) {
            let currentID = null; try { currentID = String(x.t.id()); } catch (_) {}
            if (currentID === identity) {
              const w = windows.find(w => w.id() === x.w);
              const target = w.tabs.byId(Number(identity));
              if (String(target.id()) === identity && target.url() === \(Self.literal(expected))) {
                target.url = \(Self.literal(replacement)); changed = true;
              }
            }
          }
        }
        JSON.stringify(changed);
        """)
        return try JSONDecoder().decode(Bool.self, from: data)
    }
    private static func literal(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
    private func execute(_ source: String) throws -> Data {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: timeout)
        defer { timeout.cancel() }
        try input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
        try input.fileHandleForWriting.close()
        var result = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            result.append(chunk)
            if result.count > 4_000_000 {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit(); throw CocoaError(.fileReadTooLarge)
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        return result
    }
}
