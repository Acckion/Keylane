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

        guard AXIsProcessTrusted() else {
            print("Native window and menu actions require Accessibility access for the test runner")
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
        AXUIElementSetAttributeValue(fixtureAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        try require(awaitValue(timeout: 3, { fixture.isActive ? true : nil }) == true, "Fixture did not become frontmost")

        let navigation = SystemNavigation.shared
        navigation.observeFocus(of: fixture)
        var windows: NavigationScan?
        _ = navigation.scan(.windows, target: nil) { windows = $0 }
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

        fixtureProcess.terminate()
        fixtureProcess.waitUntilExit()
        try require(try !perform(a, mode: .windows).isEmpty, "A terminated app was treated as available")
        print("Native window focus, nested menu discovery, action execution, disabled command, and app termination passed")
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
        let disabled = NSMenuItem(title: "Disabled Fixture Action", action: #selector(press), keyEquivalent: "")
        disabled.target = self
        nested.submenu?.autoenablesItems = false
        disabled.isEnabled = false
        nested.submenu?.addItem(disabled)
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
    @objc private func press() {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("pressed").path, contents: nil)
    }
}
