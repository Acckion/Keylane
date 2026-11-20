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
