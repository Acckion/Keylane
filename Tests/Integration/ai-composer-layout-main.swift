import AppKit
import SwiftUI

NSApplication.shared.setActivationPolicy(.prohibited)
struct Probe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView { let view = NSView(); view.identifier = .init(name); return view }
    func updateNSView(_ view: NSView, context: Context) {}
}
func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
let output = URL(fileURLWithPath: "/private/tmp/keylane-composer-layout-preview", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for style in [ConversationComposerStyle.chat, .launcher] {
    for multiline in [false, true] {
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: NSFont.systemFont(ofSize: 14)))
        let height: CGFloat = style.editorMinimumHeight + (multiline ? 2 * lineHeight : 0)
        let composer = AIConversationComposer()
        composer.text = multiline ? "第一行合成文字\n第二行合成文字\n第三行合成文字" : ""
        let row = ConversationComposer(style: style) {
            AIConversationTextInput(composer: composer, height: .constant(height), enabled: true,
                sendWithReturn: true, menuVisible: false, submit: {}, moveMenu: { _ in },
                chooseMenu: {}, dismissMenu: {}, placeholder: style == .launcher ? "向 AI 提问…" : "输入问题…",
                minimumHeight: style.editorMinimumHeight)
                .frame(height: height).background(Probe(name: "editor"))
        } actions: {
            Image(systemName: "arrow.up").frame(width: style.actionControlSide, height: style.actionControlSide)
                .background(Probe(name: "action"))
        } addButton: {
            ConversationFooterButton(title: "添加上下文", symbol: "plus", diameter: style.controlDiameter, action: {})
                .modifier(LauncherMenuSurface(open: false, cornerRadius: style.controlDiameter / 2)).background(Probe(name: "add"))
        }
        let preview = ZStack(alignment: .bottom) {
            row
            if style == .launcher {
                HStack {
                    ConversationFooterButton(title: "对话选项", symbol: "plus", action: {})
                        .modifier(LauncherMenuSurface(open: false)).background(Probe(name: "host-add"))
                    Spacer()
                    ConversationFooterButton(title: "操作", symbol: "command", action: {})
                        .modifier(LauncherMenuSurface(open: false))
                }
            }
        }
        let host = NSHostingView(rootView: preview.frame(width: 760).padding(20))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: height + 52), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        if ProcessInfo.processInfo.environment["KEYLANE_COMPOSER_CAPTURE"] == "1" {
            window.backgroundColor = .windowBackgroundColor
            window.center()
            window.orderFrontRegardless()
        }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        func rect(_ name: String) -> NSRect? {
            guard let view = descendants(host).first(where: { $0.identifier?.rawValue == name }) else { return nil }
            return host.convert(view.bounds, from: view)
        }
        let editor = rect("editor")!, action = rect("action")!
        precondition(abs(action.height - style.actionControlSide) < 0.5)
        if !multiline { precondition(abs(action.midY - editor.midY) < 0.5, "Single-line actions must be centered") }
        if style == .chat {
            let add = rect("add")!
            precondition(abs(add.width - style.fieldMinimumHeight) < 0.5 && abs(add.height - style.fieldMinimumHeight) < 0.5)
            precondition(abs(add.midY - action.midY) < 0.5, "Add and inline controls must share the action line")
            precondition(editor.minX - add.maxX >= 23.5, "The add button must be outside the input surface")
            if !multiline { precondition(abs(host.fittingSize.height - 88) < 0.5, "Chat single-line field must be 48pt") }
        } else {
            precondition(rect("add") == nil, "Launcher owns its existing plus; never duplicate it")
            precondition(abs(rect("host-add")!.midY - action.midY) < 0.5, "Launcher controls must align to the final editor line")
            precondition(editor.minX >= 77.5 && editor.maxX <= 722.5, "Reserve both Launcher footer control areas")
            if !multiline { precondition(abs(host.fittingSize.height - 76) < 0.5, "Restore the original 36pt Launcher field") }
        }
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let name = (style == .chat ? "chat" : "quick-ai") + (multiline ? "-multiline" : "-single")
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
        if ProcessInfo.processInfo.environment["KEYLANE_COMPOSER_CAPTURE"] == "1" {
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), output.appendingPathComponent(name + "-window.png").path]
            try capture.run(); capture.waitUntilExit()
            precondition(capture.terminationStatus == 0, "Window capture requires Screen Recording access")
        }
        window.close()
    }
}
print("PASS native composer geometry: Chat 48pt capsule, equal-height external add control, centered actions, multiline action line, and Quick AI host-control reservations; no models or user data")

// Use the actual shared panel and actual composer menu, with synthetic actions only.
let panel = LauncherActionMenuPanel(title: "Quick AI") {
    Color.clear.frame(height: 39).background(Probe(name: "menu-row"))
} search: {
    TextField("搜索操作…", text: .constant("")).textFieldStyle(.plain)
        .background(Probe(name: "menu-search"))
}
let panelHost = NSHostingView(rootView: panel)
panelHost.frame = NSRect(x: 0, y: 0, width: 345, height: 126)
panelHost.layoutSubtreeIfNeeded()
let panelViews = descendants(panelHost)
let row = panelViews.first { $0.identifier?.rawValue == "menu-row" }!
let search = panelViews.first { $0.identifier?.rawValue == "menu-search" }!
let rowRect = panelHost.convert(row.bounds, from: row)
let searchRect = panelHost.convert(search.bounds, from: search)
precondition(abs(panelHost.fittingSize.width - 345) < 0.5)
precondition(panelHost.isFlipped ? searchRect.minY > rowRect.maxY : searchRect.maxY < rowRect.minY,
             "The search control must remain below the action list")
let menu = AIConversationComposerMenu(items: [
    .init(id: "file", section: "上下文", title: "附加文件…", symbol: "doc.badge.plus", action: {})
], query: .constant(""), selection: .constant("file"), scrollTarget: .constant(nil),
   searchable: true, menuTitle: "Quick AI", activate: { _ in }, dismiss: {})
let menuHost = NSHostingView(rootView: menu)
let menuWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 345, height: 126),
    styleMask: [.borderless], backing: .buffered, defer: false)
menuWindow.isReleasedWhenClosed = false
menuWindow.appearance = NSAppearance(named: .darkAqua)
menuWindow.contentView = menuHost
menuHost.layoutSubtreeIfNeeded()
if ProcessInfo.processInfo.environment["KEYLANE_COMPOSER_CAPTURE"] == "1" {
    menuWindow.center(); menuWindow.orderFrontRegardless()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(menuWindow.windowNumber), output.appendingPathComponent("add-menu-window.png").path]
    try capture.run(); capture.waitUntilExit()
    precondition(capture.terminationStatus == 0)
}
menuWindow.close()
print("PASS shared corner menu: 345pt panel, title and full-size action rows, bottom search; same shell as Launcher")

final class MenuMotionState: ObservableObject { @Published var open = false }
struct MenuMotionPreview: View {
    @ObservedObject var state: MenuMotionState
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            LauncherExpandingMenu(open: state.open, closedSize: CGSize(width: 48, height: 48),
                                  menuSize: CGSize(width: 345, height: 126), dismiss: { state.open = false }) {
                ConversationFooterButton(title: "添加", symbol: "plus", diameter: 48, action: {})
            } menu: {
                LauncherActionMenuPanel(title: "AI Chat") {
                    Text("附加文件…").frame(height: 39)
                } search: { Text("搜索操作…") }
            }
            .background(Probe(name: "expanding-surface"))
            .frame(width: 48, height: 48, alignment: .bottomLeading).zIndex(1)
            Text("输入问题…").font(.system(size: 14)).foregroundStyle(.secondary)
                .frame(width: 704, height: 48)
                .background(.regularMaterial, in: Capsule()).background(Probe(name: "stationary-input"))
        }.padding(20)
    }
}
let motionState = MenuMotionState()
let motionHost = NSHostingView(rootView: MenuMotionPreview(state: motionState).frame(width: 800, height: 300, alignment: .bottomLeading))
let motionWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
    styleMask: [.borderless], backing: .buffered, defer: false)
motionWindow.isReleasedWhenClosed = false
motionWindow.contentView = motionHost
motionWindow.appearance = NSAppearance(named: .darkAqua)
motionWindow.backgroundColor = .windowBackgroundColor
motionWindow.center()
motionWindow.orderFrontRegardless()
func captureMotion(_ phase: String) throws {
    guard ProcessInfo.processInfo.environment["KEYLANE_COMPOSER_CAPTURE"] == "1" else { return }
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(motionWindow.windowNumber),
        output.appendingPathComponent("motion-" + phase + ".png").path]
    try capture.run(); capture.waitUntilExit()
    precondition(capture.terminationStatus == 0)
}
func motionRect(_ name: String) -> NSRect {
    motionHost.layoutSubtreeIfNeeded()
    let view = descendants(motionHost).first { $0.identifier?.rawValue == name }!
    return motionHost.convert(view.bounds, from: view)
}
RunLoop.current.run(until: Date().addingTimeInterval(0.05))
let closedSurface = motionRect("expanding-surface")
let stationaryInput = motionRect("stationary-input")
try captureMotion("closed")
motionState.open = true
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
try captureMotion("opening")
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
try captureMotion("open")
let openSurface = motionRect("expanding-surface")
precondition(abs(openSurface.width - 345) < 0.5 && abs(openSurface.height - 126) < 0.5)
precondition(abs(openSurface.minX - closedSurface.minX) < 0.5)
precondition(abs((motionHost.isFlipped ? openSurface.maxY : openSurface.minY) -
                 (motionHost.isFlipped ? closedSurface.maxY : closedSurface.minY)) < 0.5,
             "The bottom corner must stay fixed while the menu expands")
precondition(motionRect("stationary-input") == stationaryInput, "Menu expansion must not move the input")
motionState.open = false
RunLoop.current.run(until: Date().addingTimeInterval(0.02))
try captureMotion("closing")
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
try captureMotion("collapsed")
precondition(motionRect("expanding-surface") == closedSurface)
motionState.open = true
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
let integratedBoundary = descendants(motionHost).compactMap { $0 as? MenuOutsideClickDismissal.BoundaryView }.first!
precondition(integratedBoundary.monitoring)
fixtureClick(motionWindow, point: integratedBoundary.convert(NSPoint(x: 10, y: integratedBoundary.bounds.maxY - 10), to: nil))
precondition(motionState.open, "The expanded region above the closed button must count as inside the menu")
fixtureClick(motionWindow, point: motionHost.convert(NSPoint(x: stationaryInput.maxX - 2, y: stationaryInput.midY), to: nil))
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
precondition(!motionState.open && !integratedBoundary.monitoring)
precondition(motionRect("expanding-surface") == closedSurface)
precondition(motionRect("stationary-input") == stationaryInput)
motionWindow.close()
print("PASS integrated expanding menu: full expanded hit boundary, outside-click collapse and fixed input")
print("PASS shared expanding surface: anchored bottom corner, 48pt/345pt open-close sizes, stationary input and reversible collapse")

// Synthetic events remain inside this fixture process; no pointer or global input events.
final class MenuClickTarget: NSView {
    var clicks = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1; window?.makeFirstResponder(self) }
    override func rightMouseDown(with event: NSEvent) { clicks += 1 }
}
enum FixtureMouseEvents { static var nextNumber = 0 }
func fixtureClick(_ window: NSWindow, point: NSPoint, type: NSEvent.EventType = .leftMouseDown) {
    FixtureMouseEvents.nextNumber += 1
    let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: FixtureMouseEvents.nextNumber, clickCount: 1, pressure: 1)!
    NSApp.sendEvent(event)
    let release = NSEvent.mouseEvent(with: type == .rightMouseDown ? .rightMouseUp : .leftMouseUp,
        location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, eventNumber: FixtureMouseEvents.nextNumber,
        clickCount: 1, pressure: 0)!
    NSApp.sendEvent(release)
}
let clickWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
    styleMask: [.borderless], backing: .buffered, defer: false)
clickWindow.isReleasedWhenClosed = false
let clickRoot = MenuClickTarget(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
clickWindow.contentView = clickRoot
let insideTarget = MenuClickTarget(frame: NSRect(x: 20, y: 20, width: 120, height: 100))
let outsideTarget = MenuClickTarget(frame: NSRect(x: 200, y: 20, width: 100, height: 100))
clickRoot.addSubview(insideTarget); clickRoot.addSubview(outsideTarget)
let boundary = MenuOutsideClickDismissal.BoundaryView(frame: insideTarget.frame)
clickRoot.addSubview(boundary)
clickWindow.orderFrontRegardless()
var dismissals = 0
func presentBoundary() { boundary.configure(presented: true) { dismissals += 1 } }
presentBoundary()
precondition(boundary.monitoring)
fixtureClick(clickWindow, point: NSPoint(x: 60, y: 60))
precondition(dismissals == 0 && insideTarget.clicks == 1, "Inside clicks must remain interactive without dismissing: dismissed=\(dismissals), clicks=\(insideTarget.clicks), boundary=\(boundary.frame)")
fixtureClick(clickWindow, point: NSPoint(x: 240, y: 60))
precondition(dismissals == 1 && !boundary.monitoring, "Outside click must dismiss and release its monitor")
precondition(outsideTarget.clicks == 1 && clickWindow.firstResponder === outsideTarget,
             "The outside click must reach and focus its original target")
fixtureClick(clickWindow, point: NSPoint(x: 240, y: 60))
precondition(dismissals == 1 && outsideTarget.clicks == 2, "Collapsed menus must stop observing clicks")
presentBoundary()
let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 240),
    styleMask: [.borderless], backing: .buffered, defer: false)
otherWindow.isReleasedWhenClosed = false
otherWindow.contentView = MenuClickTarget(frame: clickRoot.bounds)
fixtureClick(otherWindow, point: NSPoint(x: 240, y: 60))
precondition(dismissals == 1, "A local click in a different window must not be mistaken for a boundary hit")
fixtureClick(clickWindow, point: NSPoint(x: 240, y: 60), type: .rightMouseDown)
precondition(dismissals == 2 && outsideTarget.clicks == 3)
presentBoundary()
NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: clickWindow)
NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: clickWindow)
precondition(dismissals == 3 && !boundary.monitoring, "Losing key status must close only once")
presentBoundary()
boundary.removeFromSuperview()
precondition(!boundary.monitoring, "Removing the menu view must release its listeners")
clickRoot.addSubview(boundary)
precondition(boundary.monitoring)
boundary.configure(presented: false) { dismissals += 1 }
precondition(!boundary.monitoring)
otherWindow.close(); clickWindow.close()
print("PASS native outside dismissal: inside/outside and right clicks, click forwarding, window isolation, resign-key, collapse and detachment cleanup")
