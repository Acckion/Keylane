import AppKit
import ApplicationServices
import Carbon
import KeylaneCore

@main
struct NavigationChecks {
    static func main() {
        do { try runChecks() }
        catch {
            fputs("Navigation check failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func runChecks() throws {
        if CommandLine.arguments.contains("--fixture") {
            let fixture = NavigationFixture()
            NSApplication.shared.delegate = fixture
            NSApplication.shared.run()
            return
        }

        precondition(NavigationShortcut.keys(character: "s", virtualKey: nil, glyph: nil, modifiers: 1) == ["⇧", "⌘", "S"])
        precondition(NavigationShortcut.keys(character: nil, virtualKey: kVK_LeftArrow, glyph: nil, modifiers: 14) == ["⌃", "⌥", "←"])
        precondition(NavigationShortcut.keys(character: nil, virtualKey: nil, glyph: kMenuF5Glyph, modifiers: 8) == ["F5"])
        precondition(NavigationShortcut.keys(character: "", virtualKey: nil, glyph: nil, modifiers: 0).isEmpty)
        let request = NavigationScanRequest()
        request.cancel()
        precondition(request.isCancelled)
        print("Shortcut display and scan cancellation passed")

        try checkController()

        guard AXIsProcessTrusted() else {
            print("SKIP native window and menu actions: test runner has no Accessibility access")
            return
        }

        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keylane-navigation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fixtureProcess = Process()
        fixtureProcess.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        fixtureProcess.arguments = ["--fixture", temporary.path]
        try fixtureProcess.run()
        defer { if fixtureProcess.isRunning { fixtureProcess.terminate() }; fixtureProcess.waitUntilExit() }
        let marker = temporary.appendingPathComponent("pressed")
        guard let fixture = awaitValue(timeout: 4, { NSRunningApplication(processIdentifier: fixtureProcess.processIdentifier) }),
              awaitValue(timeout: 4, { FileManager.default.fileExists(atPath: temporary.appendingPathComponent("ready").path) ? true : nil }) == true
        else { throw CheckError.failed("Fixture did not start") }

        let fixtureAX = AXUIElementCreateApplication(fixture.processIdentifier)
        try require(awaitValue(timeout: 4, {
            if fixture.isActive { return true }
            AXUIElementSetAttributeValue(fixtureAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            return nil
        }) == true, "Fixture did not become frontmost")

        let navigation = SystemNavigation.shared
        navigation.observeFocus(of: fixture)
        var windows: NavigationScan?
        _ = navigation.scan(.windows, target: nil, windowApplications: [fixture]) { windows = $0 }
        let fixtureWindows = awaitValue(timeout: 8, { windows })?.items.filter { $0.application.processIdentifier == fixture.processIdentifier } ?? []
        try require(fixtureWindows.first?.title == "Navigation Fixture B", "The focused window did not rank first")
        guard let a = fixtureWindows.first(where: { $0.title == "Navigation Fixture A" }) else { throw CheckError.failed("Missing window A") }
        let switchError = try perform(a, mode: .windows)
        try require(switchError.isEmpty, "Window focus failed: " + switchError)

        let placementError = try place(.left, in: fixture)
        try require(placementError.isEmpty, "Left-half placement failed: " + placementError)
        try require(try place(.restore, in: fixture).isEmpty, "Window restore failed")
        try require(try !place(.restore, in: fixture).isEmpty, "Restore remained available after use")
        print("Native window placement and restore passed")

        var menus: NavigationScan?
        _ = navigation.scan(.menus, target: fixture) { menus = $0 }
        let commands = awaitValue(timeout: 8, { menus })?.items ?? []
        guard let command = commands.first(where: { $0.title == "Run Fixture Action" }),
              let disabled = commands.first(where: { $0.title == "Disabled Fixture Action" }) else { throw CheckError.failed("Missing menu commands") }
        try require(command.detail == "Fixture › Nested", "Nested menu path was incorrect")
        try require(command.keys == ["⇧", "⌘", "J"], "Menu shortcut was incorrect")
        try require(!disabled.enabled, "Disabled command was reported as enabled")
        try require(try !perform(disabled, mode: .menus).isEmpty, "Disabled command did not return an error")
        try require(!FileManager.default.fileExists(atPath: marker.path), "Disabled command executed")
        try require(try perform(command, mode: .menus).isEmpty, "Menu action returned an error")
        try require(awaitValue(timeout: 2, {
            FileManager.default.fileExists(atPath: marker.path) ? true : nil
        }) == true, "The menu action did not reach the fixture")

        try FileManager.default.removeItem(at: marker)
        try Data().write(to: temporary.appendingPathComponent("change-menu"))
        try require(awaitValue(timeout: 3, {
            FileManager.default.fileExists(atPath: temporary.appendingPathComponent("menu-changed").path) ? true : nil
        }) == true, "Fixture did not update the menu")
        try require(try !perform(command, mode: .menus).isEmpty, "Renamed command remained executable")
        try require(!FileManager.default.fileExists(atPath: marker.path), "Stale menu action executed")
        menus = nil
        navigation.scan(.menus, target: fixture) { menus = $0 }
        guard let renamed = awaitValue(timeout: 8, { menus })?.items.first(where: { $0.title == "Renamed Fixture Action" })
        else { throw CheckError.failed("Renamed command missing after refresh") }
        try require(try perform(renamed, mode: .menus).isEmpty, "Refreshed menu command failed")
        try require(awaitValue(timeout: 2, {
            FileManager.default.fileExists(atPath: marker.path) ? true : nil
        }) == true, "Refreshed menu command did not execute")
        print("Native dynamic menu rename and refresh passed")

        let pasteMarker = temporary.appendingPathComponent("pasted")
        var filePaste: SystemNavigation.PasteMenuResult?
        navigation.pasteFile(in: fixture, isCurrent: { false }) { filePaste = $0 }
        guard case .cancelled? = awaitValue(timeout: 4, { filePaste }) else {
            throw CheckError.failed("A stale file paste was not cancelled")
        }
        try require(!FileManager.default.fileExists(atPath: pasteMarker.path), "A stale file paste executed")
        filePaste = nil
        navigation.pasteFile(in: fixture, isCurrent: { true }) { filePaste = $0 }
        guard case .performed? = awaitValue(timeout: 4, { filePaste }) else {
            throw CheckError.failed("The native file paste menu did not execute")
        }
        try require(awaitValue(timeout: 2, {
            FileManager.default.fileExists(atPath: pasteMarker.path) ? true : nil
        }) == true, "The paste menu action did not reach the target")
        print("Native file paste menu and stale paste cancellation passed")

        fixtureProcess.terminate()
        fixtureProcess.waitUntilExit()
        try require(try !perform(a, mode: .windows).isEmpty, "A terminated app was treated as available")
        print("Native window focus, nested menu discovery, action execution, disabled command, and app termination passed")
    }

    private static func checkController() throws {
        let fixtureApp = NSRunningApplication.current
        let element = AXUIElementCreateApplication(fixtureApp.processIdentifier)
        let first = NavigationItem(id: 0, title: "Fixture Alpha", detail: "Menus", application: fixtureApp, element: element)
        let second = NavigationItem(id: 1, title: "Fixture Beta", detail: "Menus", application: fixtureApp, element: element)
        let replacement = NavigationItem(id: 0, title: "Fixture Alpha", detail: "Menus", application: fixtureApp, element: element)
        var scans: [(NavigationScanRequest, (NavigationScan) -> Void)] = []
        var actions: [(NavigationScanRequest, (String?) -> Void)] = []
        var completions = 0
        var trusted = true
        let controller = NavigationController(trusted: { trusted }, scan: { _, _, request, completion in
            scans.append((request, completion))
        }, runAction: { _, _, request, completion in
            actions.append((request, completion))
        })
        controller.load(.windows, target: nil)
        controller.load(.windows, target: nil)
        try require(scans[0].0.isCancelled, "Switching target did not cancel the old scan")
        controller.query = "beta"
        scans[1].1(.init(items: [first, second]))
        scans[0].1(.init(items: [first], incomplete: true))
        try require(controller.selected?.identity == second.identity && !controller.incomplete,
                    "Latest query or target was overwritten")
        try require(!controller.select(first), "An item hidden by the query remained selectable")
        controller.perform(first, mode: .windows) { _ in completions += 1 }
        controller.perform(second, mode: .menus) { _ in completions += 1 }
        try require(actions.isEmpty, "A stale item or mode executed")
        controller.perform(second, mode: .windows) { _ in completions += 1 }
        controller.perform(second, mode: .windows) { _ in completions += 1 }
        try require(actions.count == 1, "Duplicate action was started")
        controller.stop()
        try require(!actions[0].0.isCancelled && controller.results.isEmpty,
                    "Hiding the launcher must clear results and allow the committed focus handoff")
        controller.query = ""
        controller.load(.windows, target: nil)
        scans[2].1(.init(items: [replacement]))
        try require(actions[0].0.isCancelled && !controller.performing, "Reopening did not cancel the prior action")
        actions[0].1(nil)
        try require(completions == 0 && controller.selected?.identity == replacement.identity,
                    "An old action completion affected the reopened page")
        controller.perform(first, mode: .windows) { _ in completions += 1 }
        try require(actions.count == 1, "A stale action was accepted because the new row reused its ID")
        controller.perform(replacement, mode: .windows) { _ in completions += 1 }
        actions[1].1(nil)
        try require(completions == 1, "The current action did not complete")
        controller.load(.menus, target: nil)
        try require(controller.status == .noApplication && controller.results.isEmpty, "Missing app was not shown")
        trusted = false
        controller.load(.windows, target: nil)
        try require(controller.status == .permission && scans.count == 3, "An unauthorized scan was started")
        print("PASS isolated navigation controller: query, target, selection, cancel, reopen, permission and stale completion")
    }

    private enum CheckError: Error { case failed(String) }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckError.failed(message) }
    }

    private static func perform(_ item: NavigationItem, mode: NavigationMode) throws -> String {
        var outcome: String?
        SystemNavigation.shared.perform(item, mode: mode) { outcome = $0 ?? "" }
        guard let outcome = awaitValue(timeout: 4, { outcome }) else { throw CheckError.failed("Navigation action timed out") }
        return outcome
    }

    private static func place(_ placement: WindowPlacement, in app: NSRunningApplication) throws -> String {
        var outcome: String?
        SystemNavigation.shared.placeWindow(placement, in: app) { outcome = $0 ?? "" }
        guard let outcome = awaitValue(timeout: 4, { outcome }) else { throw CheckError.failed("Window placement timed out") }
        return outcome
    }

    private static func awaitValue<T>(timeout: TimeInterval, _ value: () -> T?) -> T? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let value = value() { return value }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return value()
    }
}

private final class NavigationFixture: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var menuUpdates: Timer?
    private let folder = URL(fileURLWithPath: CommandLine.arguments.last!)
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menuBar = NSMenu()
        let appRoot = NSMenuItem()
        menuBar.addItem(appRoot)
        appRoot.submenu = NSMenu()
        let fixture = NSMenuItem(title: "Fixture", action: nil, keyEquivalent: "")
        let menu = NSMenu()
        fixture.submenu = menu
        menuBar.addItem(fixture)
        let nested = NSMenuItem(title: "Nested", action: nil, keyEquivalent: "")
        nested.submenu = NSMenu()
        menu.addItem(nested)
        let run = NSMenuItem(title: "Run Fixture Action", action: #selector(press), keyEquivalent: "j")
        run.keyEquivalentModifierMask = [.shift, .command]
        run.target = self
        nested.submenu?.addItem(run)
        menuUpdates = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [folder, weak run] timer in
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("change-menu").path) else { return }
            run?.title = "Renamed Fixture Action"
            FileManager.default.createFile(atPath: folder.appendingPathComponent("menu-changed").path, contents: nil)
            timer.invalidate()
        }
        let disabled = NSMenuItem(title: "Disabled Fixture Action", action: #selector(press), keyEquivalent: "")
        disabled.target = self
        nested.submenu?.autoenablesItems = false
        disabled.isEnabled = false
        nested.submenu?.addItem(disabled)
        let paste = NSMenuItem(title: "Paste Fixture", action: #selector(pasteFile), keyEquivalent: "v")
        paste.target = self
        menu.addItem(paste)
        NSApp.mainMenu = menuBar
        NSApp.activate(ignoringOtherApps: true)
        for (index, letter) in ["A", "B"].enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 250 + index * 60, y: 330, width: 420, height: 240),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Navigation Fixture " + letter
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        FileManager.default.createFile(atPath: folder.appendingPathComponent("ready").path, contents: nil)
    }
    @objc private func pasteFile() {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("pasted").path, contents: nil)
    }

    @objc private func press() {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("pressed").path, contents: nil)
    }
}
