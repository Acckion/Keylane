// Production sources, fresh preference domain and temporary home. No services are
// started and no uninstall operation is invoked; review callbacks are recording spies.
let probeHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!, isDirectory: true)
precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == probeHome.resolvingSymlinksInPath())
precondition(Bundle.main.bundleIdentifier?.hasPrefix("org.keylane.test.application-menu.") == true)
if CommandLine.arguments.contains("--settings-entry"), let domain = Bundle.main.bundleIdentifier {
    UserDefaults.standard.removePersistentDomain(forName: domain)
}
setbuf(stdout, nil)
let _ = NSApplication.shared
NSApp.setActivationPolicy(.regular)
NSApp.finishLaunching()
func expect(_ value: @autoclosure () -> Bool, _ label: String) {
    precondition(value(), label)
    print("PASS " + label)
}
func drain(_ seconds: Double = 0.12) { RunLoop.main.run(until: .now.addingTimeInterval(seconds)) }
func fixtureApp(_ name: String) throws -> URL {
    let app = probeHome.appendingPathComponent("Apps/\(name).app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "org.keylane.test.demo." + UUID().uuidString, "CFBundlePackageType": "APPL", "CFBundleName": name]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    return app
}
let alpha = try fixtureApp("Demo Alpha")
let beta = try fixtureApp("Demo Beta")
let chinese = try fixtureApp("备忘录演示")
let data = probeHome.appendingPathComponent("Library/Caches/org.keylane.demo")
try FileManager.default.createDirectory(at: data.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data("demo".utf8).write(to: data)
let review = ApplicationUninstallReview()
var submissions: [Set<String>] = []
var cancellations = 0
func prepareReview() {
    review.prepare(name: "Demo Alpha", detail: "隔离演示：操作仅记录选择，不移除文件。",
                   items: [.init(url: alpha, isApplication: true), .init(url: data)],
                   confirm: { submissions.append($0) }, cancel: { cancellations += 1 })
}
prepareReview()
expect(review.selected == [alpha.path], "leftovers are opt-in")
review.toggle(data.path)
review.filter("no matches")
expect(review.visible.isEmpty && review.selected.count == 2, "filtering preserves hidden selections")
review.sort = .name
review.filter("demo")
review.move(1)
review.toggleHighlighted()
expect(review.selected == [alpha.path], "keyboard highlight toggles only its target")
review.toggle(alpha.path)
expect(!review.canSubmit, "cannot remove leftovers without selecting the application")
review.submit()
expect(submissions.isEmpty, "disabled confirmation cannot submit")
review.toggle(alpha.path)
review.toggle(data.path)
review.submit(); review.submit()
expect(submissions == [[alpha.path, data.path]], "confirmation snapshots selection exactly once")
review.clear()
expect(cancellations == 0 && review.items.isEmpty, "completed confirmation is not cancelled twice")
prepareReview(); review.clear(); review.clear()
expect(cancellations == 1 && !review.canSubmit, "cancel invalidates stale confirmation exactly once")
expect(FileManager.default.fileExists(atPath: alpha.path) && FileManager.default.fileExists(atPath: data.path), "review and cancellation preserve fixture files")
prepareReview()
let model = Model()
model.apps = [alpha, beta, chinese]
model.applicationSettingsCatalog.start()
struct MenuVerificationView: View {
    let model: Model
    @ObservedObject var review: ApplicationUninstallReview
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SearchField(text: $query, placeholder: "筛选演示文件…", focusToken: 0, navigation: "arrows",
                            submit: review.submit, move: review.move, escape: review.clear)
                    .onChange(of: query) { _, text in review.filter(text) }
                AutoQuitDurationPicker(label: "默认自动退出时长", minutes: 3, defaultMinutes: nil, navigation: "arrows", select: model.applicationAutoQuit.setDefaultMinutes)
                if CommandLine.arguments.contains("--trace-input") { AppKitInputControl() }
            }.padding(16)
            ApplicationUninstallReviewPage(review: review)
            Button("演示确认（仅记录，不删除）", action: review.submit).disabled(!review.canSubmit).padding(12)
        }
        .frame(width: 760, height: 530)
        .toolbar { ToolbarItem { ApplicationAutoQuitAddButton(model: model) } }
    }
}
// A plain AppKit positive control distinguishes event-targeting problems from
// SwiftUI bindings, toolbar rebuilding, shortcuts and the production search view.
private struct AppKitInputControl: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSButton {
        NSButton(title: "AppKit 输入对照", target: context.coordinator, action: #selector(Coordinator.show(_:)))
    }
    func updateNSView(_ view: NSButton, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? { nsView.fittingSize }
    final class Coordinator: NSObject, NSPopoverDelegate {
        let popover = NSPopover()
        func popoverShouldClose(_ popover: NSPopover) -> Bool {
            print("TRACE control.popoverShouldClose event=\(String(describing: NSApp.currentEvent?.type))")
            return true
        }
        func popoverDidClose(_ notification: Notification) { print("TRACE control.popoverDidClose") }
        @objc func show(_ sender: NSButton) {
            let controller = NSViewController()
            let field = NSSearchField(frame: NSRect(x: 0,y: 0,width: 320,height: 40))
            field.placeholderString = "AppKit 对照搜索"
            field.setAccessibilityLabel("AppKit 对照搜索")
            controller.view = field
            popover.contentViewController = controller
            popover.behavior = .transient
            popover.delegate = self
            popover.animates = false
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            field.window?.makeKeyAndOrderFront(nil)
            field.window?.makeFirstResponder(field)
        }
    }
}
let testWindow = NSWindow(contentRect: NSRect(x: 160,y: 160,width: 760,height: 530),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
testWindow.title = "Keylane Menu Verification — Isolated Data"
if CommandLine.arguments.contains("--settings-entry") {
    model.settingsPage = SettingsItem.applicationAutoQuit.page
    let state = SettingsWindowState(model: model)
    testWindow.styleMask.insert(.fullSizeContentView)
    testWindow.setContentSize(NSSize(width: 740, height: 730))
    testWindow.title = "Keylane Settings Entry — Isolated Data"
    testWindow.contentView = NSHostingView(rootView: SettingsView(state: state))
} else {
    testWindow.contentView = NSHostingView(rootView: MenuVerificationView(model: model, review: review))
}
testWindow.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
drain(0.4)
if CommandLine.arguments.contains("--interactive") || CommandLine.arguments.contains("--trace-input") || CommandLine.arguments.contains("--settings-entry") {
    print("Interactive production UI fixture; no deletion handler or background services. Home: \(probeHome.path)")
    var observations: [NSObjectProtocol] = []
    var inputMonitor: Any?
    if CommandLine.arguments.contains("--trace-input") {
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                print("TRACE window=\(window.windowNumber) type=\(type(of: window)) notification=\(note.name.rawValue) event=\(String(describing: NSApp.currentEvent?.type))")
            })
        }
        func sourceID() -> String {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
            return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        print("TRACE source=\(sourceID())")
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .flagsChanged]) { event in
            let key = event.type == .keyDown || event.type == .flagsChanged ? Int(event.keyCode) : -1
            print("TRACE input=\(event.type) window=\(event.windowNumber) keyCode=\(key) modifiers=\(event.modifierFlags.rawValue) source=\(sourceID())")
            if event.type == .keyDown {
                let eventWindow = event.window
                DispatchQueue.main.async {
                    let marked = (eventWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
                    let menu = testWindow.contentView?.subviews.contains { $0.identifier?.rawValue == "KeylaneSettingsSearchMenu" } ?? false
                    print("TRACE handled marked=\(marked) inlineMenu=\(menu)")
                }
            }
            return event
        }
    }
    withExtendedLifetime((observations, inputMonitor)) { NSApp.run() }
} else {
    Task { @MainActor in
    func pause(_ seconds: Double = 0.12) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    await pause(0.4)
    func nativeButtons(_ view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(nativeButtons)
    }
    func openPicker() async {
        let views = testWindow.toolbar?.items.compactMap(\.view) ?? []
        guard let button = views.flatMap(nativeButtons).first(where: { $0.toolTip == "添加自动退出应用" }) else {
            preconditionFailure("Production toolbar button unavailable")
        }
        button.performClick(nil)
        await pause(0.3)
        expect(menuEditor() != nil, "production in-window menu opens")
        expect(menuEditor()?.window === testWindow, "menu editor stays in its original owner window")
    }
    func menuEditor() -> NSTextView? {
        guard testWindow.contentView?.subviews.contains(where: { $0.identifier?.rawValue == "KeylaneSettingsSearchMenu" }) == true else { return nil }
        return testWindow.firstResponder as? NSTextView
    }
    func typeKey(_ chars: String, code: UInt16) async {
        guard menuEditor() != nil else { preconditionFailure("Menu lost editor") }
        // No target window is specified. AppKit must route through this application's key window.
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: 0, context: nil, characters: chars,
                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        NSApp.postEvent(event, atStart: false)
        await pause()
    }
    await openPicker()
    expect(menuEditor() != nil, "menu receives native field-editor focus")
    await typeKey("d", code: 2)
    expect(menuEditor()?.string == "d", "unaddressed letter stays in open menu")
    await typeKey("\u{7f}", code: 51)
    expect(menuEditor()?.string == "", "backspace edits without dismissing")
    guard let editor = menuEditor() else { preconditionFailure() }
    editor.setMarkedText("bei", selectedRange: NSRange(location: 3,length: 0), replacementRange: NSRange(location: NSNotFound,length: 0))
    await pause()
    expect(menuEditor()?.hasMarkedText() == true, "native marked-text composition keeps the menu open")
    editor.insertText("备", replacementRange: NSRange(location: 0,length: editor.string.utf16.count))
    editor.unmarkText()
    await pause()
    expect(menuEditor()?.string == "备", "committed Chinese text remains searchable")
    await typeKey("\u{1b}", code: 53)
    expect(menuEditor() == nil, "Escape dismisses menu")
    await openPicker()
    expect(menuEditor()?.string == "", "reopening resets the query")
    await typeKey("d", code: 2)
    await typeKey("\u{f701}", code: 125)
    await typeKey("\u{f700}", code: 126)
    await typeKey("\u{f701}", code: 125)
    await typeKey("\r", code: 36)
    expect(model.applicationAutoQuit.minutes(for: beta) != 0 && model.applicationAutoQuit.minutes(for: alpha) == 0,
           "Down Up Down Return chooses only the highlighted fake application")
    expect(menuEditor() == nil, "choosing an application dismisses the menu")
    await openPicker()
    await typeKey("z", code: 6)
    await typeKey("\r", code: 36)
    expect(menuEditor()?.string == "z", "Return with no results keeps the picker open")
    await typeKey("\u{1b}", code: 53)
    let duration = nativeButtons(testWindow.contentView!).first { $0.toolTip == "默认自动退出时长" }
    expect(duration != nil, "duration control is present")
    duration?.performClick(nil)
    await pause(0.3)
    await typeKey("1", code: 18)
    await typeKey("0", code: 29)
    expect(menuEditor()?.string == "10", "duration search stays open")
    await typeKey("\r", code: 36)
    expect(model.applicationAutoQuit.defaultMinutes == 10 && menuEditor() == nil, "duration Return selects and dismisses")
    expect(FileManager.default.fileExists(atPath: data.path), "UI checks did not delete data")
    testWindow.orderOut(nil)
    model.applicationSettingsCatalog.stop()
    print("PASS application menu UI regression checks (synthetic native composition; physical IME still requires manual acceptance)")
    exit(0)
    }
    NSApp.run()
}
