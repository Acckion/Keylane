// Synthetic transports only. No Model/Delegate, real apps, browsers, Focus or TCC requests.
setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory); app.finishLaunching()
let root = FileManager.default.temporaryDirectory.appendingPathComponent("FocusSafety-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let suite = "org.keylane.focus.safety." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defaults.set(true, forKey: "focus.enabled")
let registry = MenuBarRegistry(preferences: defaults)
defer { registry.shutdown(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message); print("PASS " + message) }
func until(_ ready: () -> Bool) {
    let end = Date().addingTimeInterval(5)
    while !ready() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(ready(), "Synthetic operation timed out")
}
final class Fake {
    let lock = NSLock()
    var tabs: [FocusBrowser.Tab] = []
    var processes: [(String, Int32)] = [("com.apple.Safari", 1)]
    var writes = 0, reads = 0
    var failRead = false
    var onRead: (() -> Void)?
    func read() -> [FocusBrowser.Tab] {
        lock.lock(); reads += 1; let snapshot = tabs, hook = onRead; onRead = nil; lock.unlock()
        hook?(); return snapshot
    }
    func change(_ body: (Fake) -> Void) { lock.lock(); defer { lock.unlock() }; body(self) }
    func snapshot() -> [FocusBrowser.Tab] { lock.lock(); defer { lock.unlock() }; return tabs }
    var driver: FocusBrowser.Driver {
        .init(browsers: { self.lock.lock(); defer { self.lock.unlock() }; return self.processes }, authorized: { _ in true },
              read: { _ in
            self.lock.lock(); let fail = self.failRead; self.lock.unlock()
            if fail { throw CocoaError(.executableRuntimeMismatch) }
            return self.read()
        }, write: { _, tab, expected, replacement in
            self.lock.lock(); defer { self.lock.unlock() }
            guard FocusBrowser.unique(tab, in: self.tabs), let i = self.tabs.firstIndex(where: {
                $0.identity == tab.identity && $0.window == tab.window && $0.index == tab.index && $0.url == expected
            }) else { return false }
            self.writes += 1
            self.tabs[i] = .init(window: tab.window, index: tab.index, url: replacement, identity: tab.identity)
            return true
        })
    }
}
func tab(_ url: String = "https://news.example.com/", id: String? = "one", index: Int = 0, window: Int = 10) -> FocusBrowser.Tab {
    .init(window: window, index: index, url: url, identity: id)
}
var policy = FocusConfiguration(); policy.websites = ["example.com"]
func poll(_ browser: FocusBrowser) { var done = false; browser.poll(configuration: policy, preferences: .init(), snoozes: []) { _, _ in done = true }; until { done } }
func restore(_ browser: FocusBrowser) { var done = false; browser.restore { done = true }; until { done } }
func records(_ directory: URL) -> [FocusBrowser.Redirect] {
    try! JSONDecoder().decode([FocusBrowser.Redirect].self, from: Data(contentsOf: directory.appendingPathComponent("browser-recovery.json")))
}
// Initial duplicate URLs, absent IDs and duplicate IDs are all ambiguous.
for sample in [[tab(id: nil)], [tab(), tab(id: "two", index: 1)], [tab(), tab("https://other.invalid", index: 1)]] {
    let fake = Fake(); fake.tabs = sample
    let browser = FocusBrowser(directory: root.appendingPathComponent(UUID().uuidString), driver: fake.driver)
    poll(browser); check(fake.writes == 0, "ambiguous initial identity skips redirect")
}
// An index can be reused between read and write. Matching URL alone must not win.
let race = Fake(); race.tabs = [tab()]
race.onRead = { race.change { $0.tabs = [tab(id: "replacement")] } }
let raced = FocusBrowser(directory: root.appendingPathComponent("race"), driver: race.driver)
poll(raced); check(race.writes == 0, "replacement tab with identical URL is never redirected")

for scenario in ["duplicate-marker", "moved", "navigated", "legacy"] {
    let fake = Fake(); fake.tabs = [tab()]
    let directory = root.appendingPathComponent(scenario)
    let browser = FocusBrowser(directory: directory, driver: fake.driver, recovery: .init(attempts: 1, interval: 0.02, lifetime: 60))
    poll(browser); let blocked = fake.snapshot()[0].url
    fake.change { value in
        if scenario == "duplicate-marker" { value.tabs.append(tab(blocked, id: "two", index: 1)) }
        if scenario == "moved" { value.tabs = [tab(blocked, index: 1, window: 11)] }
        if scenario == "navigated" { value.tabs = [tab("https://user.invalid/")] }
    }
    if scenario == "legacy" {
        var journal = records(directory); journal[0].identity = nil
        try JSONEncoder().encode(journal).write(to: directory.appendingPathComponent("browser-recovery.json"))
        let legacy = FocusBrowser(directory: directory, driver: fake.driver, recovery: .init(attempts: 1, interval: 0.02, lifetime: 60))
        restore(legacy)
    } else { restore(browser) }
    check(fake.writes == 1, scenario + " does not restore a different or ambiguous tab")
    check(records(directory).count == 1 && FileManager.default.fileExists(atPath: URL(string: blocked)!.path), scenario + " preserves original URL and marker")
}
// No browser -> new PID with empty first snapshot -> restored tab appears later.
let delayed = Fake(); delayed.tabs = [tab()]
let delayedDirectory = root.appendingPathComponent("relaunch")
let delayedBrowser = FocusBrowser(directory: delayedDirectory, driver: delayed.driver, recovery: .init(attempts: 8, interval: 0.04, lifetime: 60))
poll(delayedBrowser); let marker = delayed.snapshot()[0].url
delayed.change { $0.processes = []; $0.tabs = [] }; restore(delayedBrowser)
check(records(delayedDirectory).count == 1, "browser absent retains recovery journal")
delayed.change { $0.processes = [("com.apple.Safari", 2)] }; restore(delayedBrowser)
check(records(delayedDirectory).count == 1, "new process empty snapshot retains recovery journal")
delayed.change { $0.tabs = [tab(marker, id: "new-id", index: 2), tab("https://user.invalid/", id: "user", index: 3)] }
until { delayed.snapshot().first?.url == "https://news.example.com/" }
check(delayed.snapshot()[1].url == "https://user.invalid/", "late restored marker recovers uniquely without changing user navigation")
check(delayedBrowser.flush(), "drain successful retry")

let expired = Fake(); expired.tabs = [tab()]
let expiryDirectory = root.appendingPathComponent("expiry")
let expiringBrowser = FocusBrowser(directory: expiryDirectory, driver: expired.driver, recovery: .init(attempts: 2, interval: 0.02, lifetime: 60))
poll(expiringBrowser); let expiryMarker = expired.snapshot()[0].url
expired.change { $0.tabs = [] }; restore(expiringBrowser)
until { (records(expiryDirectory).first?.suspended) == true }
let readsAtExpiry = expired.reads
RunLoop.current.run(until: Date().addingTimeInterval(0.08))
check(expired.reads == readsAtExpiry && FileManager.default.fileExists(atPath: URL(string: expiryMarker)!.path), "retry budget stops polling but preserves original recovery data")

let failure = Fake(); failure.tabs = [tab()]
let failureDirectory = root.appendingPathComponent("restore-error")
let failedBrowser = FocusBrowser(directory: failureDirectory, driver: failure.driver, recovery: .init(attempts: 3, interval: 0.02, lifetime: 60))
poll(failedBrowser); failure.change { $0.failRead = true }; restore(failedBrowser)
check(failedBrowser.restorationError != nil && records(failureDirectory).count == 1, "restoration failure reports pending recovery and preserves journal")
failure.change { $0.failRead = false }
until { failure.snapshot()[0].url == "https://news.example.com/" && failedBrowser.restorationError == nil }
check(true, "successful bounded retry clears recovery error")
let aged = Fake(); aged.tabs = [tab()]
let agedDirectory = root.appendingPathComponent("aged")
let agedBrowser = FocusBrowser(directory: agedDirectory, driver: aged.driver, recovery: .init(attempts: 5, interval: 0.02, lifetime: 0))
poll(agedBrowser); restore(agedBrowser)
check(records(agedDirectory).first?.suspended == true && aged.writes == 1, "expired recovery stops writes without deleting evidence")

// The full journal remains unchanged and reports a pause-worthy error.
let saturatedDirectory = root.appendingPathComponent("capacity")
try FileManager.default.createDirectory(at: saturatedDirectory.appendingPathComponent("Blocked", isDirectory: true),
                                        withIntermediateDirectories: true)
let saturatedPath = saturatedDirectory.appendingPathComponent("browser-recovery.json")
let full = (0..<FocusBrowser.recoveryCapacity).map { index in
    FocusBrowser.Redirect(browser: "com.apple.Safari", pid: 1, original: "https://news.example.com/\(index)",
        blocked: saturatedDirectory.appendingPathComponent("Blocked/\(index).html").absoluteString)
}
let fullBytes = try JSONEncoder().encode(full)
try fullBytes.write(to: saturatedPath)
let fullFake = Fake()
fullFake.tabs = [tab("https://news.example.com/new")]
let saturated = FocusBrowser(directory: saturatedDirectory, driver: fullFake.driver)
var saturatedDone = false
var saturationIssue: String?
saturated.poll(configuration: policy, preferences: .init(), snoozes: []) { issue, _ in
    saturationIssue = issue; saturatedDone = true
}
until { saturatedDone }
let persistedFullBytes = try Data(contentsOf: saturatedPath)
check(saturationIssue?.contains("已满") == true && fullFake.writes == 0 && fullBytes == persistedFullBytes,
      "capacity is reported without redirecting or losing existing recovery records")

// An injected transient launch failure releases the URL slot but not the receipt.
let retryDirectory = root.appendingPathComponent("app-retry")
let retryState = FocusStore(url: retryDirectory.appendingPathComponent("state.json"))
let fixtureProcess = FocusApplicationExits.Process(pid: -11, launched: Date())
let fixtureSession = UUID()
let fixtureURL = root.appendingPathComponent("Inert.app")
var retryArchive = FocusArchive()
check(retryArchive.applicationExits.request(fixtureProcess, application: .init(id: "fixture.fake", name: "Inert"),
    url: fixtureURL, session: fixtureSession), "fixture receives quit ticket")
retryArchive.applicationExits.sent(fixtureProcess)
retryArchive.applicationExits.observedExit(fixtureProcess)
retryArchive.applicationExits.finish(fixtureSession, restore: true)
try retryState.save(retryArchive)
var restoreLaunches = 0
let applicationRetryController = FocusController(registry: registry, defaults: defaults, directory: retryDirectory,
    authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic"), observeSystemFocus: false,
    browserDriver: fullFake.driver, openApplicationForRestore: { url, completion in
        precondition(url == fixtureURL)
        restoreLaunches += 1
        completion(restoreLaunches > 1)
    })
applicationRetryController.startService()
check(restoreLaunches == 1 && applicationRetryController.archive.applicationExits.receipts.count == 1,
      "failed application reopen retains durable receipt")
until { restoreLaunches == 2 }
check(applicationRetryController.archive.applicationExits.receipts.isEmpty,
      "bounded retry reopens after transient failure and clears receipt only on success")
applicationRetryController.stopService()

// Preferences cancel a queued policy, then safely restore its existing marker.
let preferenceFake = Fake(); preferenceFake.tabs = [tab()]
let preferenceDirectory = root.appendingPathComponent("preferences")
var state = FocusArchive(); var allow = FocusConfiguration(); allow.mode = .allow; allow.goal = "Synthetic"
state.session = .init(configuration: allow, now: Date())
try FocusStore(url: preferenceDirectory.appendingPathComponent("state.json")).save(state)
let preferenceController = FocusController(registry: registry, defaults: defaults, directory: preferenceDirectory,
    authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic"), observeSystemFocus: false, browserDriver: preferenceFake.driver)
var pollDone = false
preferenceController.browser.poll(configuration: allow, preferences: .init(), snoozes: []) { _, _ in pollDone = true }; until { pollDone }
preferenceController.preferences.allowAllWebsites = true
until { preferenceFake.snapshot()[0].url == "https://news.example.com/" }
check(preferenceController.browser.flush(), "allow-all preference restores identifiable blocked tab")
preferenceController.preferences.allowAllWebsites = false
let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
preferenceFake.change { $0.onRead = { entered.signal(); _ = release.wait(timeout: .now() + 3) } }
preferenceController.browser.poll(configuration: allow, preferences: .init(), snoozes: []) { _, _ in }
check(entered.wait(timeout: .now() + 3) == .success, "queued old policy is in flight")
preferenceController.preferences.allowAllWebsites = true; release.signal()
check(preferenceController.browser.flush(), "allow-all cancellation drains old policy")
check(preferenceFake.snapshot()[0].url == "https://news.example.com/", "canceled old policy cannot redirect after preference changes")
preferenceController.windows.close()

// Permission calls are injected; no TCC APIs are called by these controllers.
var prompts = 0
let empty = Fake(); empty.tabs = []
let access = FocusController.BrowserAccess(running: { ["com.apple.Safari", "com.google.Chrome"] }, permission: { _, ask in
    if ask { prompts += 1 }; return -1743
})
let permissionController = FocusController(registry: registry, defaults: defaults, directory: root.appendingPathComponent("permission"),
    authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic"), observeSystemFocus: false,
    browserDriver: empty.driver, browserAccess: access)
permissionController.startService(); permissionController.prepareSession(); permissionController.draft.goal = "Synthetic"; permissionController.draft.websites = ["example.com"]
for _ in 0..<2 { permissionController.saveSession {}; until { !permissionController.starting } }
check(prompts == 1 && permissionController.session == nil, "permission denial stops the chain and suppresses subsequent prompts")
permissionController.stopService()
defaults.removeObject(forKey: "focus.browserPermissionDenied")
let promptEntered = DispatchSemaphore(value: 0), promptRelease = DispatchSemaphore(value: 0)
let canceledAccess = FocusController.BrowserAccess(running: { ["com.apple.Safari", "com.google.Chrome"] }, permission: { _, ask in
    if ask { prompts += 1; promptEntered.signal(); _ = promptRelease.wait(timeout: .now() + 3) }; return ask ? 0 : -1743
})
let cancelController = FocusController(registry: registry, defaults: defaults, directory: root.appendingPathComponent("cancel"),
    authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic"), observeSystemFocus: false,
    browserDriver: empty.driver, browserAccess: canceledAccess)
cancelController.startService(); cancelController.prepareSession(); cancelController.draft.goal = "Synthetic"; cancelController.draft.websites = ["example.com"]
cancelController.saveSession {}
// Drain the main queue, since the request gate must run on it.
var didEnter = false
until { if promptEntered.wait(timeout: .now()) == .success { didEnter = true }; return didEnter }
cancelController.cancelPreparation(); promptRelease.signal()
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
check(prompts == 2 && cancelController.session == nil, "canceling preparation stops later browser requests and session creation")
cancelController.stopService()
print("FOCUS_SAFETY_PASS")
