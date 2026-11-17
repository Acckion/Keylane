import AppKit

/// Bounded local lifecycle log. Never includes text, paths, app names or document contents.
final class WindowDiagnostics {
    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/Diagnostics/window-events.json")
    }

    static func recentEventsForFeedback() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let records = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let fields = Set(["time", "launcherVisible", "launcherKey", "settingsVisible", "hotkeyStatus", "displayCount"])
        let eventNames = Set(["reopen", "shown", "shownSettled", "hidden:command", "hidden:pasteDispatch",
                              "hidden:outsideClick", "hidden:otherWindow", "hidden:resignKey"])
        let recent = records.suffix(6).map { event in
            var safe = event.filter { fields.contains($0.key) && $0.value is NSNumber }
            if let name = event["event"] as? String, eventNames.contains(name) { safe["event"] = name }
            return safe
        }
        guard !recent.isEmpty, let encoded = try? JSONSerialization.data(withJSONObject: recent, options: [.sortedKeys]),
              encoded.count <= 2048 else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    private var entries: [[String: Any]] = []
    func record(_ event: String, launcher: NSWindow, settings: NSWindow?, hotkeyStatus: Int32) {
        entries.append(["event": event, "time": Date().timeIntervalSince1970, "launcherVisible": launcher.isVisible, "launcherKey": launcher.isKeyWindow, "settingsVisible": settings?.isVisible ?? false, "hotkeyStatus": hotkeyStatus, "displayCount": NSScreen.screens.count])
        entries = Array(entries.suffix(32))
        do {
            let url = Self.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        } catch { NSLog("Keylane: could not write window diagnostics") }
    }
}
