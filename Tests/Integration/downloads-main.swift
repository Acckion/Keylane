import AppKit
import KeylaneCore

// Only the unused launcher dismissal is stubbed; the production catalog, watcher and controller run unchanged.
final class Delegate: NSObject, NSApplicationDelegate { func hideLauncher() {} }
@main struct DownloadsCheck {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneDownloads-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "org.keylane.test.downloads." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode(ScreenshotScope(path: root.path, bookmark: nil)), forKey: "downloads.folder")
        try Data([1]).write(to: root.appendingPathComponent("old.txt"))
        let controller = DownloadsController(defaults: defaults)
        var received: [URL] = []
        controller.addToShelf = { received += $0; return true }
        controller.refresh()
        try require(controller.files.isEmpty, "Disabled downloads must not scan")
        controller.setEnabled(true)
        try await wait { controller.files.count == 1 }
        try require(received.isEmpty && !controller.autoShelf, "Automatic shelf delivery must default off")
        controller.sendSelectedToShelf()
        try require(received.count == 1, "Manual action must use shared integration callback")
        controller.query = "missing"
        try require(controller.selected == nil, "Filtering must clear stale action targets")
        controller.query = ""
        controller.autoShelf = true
        try await Task.sleep(for: .milliseconds(500))
        try require(received.count == 1, "Enabling auto delivery must seed existing files")
        let temporary = root.appendingPathComponent("new.zip.crdownload")
        try Data([2]).write(to: temporary)
        controller.refresh()
        try await Task.sleep(for: .milliseconds(500))
        try require(!controller.files.contains { $0.url == temporary } && received.count == 1, "Partial downloads must be ignored")
        try FileManager.default.moveItem(at: temporary, to: root.appendingPathComponent("new.zip"))
        try await wait { received.count == 2 }
        try require(received[1].lastPathComponent == "new.zip", "Completed name must settle and arrive once")
        controller.refresh(); try await Task.sleep(for: .milliseconds(400))
        try require(received.count == 2, "Repeated events must not create duplicate shelves")
        controller.setEnabled(false)
        try Data([3]).write(to: root.appendingPathComponent("disabled.txt"))
        try await Task.sleep(for: .seconds(3))
        try require(controller.files.isEmpty && received.count == 2, "Stopping must clear UI and stop delivery")
        print("PASS downloads: opt-in, baseline, manual shelf action, filtering, temporary download, rename, stable delivery, duplicate, disable")
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try require(condition(), "Timed out waiting for filesystem observation")
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "DownloadsCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
