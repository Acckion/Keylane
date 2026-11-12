import AppKit
import Darwin
import Foundation

// ApplicationAutoQuit uses the host only to show an error toast.
final class Delegate: NSObject, NSApplicationDelegate {
    let toast = Toast()
}

struct Toast {
    enum Style { case failure }
    func show(_ message: String, style: Style) { fputs(message + "\n", stderr) }
}

private struct CheckFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@main
struct ApplicationAutoQuitChecks {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--helper"] {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.run()
            return
        }
        do {
            try checkDeadline()
        } catch {
            fputs("Auto-quit check failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func wait(for message: String, until ready: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        repeat {
            if ready() { return }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw CheckFailure(message)
    }

    private static func checkDeadline() throws {
        guard CommandLine.arguments.count == 2 else { throw CheckFailure("Expected a temporary fixture app") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard let bundleID = Bundle(url: fixture)?.bundleIdentifier,
              bundleID.hasPrefix("org.keylane.auto-quit-fixture.") else {
            throw CheckFailure("Refusing to run a non-fixture app")
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--helper"]
        var launched: NSRunningApplication?
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: fixture, configuration: configuration) { app, error in
            launched = app
            launchError = error
        }
        try wait(for: "The fixture did not launch") { launched != nil || launchError != nil }
        if let launchError { throw launchError }
        guard let helper = launched, helper.bundleIdentifier == bundleID,
              helper.bundleURL?.resolvingSymlinksInPath() == fixture else {
            throw CheckFailure("Unexpected app returned from the fixture launch")
        }
        defer { if !helper.isTerminated { _ = helper.terminate() } }
        try wait(for: "The fixture did not become a background application") {
            helper.isFinishedLaunching && helper.activationPolicy == .regular && !helper.isActive
                && NSWorkspace.shared.frontmostApplication != nil
                && NSWorkspace.shared.frontmostApplication?.processIdentifier != helper.processIdentifier
        }

        let suite = "org.keylane.auto-quit-fixture.settings." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var firstProbe = true
        var clock = 129.0
        var clockReads = 0
        let controller = ApplicationAutoQuit(defaults: defaults, uptime: {
            clockReads += 1
            return clock
        }, protection: {
            let shouldWait = lock.withLock {
                let shouldWait = firstProbe
                firstProbe = false
                return shouldWait
            }
            if shouldWait {
                probeStarted.signal()
                _ = releaseProbe.wait(timeout: .now() + 10)
            }
            return .init()
        })
        defer {
            controller.stop()
            releaseProbe.signal()
        }
        controller.setMinutes(1, for: fixture)
        guard controller.rules.count == 1 else { throw CheckFailure("The fixture must be the only auto-quit rule") }

        controller.start { true }
        try wait(for: "The first media check did not start") { probeStarted.wait(timeout: .now()) == .success }
        guard clockReads == 0 else { throw CheckFailure("The idle clock was read before the media check finished") }
        clock = 131
        releaseProbe.signal()
        try wait(for: "The media check result did not reach the main thread") { clockReads > 0 }
        print("PASS idle clock starts at tick 131 after the blocked media check finishes")

        clock = 190
        let previousReads = clockReads
        controller.check()
        try wait(for: "The 59-second check did not finish") { clockReads > previousReads }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        guard !helper.isTerminated else { throw CheckFailure("The fixture exited before 60 seconds of inactivity") }
        print("PASS fixture remains running at 59 seconds of inactivity")

        clock = 191
        controller.check()
        try wait(for: "The fixture did not exit at 60 seconds of inactivity") { helper.isTerminated }
        print("PASS fixture exits normally at 60 seconds of inactivity")
    }
}
