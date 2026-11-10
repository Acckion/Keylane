import AppKit

/// Bounded local lifecycle log. Never includes text, paths, app names or document contents.
final class WindowDiagnostics {
    private var entries: [[String: Any]] = []
    func record(_ event: String, launcher: NSWindow, settings: NSWindow?, hotkeyStatus: Int32) {
        entries.append(["event": event, "time": Date().timeIntervalSince1970, "launcherVisible": launcher.isVisible, "launcherKey": launcher.isKeyWindow, "settingsVisible": settings?.isVisible ?? false, "hotkeyStatus": hotkeyStatus, "displayCount": NSScreen.screens.count])
        entries = Array(entries.suffix(32))
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/Diagnostics")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("window-events.json"), options: .atomic)
        } catch { NSLog("Keylane: could not write window diagnostics") }
    }
}
