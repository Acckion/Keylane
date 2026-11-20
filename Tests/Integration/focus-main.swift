// Bypasses production bootstrap. Isolated data, a dedicated helper app, and synthetic browser transport only.
setbuf(stdout, nil)
let focusApp = NSApplication.shared
focusApp.setActivationPolicy(.accessory)
focusApp.finishLaunching()
let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("FocusFixture-" + UUID().uuidString)
try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
let fixtureSuite = "org.keylane.focus.fixture." + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: fixtureSuite)!
let fixtureRegistry = MenuBarRegistry(preferences: fixtureDefaults)
defer { fixtureRegistry.shutdown(); fixtureDefaults.removePersistentDomain(forName: fixtureSuite); try? FileManager.default.removeItem(at: fixtureRoot) }
func expectFocus(_ value: @autoclosure () -> Bool, _ label: String) { precondition(value(), label); print("PASS " + label) }
func drainFocus(_ seconds: TimeInterval = 0.12) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
let fixtureController = FocusController(registry: fixtureRegistry, defaults: fixtureDefaults, directory: fixtureRoot.appendingPathComponent("state"))
expectFocus(!fixtureController.permission.enabled, "Focus defaults disabled without permission requests")
fixtureController.prepareCategory()
fixtureController.categoryDraft.name = "学习 Study"
fixtureController.categoryDraft.symbol = "book"
fixtureController.categoryDraft.websites = ["www.example.com", "bing"]
fixtureController.categoryDraft.applications = [.init(id: "com.apple.Notes", name: "备忘录")]
expectFocus(fixtureController.saveCategory(), "category saves atomically")
let restoredController = FocusController(registry: fixtureRegistry, defaults: fixtureDefaults, directory: fixtureRoot.appendingPathComponent("state"))
expectFocus(restoredController.archive.categories.count == 1 && restoredController.archive.categories[0].websites == ["bing", "example.com"], "category persists and normalizes domains")
fixtureController.prepareCategory(FocusCategory.builtIn[0], duplicate: true)
expectFocus(fixtureController.editingCategory == nil && fixtureController.categoryDraft.id != FocusCategory.builtIn[0].id, "built-in duplication cannot overwrite original")
fixtureController.prepareCategory(restoredController.archive.categories[0])

// Browser transport uses a synthetic tab array only.
let transportLock = NSLock()
var syntheticTabs = [FocusBrowser.Tab(window: 11, index: 0, url: "https://news.example.com/a"),
                     FocusBrowser.Tab(window: 11, index: 1, url: "https://work.invalid/")]
let transport = FocusBrowser.Driver(browsers: { [("com.apple.Safari", 123)] }, authorized: { _ in true }, read: { _ in
    transportLock.lock(); defer { transportLock.unlock() }; return syntheticTabs
}, write: { _, tab, expected, replacement in
    transportLock.lock(); defer { transportLock.unlock() }
    if let index = syntheticTabs.firstIndex(where: { $0.window == tab.window && $0.index == tab.index && $0.url == expected }) {
        syntheticTabs[index] = .init(window: tab.window, index: tab.index, url: replacement)
        return true
    }
    return false
})
let browser = FocusBrowser(directory: fixtureRoot.appendingPathComponent("browser"), driver: transport)
var syntheticConfig = FocusConfiguration(); syntheticConfig.websites = ["example.com"]
var reportReceived = false
browser.poll(configuration: syntheticConfig, preferences: .init(), snoozes: []) { error, host in
    expectFocus(error == nil && host == "news.example.com", "browser reports blocked hostname"); reportReceived = true
}
while !reportReceived { drainFocus() }
transportLock.lock(); let redirected = syntheticTabs[0].url; transportLock.unlock()
expectFocus(redirected.hasPrefix("file:"), "blocked tab redirects to an app-owned page")
var restoredTabs = false
browser.restore { restoredTabs = true }
while !restoredTabs { drainFocus() }
transportLock.lock(); let restoredURL = syntheticTabs[0].url; transportLock.unlock()
expectFocus(restoredURL == "https://news.example.com/a", "pause restores the exact blocked tab")
reportReceived = false
browser.poll(configuration: syntheticConfig, preferences: .init(), snoozes: []) { _, _ in reportReceived = true }
while !reportReceived { drainFocus() }
transportLock.lock(); syntheticTabs[0] = .init(window: 11, index: 0, url: "https://changed.invalid/"); transportLock.unlock()
restoredTabs = false; browser.restore { restoredTabs = true }
while !restoredTabs { drainFocus() }
transportLock.lock(); let userChanged = syntheticTabs[0].url; transportLock.unlock()
expectFocus(userChanged == "https://changed.invalid/", "restoration preserves a tab the user navigated away from")

// Render production SwiftUI views with isolated data; no screenshot of the desktop is taken.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let catalog = ApplicationSettingsCatalog(items: [
    .init(id: "/System/Applications/Notes.app", url: URL(fileURLWithPath: "/System/Applications/Notes.app"), title: "备忘录", filename: "Notes.app"),
    .init(id: "/System/Applications/Calendar.app", url: URL(fileURLWithPath: "/System/Applications/Calendar.app"), title: "日历", filename: "Calendar.app")
])
let previewWindow = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 820, height: 530), styleMask: [.titled], backing: .buffered, defer: false)
previewWindow.isReleasedWhenClosed = false; previewWindow.title = "Keylane Focus — 隔离界面验证"
func renderFocus<V: View>(_ view: V, name: String) throws {
    let host = NSHostingView(rootView: view.frame(width: 820, height: 530).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
    host.frame = NSRect(x: 0, y: 0, width: 820, height: 530)
    previewWindow.contentView = host; previewWindow.makeKeyAndOrderFront(nil)
    drainFocus(0.3); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
    let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
try renderFocus(FocusCategoryForm(controller: fixtureController, catalog: catalog, back: {}), name: "category")
func nativeFocusFields(_ root: NSView) -> [NSTextField] {
    (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(nativeFocusFields)
}
let nameField = nativeFocusFields(previewWindow.contentView!).first { $0.placeholderString == "为专注分类命名" }
expectFocus(nameField?.currentEditor() != nil, "category form focuses its name field for immediate typing")
if let field = nativeFocusFields(previewWindow.contentView!).first(where: { ($0.placeholderString?.contains("搜索应用") == true || $0.placeholderString == "添加…") }) {
    previewWindow.makeFirstResponder(field); field.selectText(nil)
    let editor = field.currentEditor() as! NSTextView
    editor.insertText("Calendar", replacementRange: editor.selectedRange())
    drainFocus(0.3)
    expectFocus(field.stringValue == "Calendar", "inline app picker retains typed English search")
    let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: previewWindow.windowNumber,
                                 context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    previewWindow.sendEvent(enter); drainFocus(0.2)
    expectFocus(fixtureController.categoryDraft.applications.contains { $0.id == "com.apple.iCal" },
                "Return selects the matching app instead of adding its name as a website keyword")
    editor.insertText("日历", replacementRange: editor.selectedRange())
    drainFocus(0.3)
    expectFocus(field.stringValue.contains("日历"), "inline app picker accepts Chinese text without closing on keypress")
} else { preconditionFailure("Focus app picker native input was not found") }
fixtureController.prepareSession(); fixtureController.draft.goal = "撰写报告"
fixtureController.draft.mode = .allow
fixtureController.draft.applications = restoredController.archive.categories[0].applications
fixtureController.draft.websites = ["example.com"]
fixtureController.durationText = "45 min"
try renderFocus(FocusSessionForm(controller: fixtureController, catalog: catalog, back: {}), name: "session")
let goalField = nativeFocusFields(previewWindow.contentView!).first { $0.placeholderString == "这次想专注做什么？" }
expectFocus(goalField?.currentEditor() != nil, "session form focuses its goal field for immediate typing")
try renderFocus(FocusCategoryList(controller: restoredController, edit: { _ in }), name: "categories")
previewWindow.close()
// The only application this controller may quit is the generated helper bundle.
let helperURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let helperID = Bundle(url: helperURL)!.bundleIdentifier!
precondition(helperID.hasPrefix("org.keylane.focus.fixture."))
var launchedHelper: NSRunningApplication?
var launchFinished = false
var launchMessage = ""
let launchConfiguration = NSWorkspace.OpenConfiguration(); launchConfiguration.activates = true
NSWorkspace.shared.openApplication(at: helperURL, configuration: launchConfiguration) { app, error in
    launchedHelper = app; launchMessage = error?.localizedDescription ?? ""; launchFinished = true
}
let launchDeadline = Date().addingTimeInterval(8)
while !launchFinished && Date() < launchDeadline { drainFocus() }
expectFocus(launchedHelper != nil, "Launch Services opens owned helper: " + launchMessage)
let helper = launchedHelper!
defer { NSRunningApplication.runningApplications(withBundleIdentifier: helperID).forEach { $0.terminate() } }
let helperDeadline = Date().addingTimeInterval(6)
while Date() < helperDeadline && NSRunningApplication(processIdentifier: helper.processIdentifier)?.activationPolicy != .regular { drainFocus() }
expectFocus(NSWorkspace.shared.runningApplications.contains { $0.processIdentifier == helper.processIdentifier }, "helper is registered with NSWorkspace")
expectFocus(NSRunningApplication(processIdentifier: helper.processIdentifier)?.bundleIdentifier == helperID, "owned helper has the fixture bundle identifier")
var helperConfiguration = FocusConfiguration(); helperConfiguration.goal = "隔离拦截验证"; helperConfiguration.duration = 2700
helperConfiguration.applications = [.init(id: helperID, name: "Focus Fixture")]
expectFocus(helperConfiguration.mode == .block && helperConfiguration.applications.count == 1, "fixture policy can only block its owned helper")
var helperArchive = FocusArchive(); helperArchive.preferences.playSound = false
helperArchive.preferences.restoreApplications = true
helperArchive.session = FocusSession(configuration: helperConfiguration, now: Date())
let helperDirectory = fixtureRoot.appendingPathComponent("helper-state")
try FocusStore(url: helperDirectory.appendingPathComponent("state.json")).save(helperArchive)
fixtureDefaults.set(true, forKey: "focus.enabled")
let helperController = FocusController(registry: fixtureRegistry, defaults: fixtureDefaults, directory: helperDirectory,
                                       authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic authorization"), observeSystemFocus: false)
expectFocus(helperController.session?.paused == true, "process restart restores the session paused")
func captureFocusPanel(_ name: String, width: CGFloat) throws {
    guard let panel = NSApplication.shared.windows.first(where: { $0 is NSPanel && abs($0.frame.width - width) < 1 && $0.isVisible }),
          let view = panel.contentView else { preconditionFailure("Missing Focus panel " + name) }
    drainFocus(0.2); view.layoutSubtreeIfNeeded()
    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
helperController.startService()
helperController.preferences.inMenuBar = true
expectFocus(fixtureRegistry.nativeItem(id: FocusController.owner) != nil, "moving the session uses the shared native menu bar registry")
helperController.preferences.inMenuBar = false
expectFocus(fixtureRegistry.nativeItem(id: FocusController.owner) == nil, "detaching removes the native status item")
try captureFocusPanel("focus-bar", width: 360)
if let owned = NSRunningApplication(processIdentifier: helper.processIdentifier) {
    owned.activate(options: []); drainFocus(0.2)
}
helperController.resume()
let edgePanels = NSApplication.shared.windows.compactMap { $0 as? NSPanel }.filter { $0.isVisible && $0.ignoresMouseEvents }
expectFocus(edgePanels.count == NSScreen.screens.count && edgePanels.allSatisfy { !$0.isKeyWindow },
            "warning edges cover each display without taking clicks or keyboard focus")
try captureFocusPanel("blocked-glow", width: NSScreen.main!.frame.width)
let quitDeadline = Date().addingTimeInterval(8)
while Date() < quitDeadline && (!helper.isTerminated || helperController.archive.terminatedApplications.isEmpty) { drainFocus() }
print("HELPER_STATE running=\(!helper.isTerminated) regular=\(NSRunningApplication(processIdentifier: helper.processIdentifier)?.activationPolicy.rawValue ?? -1) paused=\(helperController.session?.paused ?? true) authorized=\(helperController.permission.available) message=\(helperController.message)")
expectFocus(helper.isTerminated && !helperController.archive.terminatedApplications.isEmpty, "actual NSWorkspace blocking quits only the generated helper")
try captureFocusPanel("blocked-notice", width: 440)
let notice = NSApplication.shared.windows.first { $0 is NSPanel && abs($0.frame.width - 440) < 1 && $0.isVisible }!
// SwiftUI's rendered button is not an NSButton subview. Exercise its real mouse path.
let snoozePoint = NSPoint(x: notice.frame.width - 58, y: notice.frame.height / 2)
for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    let event = NSEvent.mouseEvent(with: type, location: snoozePoint, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: notice.windowNumber,
                                  context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    notice.sendEvent(event)
}
drainFocus(0.2)
expectFocus(helperController.session?.snoozed(helperID, at: Date()) == true,
            "blocked notification Snooze remains clickable after the app exits and focus changes")
let snoozeDeadline = Date().addingTimeInterval(8)
while Date() < snoozeDeadline && NSRunningApplication.runningApplications(withBundleIdentifier: helperID).isEmpty { drainFocus() }
expectFocus(!NSRunningApplication.runningApplications(withBundleIdentifier: helperID).isEmpty, "notification Snooze reopens the owned app")
helperController.restart()
let secondQuitDeadline = Date().addingTimeInterval(8)
while Date() < secondQuitDeadline && !NSRunningApplication.runningApplications(withBundleIdentifier: helperID).isEmpty { drainFocus() }
expectFocus(NSRunningApplication.runningApplications(withBundleIdentifier: helperID).isEmpty, "restart clears snooze and re-enforces the owned app policy")
helperController.finish(completed: true)
try captureFocusPanel("completed-notice", width: 440)
try captureFocusPanel("completed-glow", width: NSScreen.main!.frame.width)
let reopenDeadline = Date().addingTimeInterval(8)
while Date() < reopenDeadline && NSRunningApplication.runningApplications(withBundleIdentifier: helperID).isEmpty { drainFocus() }
expectFocus(!NSRunningApplication.runningApplications(withBundleIdentifier: helperID).isEmpty, "completion reopens the app Focus actually terminated")
expectFocus(helperController.archive.history.last?.completed == true, "completion records a successful session")
helperController.stopService()
expectFocus(helperController.browser.flush(), "shutdown flushes queued browser recovery")
// Synthetic system deliveries use empty block categories; no user app or browser can match.
let categoryA = FocusCategory(name: "系统学习"), categoryB = FocusCategory(name: "系统工作")
let autoDirectory = fixtureRoot.appendingPathComponent("system-state")
var autoArchive = FocusArchive(); autoArchive.categories = [categoryA, categoryB]
autoArchive.preferences.playSound = false
autoArchive.lastConfiguration.goal = "保留的手动配置"
try FocusStore(url: autoDirectory.appendingPathComponent("state.json")).save(autoArchive)
let autoController = FocusController(registry: fixtureRegistry, defaults: fixtureDefaults, directory: autoDirectory,
                                    authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic authorization"), observeSystemFocus: false)
let filterA = FocusSystemFilter(categories: [categoryA.id]), filterB = FocusSystemFilter(categories: [categoryB.id])
autoController.startService()
try autoController.applySystemFilter(filterA)
let firstAutoID = autoController.session!.id
expectFocus(autoController.systemManaged && autoController.session?.configuration.goal == categoryA.name, "system activation owns its automatic session")
expectFocus(autoController.archive.lastConfiguration.goal == "保留的手动配置", "automatic session preserves last manual configuration")
try autoController.applySystemFilter(filterA)
expectFocus(autoController.session?.id == firstAutoID, "duplicate system delivery does not restart a session")
autoController.pause()
autoController.stopService()
let recovered = FocusController(registry: fixtureRegistry, defaults: fixtureDefaults, directory: autoDirectory,
                                authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic authorization"), observeSystemFocus: false)
recovered.startService()
try recovered.applySystemFilter(filterA, recovering: true)
expectFocus(recovered.session?.paused == true, "relaunch preserves a user-paused automatic session")
recovered.resume(); recovered.stopService()
let resumed = FocusController(registry: fixtureRegistry, defaults: fixtureDefaults, directory: autoDirectory,
                              authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic authorization"), observeSystemFocus: false)
resumed.startService()
try resumed.applySystemFilter(filterA, recovering: true)
expectFocus(resumed.session?.paused == false && resumed.session?.id == firstAutoID, "relaunch reconciles only the matching system-owned session")
try resumed.applySystemFilter(filterB)
expectFocus(resumed.systemManaged && resumed.session?.id != firstAutoID && resumed.session?.configuration.goal == categoryB.name, "system mode switch replaces only its own session")
do {
    try resumed.applySystemFilter(.init(categories: [UUID()], mode: .allow))
    preconditionFailure("Deleted category must not create an empty allow policy")
} catch FocusSystemFilterError.missingCategory {
    expectFocus(resumed.session?.paused == true && resumed.session?.configuration.goal == categoryB.name,
                "deleted category pauses the owned session without replacing its policy")
}
resumed.resume()
resumed.restart()
expectFocus(resumed.systemManaged, "restarting an automatic session retains system ownership")
try resumed.applySystemFilter(.init())
expectFocus(resumed.session == nil && resumed.archive.history.last?.completed == true, "system reset finishes its automatic session")
try resumed.applySystemFilter(filterA)
resumed.finish(completed: false, showFeedback: false)
try resumed.applySystemFilter(filterA)
expectFocus(resumed.session == nil, "manual cancellation suppresses duplicate system starts")
resumed.stopService()

var manualArchive = FocusArchive(); manualArchive.categories = [categoryA, categoryB]
manualArchive.preferences.playSound = false
var manualConfig = FocusConfiguration(); manualConfig.goal = "手动任务"
manualArchive.session = FocusSession(configuration: manualConfig, now: Date())
let manualDirectory = fixtureRoot.appendingPathComponent("manual-priority")
try FocusStore(url: manualDirectory.appendingPathComponent("state.json")).save(manualArchive)
let manualController = FocusController(registry: fixtureRegistry, defaults: fixtureDefaults, directory: manualDirectory,
                                       authorization: .init(check: { true }, request: { $0(true) }, guidance: "Synthetic authorization"), observeSystemFocus: false)
manualController.startService(); manualController.resume()
let manualSession = manualController.session!
for request in [filterA, filterB, FocusSystemFilter()] { try manualController.applySystemFilter(request) }
expectFocus(manualController.session == manualSession && !manualController.systemManaged, "system activation, switch and reset preserve the manual session")
manualController.finish(completed: false, showFeedback: false); manualController.stopService()
expectFocus(manualController.browser.flush() && resumed.browser.flush(), "system fixture flushes isolated recovery queues")
print("FOCUS_FIXTURE_PASS previews=" + output.path)
