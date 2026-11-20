import AppKit
import ApplicationServices
import KeylaneCore

// The host is not started by these read-only controller checks.
final class Delegate: NSObject, NSApplicationDelegate { var previousApplication: NSRunningApplication? }

@main struct ShortcutMapChecks {
    static func main() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            fatalError("Finder is required as a live target identity; no menu actions are performed")
        }
        let suite = "keylane-shortcut-map-test-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var callbacks: [(NavigationScanRequest, (NavigationScan) -> Void)] = []
        var trusted = true
        let controller = ShortcutMapController(trusted: { trusted }, preferences: preferences, timeoutInterval: 0.03,
                                               scan: { _, request, callback in callbacks.append((request, callback)) })
        let item = NavigationItem(id: 1, title: "Fixture", detail: "File", application: app,
                                  element: AXUIElementCreateApplication(app.processIdentifier), keys: ["⌘", "L"],
                                  shortcut: .init(key: 37, modifiers: 256), enabled: false)
        var completions = 0
        controller.load(app) { completions += 1 }
        controller.load(app) { completions += 1 }
        precondition(callbacks[0].0.isCancelled)
        callbacks[0].1(.init(items: [item]))
        precondition(completions == 0 && controller.loading)
        callbacks[1].1(.init(items: [item], incomplete: true))
        precondition(completions == 1 && !controller.loading)
        precondition(controller.target?.processIdentifier == app.processIdentifier)
        precondition(controller.entries.contains { $0.title == "Fixture" && !$0.enabled })
        precondition(!controller.overlaps(item.shortcut!).contains { $0.title == "Fixture" })
        precondition(controller.coverage.contains("不完整"))
        controller.load(app) { completions += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(completions == 2 && !controller.loading && callbacks[2].0.isCancelled)
        callbacks[2].1(.init(items: [item]))
        precondition(completions == 2 && !controller.entries.contains { $0.title == "Fixture" })
        trusted = false
        controller.load(app)
        precondition(callbacks.count == 3 && controller.coverage.contains("权限"))
        trusted = true
        preferences.set([app.bundleIdentifier!: "Finder"], forKey: "navigation.excludedMenuApplications")
        controller.load(app)
        precondition(callbacks.count == 3 && controller.coverage.contains("排除"))
        controller.load(NSRunningApplication.current)
        precondition(callbacks.count == 3 && controller.coverage.contains("请选择"))
        print("PASS shortcut map: stale scans, timeout, disabled commands, permissions, exclusions, host rejection; no actions dispatched")
    }
}
