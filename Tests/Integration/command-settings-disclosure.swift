// Appended to a temporary copy of the app's main.swift by the UI fixture script.
// Uses the production list with in-memory data; never instantiates Model/Delegate.
private struct CommandDisclosureFixture: View {
    @State private var expanded = Set<String>()
    @State private var aliases: [String: String] = [:]
    @State private var enabled = Set(Self.titles)
    @State private var dark = true
    private static let titles = ["剪贴板历史", "顺序粘贴", "搜索文字片段", "搜索菜单项", "普通命令"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("命令展开回归 · 隔离演示数据").font(.headline)
            HStack {
                Toggle("深色演示", isOn: $dark)
                Button("保存窗口证据") { saveEvidence() }
            }
            CommandSettingsList(items: Self.titles, id: \.self, disclosure: { title in
                guard title != "普通命令" else { return nil }
                return CommandSettingsDisclosure(isExpanded: Binding(
                    get: { expanded.contains(title) },
                    set: { value in
                        if value { expanded.insert(title) } else { expanded.remove(title) }
                        print("\(title): \(value ? "expanded" : "collapsed")")
                        fflush(stdout)
                    }
                )) {
                    AnyView(SettingsRowsLayout {
                        SettingsRow("演示子项", detail: "仅用于检查展开、收起和背景；不读取实际历史。") {
                            Text("30 秒").foregroundStyle(.secondary)
                        }
                    })
                }
            }) { title in
                CommandSettingsEntry(title: title,
                                     alias: Binding(get: { aliases[title] ?? "" }, set: { aliases[title] = $0 }),
                                     shortcut: nil,
                                     isEnabled: Binding(get: { enabled.contains(title) }, set: { value in
                                         if value { enabled.insert(title) } else { enabled.remove(title) }
                                     }), setShortcut: { _ in }, icon: { SettingsIcon(symbol: "clipboard") })
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 680, height: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func saveEvidence() {
        guard let view = NSApp.keyWindow?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_UI_EVIDENCE"] ?? NSTemporaryDirectory())
        let state = expanded.isEmpty ? "collapsed" : expanded.count == 4 ? "expanded" : "mixed"
        let url = directory.appendingPathComponent("\(dark ? "dark" : "light")-\(state).png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        print("Evidence: \(url.lastPathComponent)")
        fflush(stdout)
    }
}

let fixtureApplication = NSApplication.shared
fixtureApplication.setActivationPolicy(.regular)
let fixtureWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 650),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
fixtureWindow.title = "Keylane — command disclosure fixture"
fixtureWindow.contentView = NSHostingView(rootView: CommandDisclosureFixture())
fixtureWindow.center()
fixtureWindow.makeKeyAndOrderFront(nil)
fixtureApplication.activate(ignoringOtherApps: true)
fixtureApplication.run()
