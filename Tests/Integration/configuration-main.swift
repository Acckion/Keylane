import AppKit
import Carbon
import Foundation
import KeylaneCore

// Synthetic data only. Each invocation uses a random, explicitly guarded suite.
let args = CommandLine.arguments
precondition(args.count == 4)
let phase = args[1], suite = args[2], root = URL(fileURLWithPath: args[3], isDirectory: true)
let prefix = "org.keylane.configuration-fixture."
precondition(suite.hasPrefix(prefix) && UUID(uuidString: String(suite.dropFirst(prefix.count))) != nil)
let path = root.standardizedFileURL.path
precondition(path.hasPrefix("/private/tmp/KeylaneConfiguration.") || path.hasPrefix("/tmp/KeylaneConfiguration."))
precondition(Bundle.main.bundleIdentifier == suite)
let defaults = UserDefaults.standard
let recovery = root.appendingPathComponent("recovery")
let fixture = root.appendingPathComponent("fixture.json")
func current() -> [String: Any] { defaults.persistentDomain(forName: suite) ?? [:] }
let modifiers = UInt32(cmdKey | shiftKey | optionKey | controlKey)
func reserve(_ shortcut: Shortcut, id: UInt32) -> EventHotKeyRef? {
    var reference: EventHotKeyRef?
    let status = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: 0x54455354, id: id), GetApplicationEventTarget(), 0, &reference)
    return status == noErr ? reference : nil
}
func available(except: Set<UInt32> = []) -> Shortcut {
    for key: UInt32 in [90, 79, 80, 99, 100, 101, 109, 103] where !except.contains(key) {
        let shortcut = Shortcut(key: key, modifiers: modifiers)
        if let reference = reserve(shortcut, id: 777) { UnregisterEventHotKey(reference); return shortcut }
    }
    fatalError("No free synthetic hotkey; nothing was overwritten")
}
func deliverSyntheticHotkey() {
    var reference: EventRef?
    precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), EventAttributes(0), &reference) == noErr)
    guard let event = reference else { fatalError("Synthetic Carbon event creation failed") }
    defer { ReleaseEvent(event) }
    var id = EventHotKeyID(signature: 0x4B4C414E, id: 1)
    precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id) == noErr)
    precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
func withAutoClosedDialog(check: @escaping (NSWindow) -> Void, operation: () -> Void) {
    var observed = false
    let started = Date()
    let timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
        if let window = NSApp.modalWindow {
            if !observed { check(window); observed = true }
            NSApp.stopModal(withCode: .alertFirstButtonReturn)
            window.orderOut(nil)
        } else if Date().timeIntervalSince(started) > 5 {
            fatalError("Expected synthetic native dialog was not presented")
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    operation()
    if !observed { print("SYNTHETIC_DIALOG_NOT_OBSERVED windows=\(NSApp.windows.count) pending=\(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("pending.plist").path)) applied=\(defaults.string(forKey: "appearance") == "dark")") }
    precondition(observed)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
switch phase {
case "seed":
    let original = available()
    var baseline: [String: Any] = [
        "appearance": "light", "placement": "activeScreen", "rootSearchSensitivity": "low", "interfaceSize": "medium",
        "windowMode": "expanded", "applicationHotkeyAction": "toggle", "navigation": "arrows",
        "windowActivationBehavior": "systemDefault", "launcherEscapeBehavior": "backOrClose", "pageNavigationKeys": "brackets",
        "rootFileContentSearch": false, "compactFavorites": false, "applicationsEnabled": false,
        "escapeClosesUtilityWindows": false, "replaceHyperKeycaps": false, "launcherReturnDelay": 90,
        "disabledLauncherCommands": [String](), "unrelatedFixture": "keep", "aliases": ["keep": "synthetic-existing"]
    ]
    baseline["shortcuts"] = try JSONEncoder().encode(["launcher": original])
    baseline[QuicklinkLibrary.storageKey] = try JSONEncoder().encode(QuicklinkLibrary(links: []))
    defaults.setPersistentDomain(baseline, forName: suite)
    precondition(defaults.synchronize())
    var archive = ConfigurationArchive()
    archive.preferences["appearance"] = .string("dark")
    archive.shortcuts = ["launcher": available(except: [original.key])]
    archive.aliases = ["quicklink:synthetic": "synthetic-imported"]
    archive.quicklinks = [.init(id: "quicklink:synthetic", title: "Synthetic", template: "https://example.com")]
    try archive.data().write(to: fixture, options: .atomic)
    let exported = try ConfigurationArchive.capture(defaults, includePersonalContent: true)
    try exported.data().write(to: root.appendingPathComponent("export.json"), options: .atomic)
    let exportedAgain = try ConfigurationArchive.decode(Data(contentsOf: root.appendingPathComponent("export.json")))
    precondition(exportedAgain.preferences["appearance"] == .string("light"))
    print("CONFIGURATION_SYNTHETIC_EXPORT_OK")
case "stage":
    let archive = try ConfigurationArchive.decode(Data(contentsOf: fixture))
    let plan = try archive.plan(current: current(), overwrite: true)
    try ConfigurationTransaction.stage(changes: plan.changes, current: current(), directory: recovery)
    precondition(defaults.string(forKey: "appearance") == "light")
    precondition(!FileManager.default.fileExists(atPath: recovery.appendingPathComponent("last-import.plist").path))
    print("CONFIGURATION_STAGE_NO_LIVE_WRITE_OK")
case "apply":
    precondition(NSApp != nil && ConfigurationStartupProbe.modelsCreated == 0)
    withAutoClosedDialog(check: { _ in
        precondition(ConfigurationStartupProbe.modelsCreated == 0)
        precondition(defaults.string(forKey: "appearance") == "dark")
    }, operation: {
        ConfigurationTransfer.finishPending(defaults: defaults, domain: suite, directory: recovery)
    })
    ConfigurationStartupProbe.restoreHandled = true
    let delegate = Delegate()
    app.delegate = delegate
    precondition(ConfigurationStartupProbe.modelsCreated == 1)
    precondition(defaults.string(forKey: "appearance") == "dark")
    precondition(defaults.string(forKey: "unrelatedFixture") == "keep")
    let archive = try ConfigurationArchive.decode(Data(contentsOf: fixture))
    let repeated = try archive.plan(current: current(), overwrite: true)
    precondition(repeated.changes.isEmpty)
    print("CONFIGURATION_NATIVE_STARTUP_NOTICE_BEFORE_MODEL_OK")
    print("CONFIGURATION_NEW_PROCESS_APPLY_IDEMPOTENCY_OK")
case "hotkeys":
    let bindings = try JSONDecoder().decode([String: Shortcut].self, from: defaults.data(forKey: "shortcuts")!)
    let original = bindings["launcher"]!
    let manager = ShortcutManager()
    defer { manager.stop() }
    try manager.apply(bindings)
    precondition(reserve(original, id: 778) == nil)
    var delivered = 0
    manager.fired = { if $0 == "launcher" { delivered += 1 } }
    deliverSyntheticHotkey()
    precondition(delivered == 1)
    let blocked = available(except: [original.key])
    guard let blocker = reserve(blocked, id: 779) else { fatalError("Synthetic conflict reservation failed") }
    defer { UnregisterEventHotKey(blocker) }
    var proposed = bindings; proposed["synthetic-secondary"] = blocked
    do { try manager.apply(proposed); fatalError("Expected OS registration conflict") }
    catch is ShortcutManager.Failure {}
    precondition(reserve(original, id: 780) == nil)
    deliverSyntheticHotkey()
    precondition(delivered == 2)
    manager.stop()
    guard let released = reserve(original, id: 781) else { fatalError("Synthetic registration was not released") }
    UnregisterEventHotKey(released)
    print("CARBON_REGISTRATION_CONFLICT_ROLLBACK_RELEASE_OK dispatch=targeted-synthetic-carbon-event")
case "cancel-next":
    let receipt = try Data(contentsOf: recovery.appendingPathComponent("last-import.plist"))
    try ConfigurationTransaction.stage(changes: ["appearance": "system"], current: current(), directory: recovery)
    try ConfigurationTransaction.cancel(directory: recovery, current: current())
    precondition(defaults.string(forKey: "appearance") == "dark")
    let retained = try Data(contentsOf: recovery.appendingPathComponent("last-import.plist"))
    precondition(retained == receipt)
    try ConfigurationTransaction.stageUndo(current: current(), directory: recovery)
    print("CONFIGURATION_CANCEL_PRESERVES_PRIOR_UNDO_OK")
case "undo":
    let completed = try ConfigurationTransaction.finish(defaults: defaults, domain: suite, directory: recovery)
    precondition(completed)
    precondition(defaults.string(forKey: "appearance") == "light")
    precondition(defaults.string(forKey: "unrelatedFixture") == "keep")
    let library = try JSONDecoder().decode(QuicklinkLibrary.self, from: defaults.data(forKey: QuicklinkLibrary.storageKey)!)
    precondition(library.links.isEmpty)
    let baseline = try ConfigurationArchive.decode(Data(contentsOf: root.appendingPathComponent("export.json")))
    let restored = try JSONDecoder().decode([String: Shortcut].self, from: defaults.data(forKey: "shortcuts")!)
    precondition(restored == baseline.shortcuts)
    precondition(defaults.dictionary(forKey: "aliases") as? [String: String] == ["keep": "synthetic-existing"])
    print("CONFIGURATION_NEW_PROCESS_UNDO_OK")
case "preview-ui":
    let text = (0..<100).map { "Synthetic preview row \($0): supported category and conflict count" }.joined(separator: "\n")
    let alert = NSAlert()
    alert.messageText = "Synthetic Configuration Preview"
    alert.accessoryView = ConfigurationTransfer.previewText(text)
    alert.addButton(withTitle: "Close")
    withAutoClosedDialog(check: { _ in
        guard let scroll = alert.accessoryView as? NSScrollView,
              let view = scroll.documentView as? NSTextView,
              let manager = view.layoutManager, let container = view.textContainer else { fatalError("Preview structure missing") }
        precondition(!view.isEditable && view.isSelectable && scroll.hasVerticalScroller)
        manager.ensureLayout(for: container)
        let needed = manager.usedRect(for: container).height + view.textContainerInset.height * 2
        precondition(needed > scroll.contentView.bounds.height)
        precondition(view.frame.height >= needed - 1)
        precondition(view.string == text)
    }, operation: { _ = alert.runModal() })
    print("CONFIGURATION_NATIVE_SCROLL_PREVIEW_OK")
case "startup-failure":
    precondition(ConfigurationStartupProbe.modelsCreated == 0)
    try ConfigurationTransaction.stage(changes: ["appearance": "dark"], current: current(), directory: recovery)
    defaults.set("system", forKey: "appearance")
    precondition(defaults.synchronize())
    withAutoClosedDialog(check: { _ in
        precondition(ConfigurationStartupProbe.modelsCreated == 0)
        precondition(defaults.string(forKey: "appearance") == "system")
    }, operation: {
        ConfigurationTransfer.finishPending(defaults: defaults, domain: suite, directory: recovery)
    })
    precondition(defaults.string(forKey: "appearance") == "system")
    precondition(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("pending.plist").path))
    ConfigurationStartupProbe.restoreHandled = true
    let delegate = Delegate()
    app.delegate = delegate
    precondition(ConfigurationStartupProbe.modelsCreated == 1)
    print("CONFIGURATION_NATIVE_STARTUP_FAILURE_PRESERVES_CONFIGURATION_OK")
case "cleanup":
    defaults.removePersistentDomain(forName: suite)
    precondition(defaults.synchronize())
    print("CONFIGURATION_SYNTHETIC_SUITE_REMOVED")
default: fatalError("Unknown fixture phase")
}
