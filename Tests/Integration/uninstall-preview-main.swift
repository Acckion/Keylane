// Production sources, fresh preference domain and temporary home. No services are
// started and no uninstall operation is invoked; review callbacks are recording spies.
let probeHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!, isDirectory: true)
precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == probeHome.resolvingSymlinksInPath())
precondition(Bundle.main.bundleIdentifier?.hasPrefix("org.keylane.test.uninstall-preview.") == true)
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
review.toggle("/not-in-snapshot")
expect(review.selected == [alpha.path], "unknown selection is ignored")
review.prepare(name: "New", detail: "No leftovers", items: [.init(url: beta, isApplication: true)], confirm: { submissions.append($0) }, cancel: { cancellations += 1 })
expect(review.selected == [beta.path] && review.query.isEmpty && review.sort == .path, "replacement resets query sorting and selection")
review.clear()
expect(!review.canSubmit && review.visible.isEmpty, "leaving review disables submission")
// Exercise the same leave/resume hooks used by the registered page, without Model services.
var resumedPage = ApplicationUninstallReview.pageID
let uninstallSelection = PageID(rawValue: "ApplicationUninstall")
let lifecyclePage = LauncherPage(id: ApplicationUninstallReview.pageID, placeholder: "",
    leave: review.clear, resume: { review.resume { resumedPage = uninstallSelection } })
prepareReview()
lifecyclePage.resume?()
expect(resumedPage == ApplicationUninstallReview.pageID && review.canSubmit, "active snapshot is not redirected")
let beforeHideSubmissions = submissions.count
let beforeHideCancellations = cancellations
lifecyclePage.leave()
lifecyclePage.resume?()
review.submit()
expect(resumedPage == uninstallSelection, "hide then resume returns to application selection")
expect(review.items.isEmpty && review.selected.isEmpty && !review.canSubmit && submissions.count == beforeHideSubmissions,
       "resume never restores cancelled deletion consent")
lifecyclePage.resume?()
expect(cancellations == beforeHideCancellations + 1, "repeated resume does not repeat cancellation")
print("PASS uninstall preview state regression (recording callbacks; no real uninstall)")
if !CommandLine.arguments.contains("--interactive") { exit(0) }
prepareReview()
struct ReviewVerificationView: View {
    @ObservedObject var review: ApplicationUninstallReview
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            Text("卸载预览 · 隔离演示").font(.headline).padding()
            HStack {
                TextField("筛选文件和文件夹…", text: $query)
                    .onChange(of: query) { _, text in review.filter(text) }
                ApplicationUninstallSortPicker(review: review)
                Button("重新准备") { prepareReview(); query = "" }
            }.padding()
            ApplicationUninstallReviewPage(review: review)
            HStack {
                Button("取消") { review.clear() }
                Button("演示确认（不删除）") { review.submit() }.disabled(!review.canSubmit)
            }.padding()
        }.frame(width: 760, height: 530)
    }
}
let testWindow = NSWindow(contentRect: NSRect(x: 160, y: 160, width: 760, height: 530), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
testWindow.title = "Keylane Uninstall Preview — Isolated Data"
testWindow.contentView = NSHostingView(rootView: ReviewVerificationView(review: review))
testWindow.makeKeyAndOrderFront(nil)
NSApp.activate(ignoringOtherApps: true)
NSApp.run()
