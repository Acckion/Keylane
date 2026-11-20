import AppKit
import Carbon
import Darwin
import KeylaneCore

/// Serial browser automation. Every write compares the tab's current URL with
/// the value just observed; restoration never replaces a tab the user changed.
final class FocusBrowser {
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
    }
    struct Redirect: Codable {
        let browser: String
        let pid: Int32
        let original: String
        let blocked: String
    }
    struct Driver {
        var browsers: () -> [(String, Int32)]
        var authorized: (String) -> Bool
        var read: (String) throws -> [Tab]
        var write: (String, Tab, String, String) throws -> Bool
    }
    private let driver: Driver?
    private var loadIssue: String?
    private let queue = DispatchQueue(label: "org.keylane.focus.browser", qos: .utility)
    private let journal: URL
    private var redirects: [Redirect] = []
    private let lock = NSLock()
    private var generation = 0
    private var checkpoint: Int { lock.lock(); defer { lock.unlock() }; return generation }
    private var busy = false

    init(directory: URL, driver: Driver? = nil) {
        self.driver = driver
        journal = directory.appendingPathComponent("browser-recovery.json")
        if FileManager.default.fileExists(atPath: journal.path) {
            do {
                guard (try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8_000_000 else { throw FocusError.storage }
                redirects = try JSONDecoder().decode([Redirect].self, from: Data(contentsOf: journal))
                guard redirects.count <= 4000, redirects.allSatisfy({ record in
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
            for (id, pid) in browsers {
                guard self.checkpoint == ticket else { break }
                guard self.authorized(id) else {
                    notice = "网站屏蔽需要允许 Keylane 自动化控制 \(Self.supported[id] ?? id)。"
                    continue
                }
                do {
                    let tabs = try self.tabs(id)
                    for tab in tabs {
                        guard self.checkpoint == ticket, self.redirects.count < 4000 else { break }
                        guard let url = URL(string: tab.url), let host = url.host,
                              configuration.blocks(website: url, allowAllWebsites: preferences.allowAllWebsites),
                              !snoozes.contains(where: { FocusWebsite.matches(host, rule: $0) }) else { continue }
                        let blocked = try self.blockPage(host: host)
                        let record = Redirect(browser: id, pid: pid, original: tab.url, blocked: blocked.absoluteString)
                        self.redirects.append(record)
                        do {
                            // Persist recovery before redirecting a browser.
                            try self.save()
                            guard self.checkpoint == ticket else { break }
                            if try self.setURL(id, tab: tab, expected: tab.url, replacement: blocked.absoluteString) {
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

    func restore(host: String? = nil, completion: @escaping () -> Void = {}) {
        lock.lock(); generation += 1; lock.unlock()
        guard loadIssue == nil else { completion(); return }
        queue.async { [weak self] in
            guard let self else { return }
            var keep: [Redirect] = []
            var snapshots: [String: [Tab]] = [:]
            var failedBrowsers = Set<String>()
            let running = Set(self.driver?.browsers().map { $0.0 } ?? NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            for record in self.redirects {
                if let host, let url = URL(string: record.original), let originalHost = url.host,
                   !FocusWebsite.matches(originalHost, rule: host) { keep.append(record); continue }
                guard running.contains(record.browser), !failedBrowsers.contains(record.browser) else { keep.append(record); continue }
                do {
                    guard self.authorized(record.browser) else {
                        keep.append(record); continue
                    }
                    if snapshots[record.browser] == nil { snapshots[record.browser] = try self.tabs(record.browser) }
                    var incomplete = false
                    for tab in snapshots[record.browser] ?? [] where tab.url == record.blocked {
                        if try !self.setURL(record.browser, tab: tab, expected: record.blocked, replacement: record.original) { incomplete = true }
                    }
                    if incomplete { keep.append(record) }
                } catch { keep.append(record); failedBrowsers.insert(record.browser) }
            }
            let retained = Set(keep.map(\.blocked))
            for record in self.redirects where !retained.contains(record.blocked) {
                if let url = URL(string: record.blocked), url.isFileURL,
                   url.deletingLastPathComponent() == self.journal.deletingLastPathComponent().appendingPathComponent("Blocked") {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            self.redirects = keep
            try? self.save()
            DispatchQueue.main.async(execute: completion)
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
            if (u) result.push({window:w.id(),index:i,url:u});
          }
        }
        JSON.stringify(result);
        """
        return try JSONDecoder().decode([Tab].self, from: execute(source))
    }
    private func setURL(_ id: String, tab: Tab, expected: String, replacement: String) throws -> Bool {
        if let driver { return try driver.write(id, tab, expected, replacement) }
        let data = try execute("""
        const a = Application(\(Self.literal(id)));
        const windows = a.windows();
        let changed = false;
        for (const w of windows) {
          if (w.id() !== \(tab.window)) continue;
          const tabs = w.tabs();
          const t = tabs[\(tab.index)];
          if (t && t.url() === \(Self.literal(expected))) { t.url = \(Self.literal(replacement)); changed = true; }
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
