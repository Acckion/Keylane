import AppKit
import SwiftUI
import KeylaneCore
@testable import Keylane

// Uses compiled production components. No Model, Delegate, history or service startup.
private final class SyncSettingsFixture {
    private var window: NSWindow?
    func show() {
        let suite = "org.keylane.tests.sync-ui." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let controller = CloudSyncController(model: nil, defaults: defaults)
        let view = VStack(spacing: 0) {
            HStack {
                Text("iCloud 同步 · 隔离预览").font(.headline)
                Spacer()
                Toggle("启用 iCloud 同步", isOn: .constant(false)).labelsHidden().toggleStyle(.switch).disabled(true)
            }.padding(16)
            SettingsPageContainer(pageID: "cloud-sync", title: "iCloud 同步", symbol: "icloud", subtitle: "让设置与内容在你的 Mac 之间保持一致。", target: nil,
                                  headerScrolledAway: .constant(false)) { CloudSyncSettings(sync: controller) }
        }.environment(\.colorScheme, .dark)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 740, height: 820),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Keylane iCloud 同步预览"
        window.contentView = NSHostingView(rootView: view)
        window.center(); window.makeKeyAndOrderFront(nil); self.window = window
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let path = ProcessInfo.processInfo.environment["KEYLANE_SYNC_UI_IMAGE"]!
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
            try? capture.run(); capture.waitUntilExit()
            defaults.removePersistentDomain(forName: suite)
            NSApp.terminate(nil)
        }
    }
}
private func verifySyncAdapters() throws {
    let files = FileManager.default
    let root = files.temporaryDirectory.appendingPathComponent("keylane-sync-adapters-" + UUID().uuidString)
    try files.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: root) }
    func require(_ condition: Bool, line: UInt = #line) throws { if !condition { throw NSError(domain: "KeylaneSyncAdapterFixture", code: Int(line)) } }
    let source = AIChatHistory(url: root.appendingPathComponent("source/history.sqlite"))
    let target = AIChatHistory(url: root.appendingPathComponent("target/history.sqlite"))
    let connection = AIConnection(name: "Synthetic", endpoint: "https://example.invalid", model: "fixture", mode: .complete)
    let id = UUID()
    try source.save(.init(id: id, content: .init(model: .init(connection), turns: [.init(question: "Synthetic question", answer: "Synthetic answer", complete: true)], instructions: "Synthetic instruction")))
    try source.update(id, change: .rename("Synthetic title")); try source.update(id, change: .pin(true)); try source.update(id, change: .archive(true))
    let values = try source.snapshot().values
    try target.apply(id: id.uuidString, data: values[id.uuidString])
    try require(try target.current(id: id.uuidString) == values[id.uuidString])
    let summary = try target.list().first
    try require(summary?.title == "Synthetic title" && summary?.pinned == true && summary?.archived == true)
    try require(try target.load(id)?.content.turns.first?.answer == "Synthetic answer")
    try require(try source.list().first?.updated == summary?.updated)
    try target.apply(id: id.uuidString, data: nil); try require(try target.list().isEmpty)

    let snippet = Snippet(title: "Synthetic snippet", text: "Synthetic body")
    let a = root.appendingPathComponent("snippets-A.sqlite"), b = root.appendingPathComponent("snippets-B.sqlite")
    let record = try snippet.record()
    try Store(url: a).save(record)
    let data = try SnippetsSyncParticipant(url: a).snapshot().values[record.id]
    try require(data != nil)
    try SnippetsSyncParticipant(url: b).apply(id: record.id, data: data)
    try require(try Store(url: b).records(kind: "snippet").first?.id == record.id)
    try require(try SnippetsSyncParticipant(url: b).current(id: record.id) == data)
    let participant = SnippetsSyncParticipant(url: b)
    let originalFingerprint = try participant.fingerprint(id: record.id)
    var newer = record; newer.title = "Saved locally during sync"
    try Store(url: b).save(newer)
    do { _ = try participant.applyIfUnchanged(id: record.id, data: data, fingerprint: originalFingerprint); throw NSError(domain: "KeylaneSyncAdapterFixture", code: 5) }
    catch SyncError.cancelled { }
    try require(try Store(url: b).record(id: record.id)?.title == newer.title)
    var mismatched = record; mismatched.id = "snippet:" + UUID().uuidString
    do { try SnippetsSyncParticipant(url: b).apply(id: mismatched.id, data: SyncHash.encode(mismatched)); throw NSError(domain: "KeylaneSyncAdapterFixture", code: 3) }
    catch SyncError.invalidData { }
    try require(try Store(url: b).records(kind: "snippet").count == 1)

    let defaults = UserDefaults.standard
    defer {
        for key in [QuicklinkLibrary.storageKey, "windowManagement.customActions", "appearance", "fixture.private-key"] { defaults.removeObject(forKey: key) }
    }
    let link = Quicklink(title: "Synthetic link", template: "https://example.invalid/")
    try QuicklinkLibrary(links: [link]).save(to: defaults)
    let links = QuicklinksSyncParticipant(), linkData = try links.snapshot().values[link.id]
    try links.apply(id: link.id, data: nil); try require(try QuicklinkLibrary.load(from: defaults).links.isEmpty)
    try links.apply(id: link.id, data: linkData); try require(try QuicklinkLibrary.load(from: defaults).links == [link])
    let invalidLink = Quicklink(id: "invalid-prefix", title: "Synthetic invalid", template: "https://example.invalid/")
    do { try links.apply(id: invalidLink.id, data: SyncHash.encode(invalidLink)); throw NSError(domain: "KeylaneSyncAdapterFixture", code: 4) }
    catch SyncError.invalidData { }
    try require(try QuicklinkLibrary.load(from: defaults).links == [link])

    var layout = CustomWindowAction(); layout.name = "Synthetic layout"
    let layouts = LayoutsSyncParticipant()
    try layouts.apply(id: layout.id.uuidString, data: SyncHash.encode(layout))
    try require(try layouts.snapshot().payloads.count == 1)
    defaults.set("dark", forKey: "appearance"); defaults.set("synthetic-never-export", forKey: "fixture.private-key")
    let preferences = DefaultsSyncParticipant(.preferences, keys: ["appearance"])
    try require(try Set(preferences.snapshot().payloads.keys) == ["appearance"])
    do { try preferences.apply(id: "fixture.private-key", data: nil); throw NSError(domain: "KeylaneSyncAdapterFixture", code: 2) }
    catch SyncError.invalidData { }
    try require(defaults.string(forKey: "fixture.private-key") == "synthetic-never-export")
    print("Isolated AI chat, snippets, quicklinks, layout and preference adapters passed")
}

// The fixture is linked against production objects with a separate explicit entry point.
// The app's original main (Model/Delegate/services) is linked but never executed.
@_cdecl("KeylaneSyncFixtureMain")
public func runSyncSettingsFixture(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    // This bundle has its own defaults domain. Verify command membership and order do not
    // mutate each other's sync fingerprint; never construct the real application model.
    guard Bundle.main.bundleIdentifier == "org.keylane.tests.icloud-sync" else { return 2 }
    do { try verifySyncAdapters() } catch {
        let failure = error as NSError
        print("Isolated sync adapters failed: domain=\(failure.domain), code=\(failure.code)"); return 2
    }
    let defaults = UserDefaults.standard
    defaults.set(["a", "b"], forKey: "favorites"); defaults.set(["b", "a"], forKey: "favoriteOrder")
    do {
        let participant = CommandsSyncParticipant()
        let before = try participant.snapshot().values["favorite/a"]
        try participant.apply(id: "favorite-order", data: SyncHash.encode(["a", "b"]))
        guard try participant.snapshot().values["favorite/a"] == before else { return 2 }
        try participant.apply(id: "favorite/c", data: SyncHash.encode(true))
        guard defaults.stringArray(forKey: "favoriteOrder") == ["a", "b"],
              Set(defaults.stringArray(forKey: "favorites") ?? []) == ["a", "b", "c"] else { return 2 }
        defaults.removeObject(forKey: "favorites"); defaults.removeObject(forKey: "favoriteOrder")
        print("Isolated command sync membership/order validation passed")
    } catch { return 2 }
    NSApplication.shared.setActivationPolicy(.regular)
    let fixture = SyncSettingsFixture()
    DispatchQueue.main.async { fixture.show() }
    NSApplication.shared.run()
    return 0
}
