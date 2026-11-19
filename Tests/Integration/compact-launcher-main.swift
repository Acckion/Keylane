import SwiftUI
import AppKit
import KeylaneCore

// Inert dependencies: exercise the production bar without services or user data.
enum VisualStyle {
    static let launcherTopInset: CGFloat = 61
    static let launcherWidth: CGFloat = 760
}
final class Registry {
    func isRegisteredCommandEnabled(_ id: CommandID) -> Bool { true }
}
final class Model {
    enum Origin { case search }
    let launcherModules: Registry? = Registry()
    var calls: [CommandID] = []
    func runCommand(_ id: CommandID, origin: Origin, usageKey: String) { calls.append(id) }
}
func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let model = Model()
let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 760, height: 61),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false
let hosting = NSHostingView(rootView:
    CompactLauncherBar(model: model, separation: 1, interactive: true, glassOpacity: 1) {
        TextField("搜索应用、文件和命令…", text: .constant(""))
            .textFieldStyle(.plain).padding(.horizontal, 19).frame(height: 61)
    })
hosting.sizingOptions = []
window.contentView = hosting
window.makeKeyAndOrderFront(nil)
pump(0.2)
for (index, shortcut) in CompactLauncherShortcut.allCases.enumerated() {
    let radius = CompactLauncherButtonGeometry.diameter / 2
    let center = CGPoint(x: CompactLauncherButtonGeometry.offset(for: index) + radius, y: radius)
    for dx in [-radius + 3, 0, radius - 3] {
        let point = CGPoint(x: center.x + dx, y: center.y)
        precondition(CompactLauncherButtonGeometry.shortcut(at: point) == shortcut)
        let before = model.calls.count
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
        }
        pump(0.03)
        precondition(model.calls.count == before + 1 && model.calls.last == shortcut.id,
                     "Full circle click failed: \(shortcut), \(dx)")
    }
}
precondition(CompactLauncherButtonGeometry.shortcut(at: CGPoint(x: 0, y: 0)) == nil)
window.orderOut(nil)
print("PASS production compact bar: 9 center/rim clicks, ordered destinations, inert services")
