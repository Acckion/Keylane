// Production sources, fresh preference domain and temporary home. No services are
// started and no uninstall operation is invoked; review callbacks are recording spies.
let probeHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!, isDirectory: true)
precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == probeHome.resolvingSymlinksInPath())
precondition(Bundle.main.bundleIdentifier?.hasPrefix("org.keylane.test.application-menu.") == true)
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
            }.padding(16)
            ApplicationUninstallReviewPage(review: review)
            Button("演示确认（仅记录，不删除）", action: review.submit).disabled(!review.canSubmit).padding(12)
        }
        .frame(width: 760, height: 530)
        .toolbar { ToolbarItem { ApplicationAutoQuitAddButton(model: model) } }
    }
}
let testWindow = NSWindow(contentRect: NSRect(x: 160,y: 160,width: 760,height: 530),styleMask: [.titled,.closable,.resizable],backing: .buffered,defer: false)
testWindow.title = "Keylane Menu Verification — Isolated Data"
testWindow.contentView = NSHostingView(rootView: MenuVerificationView(model: model, review: review))
testWindow.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
drain(0.4)
if CommandLine.arguments.contains("--interactive") {
    print("Interactive production UI fixture; no deletion handler or background services. Home: \(probeHome.path)")
    NSApp.run()
} else {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
    func nativeButtons(_ view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(nativeButtons)
    }
    func openPicker() {
        let views = testWindow.toolbar?.items.compactMap(\.view) ?? []
        guard let button = views.flatMap(nativeButtons).first(where: { $0.toolTip == "添加自动退出应用" }) else {
            preconditionFailure("Production toolbar button unavailable")
        }
        button.performClick(nil)
        drain(0.3)
        expect(popoverEditor() != nil, "production popover opens")
        expect(popoverEditor()?.window?.isKeyWindow == true, "popover is key for real keyboard dispatch")
    }
    func popoverEditor() -> NSTextView? {
        NSApp.windows.filter(\.isVisible).compactMap { $0.firstResponder as? NSTextView }.first { $0.window !== testWindow }
    }
    func typeKey(_ chars: String, code: UInt16) {
        guard let editor = popoverEditor(), let window = editor.window else { preconditionFailure("Popover lost editor") }
        // Dispatch only to this fixture's native editor, never to the system event stream.
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: chars,
                                    charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        NSApp.sendEvent(event)
        drain()
    }
    openPicker()
    expect(popoverEditor() != nil, "popover receives native field-editor focus")
    typeKey("d", code: 2)
    expect(popoverEditor()?.string == "d", "ordinary letter stays in open popover")
    typeKey("\u{7f}", code: 51)
    expect(popoverEditor()?.string == "", "backspace edits without dismissing")
    guard let editor = popoverEditor() else { preconditionFailure() }
    editor.setMarkedText("bei", selectedRange: NSRange(location: 3,length: 0), replacementRange: NSRange(location: NSNotFound,length: 0))
    drain()
    expect(popoverEditor()?.hasMarkedText() == true, "native marked-text composition keeps the popover open")
    editor.insertText("备", replacementRange: NSRange(location: 0,length: editor.string.utf16.count))
    editor.unmarkText()
    drain()
    expect(popoverEditor()?.string == "备", "committed Chinese text remains searchable")
    typeKey("\u{1b}", code: 53)
    expect(popoverEditor() == nil, "Escape dismisses popover")
    openPicker()
    expect(popoverEditor()?.string == "", "reopening resets the query")
    typeKey("d", code: 2)
    typeKey("\u{f701}", code: 125)
    typeKey("\u{f700}", code: 126)
    typeKey("\u{f701}", code: 125)
    typeKey("\r", code: 36)
    expect(model.applicationAutoQuit.minutes(for: beta) != 0 && model.applicationAutoQuit.minutes(for: alpha) == 0,
           "Down Up Down Return chooses only the highlighted fake application")
    expect(popoverEditor() == nil, "choosing an application dismisses the popover")
    openPicker()
    typeKey("z", code: 6)
    typeKey("\r", code: 36)
    expect(popoverEditor()?.string == "z", "Return with no results keeps the picker open")
    typeKey("\u{1b}", code: 53)
    let duration = nativeButtons(testWindow.contentView!).first { $0.toolTip == "默认自动退出时长" }
    expect(duration != nil, "duration control is present")
    duration?.performClick(nil)
    drain(0.3)
    typeKey("1", code: 18)
    typeKey("0", code: 29)
    expect(popoverEditor()?.string == "10", "duration search stays open")
    typeKey("\r", code: 36)
    expect(model.applicationAutoQuit.defaultMinutes == 10 && popoverEditor() == nil, "duration Return selects and dismisses")
    expect(FileManager.default.fileExists(atPath: data.path), "UI checks did not delete data")
    testWindow.orderOut(nil)
    model.applicationSettingsCatalog.stop()
    print("PASS application menu UI regression checks (synthetic native composition; physical IME still requires manual acceptance)")
    exit(0)
    }
    NSApp.run()
}
