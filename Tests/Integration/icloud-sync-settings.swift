// Injected into a temporary copy of main.swift. No Model, Delegate, history or service startup.
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
NSApplication.shared.setActivationPolicy(.regular)
private let syncFixture = SyncSettingsFixture()
DispatchQueue.main.async { syncFixture.show() }
NSApplication.shared.run()
