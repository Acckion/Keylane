import SwiftUI
import AppKit
import KeylaneCore

// Inert dependencies: exercise the production bar without services or user data.
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
window.isOpaque = false; window.backgroundColor = .clear
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

// Verify the actual rendered window, not just a geometry predicate: theme fills
// must stop at each surface, including with Reduce Transparency enabled.
let domain = "org.keylane.compact-theme-test." + UUID().uuidString
let defaults = UserDefaults(suiteName: domain)!
defer { defaults.removePersistentDomain(forName: domain) }
let store = ThemeStore(defaults: defaults)
func bitmap<V: View>(_ content: V, height: CGFloat) -> NSBitmapImageRep {
    let host = NSHostingView(rootView: content)
    host.sizingOptions = []
    window.setContentSize(NSSize(width: 760, height: height))
    window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 760, height: height)
    window.makeKeyAndOrderFront(nil); pump(0.15); host.layoutSubtreeIfNeeded()
    // Layer caching omits native glass composition. Capture only this fixture's
    // WindowServer surface, including alpha, even if another app is in front.
    let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keylane-compact-" + UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: path) }
    let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
    try! capture.run(); capture.waitUntilExit()
    precondition(capture.terminationStatus == 0, "Fixture window capture failed")
    let image = NSBitmapImageRep(data: try! Data(contentsOf: path))!

    return image
}
func color(_ image: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat, height: CGFloat = 61) -> NSColor {
    image.colorAt(x: Int(x / 760 * CGFloat(image.pixelsWide)), y: Int(y / height * CGFloat(image.pixelsHigh)))!.usingColorSpace(.sRGB)!
}
for theme in [ThemeDefinition.builtins[0], ThemeDefinition.builtins[1], ThemeDefinition.builtins[2], ThemeDefinition.builtins[4]] {
    try store.assign(theme.id)
    let scheme: ColorScheme = theme.appearance == .dark ? .dark : .light
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    do {
        let view = CompactLauncherBar(model: model, separation: 1, interactive: true, glassOpacity: 1) { Color.clear }
            .keylaneTheme(store: store, backgroundOpacity: 0)
            .environment(\.colorScheme, scheme)
        let image = bitmap(view, height: 61)
        for gap in [CGPoint(x: 557, y: 8), CGPoint(x: 626, y: 8), CGPoint(x: 695, y: 8)] {
            precondition(color(image, gap.x, gap.y).alphaComponent < 0.05,
                         "Compact gap became opaque: \(theme.name), \(gap)")
        }
        if !theme.usesSystemMaterial {
            for x: CGFloat in [150, 591.5, 660.5, 729.5] {
                precondition(color(image, x, 30.5).alphaComponent > 0.8, "Themed compact surface disappeared")
            }
        }
        let before = model.calls.count
        for index in CompactLauncherShortcut.allCases.indices {
            let point = CGPoint(x: CompactLauncherButtonGeometry.offset(for: index) + 30.5, y: 30.5)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
        pump(0.03)
        precondition(model.calls.count == before + 3, "Themed compact shortcuts lost clickability")
    }
    for reduced in [false, true] {
        let capsule = bitmap(CompactLauncherMaterial(shape: Capsule(), width: 760, height: 61, reduceTransparency: reduced)
            .environment(\.keylaneTheme, theme).environment(\.colorScheme, scheme), height: 61)
        let circle = bitmap(CompactLauncherMaterial(shape: Circle(), width: 61, height: 61, reduceTransparency: reduced)
            .frame(width: 760, height: 61, alignment: .leading)
            .environment(\.keylaneTheme, theme).environment(\.colorScheme, scheme), height: 61)
        precondition(color(capsule, 2, 2).alphaComponent < 0.05 && color(circle, 2, 2).alphaComponent < 0.05,
                     "Compact material escaped its shape")
        if !theme.usesSystemMaterial {
            precondition(color(capsule, 380, 30.5).alphaComponent > 0.8 && color(circle, 30.5, 30.5).alphaComponent > 0.8,
                         "Theme fill disappeared with reduced transparency=\(reduced)")
        }
    }
    if !theme.usesSystemMaterial {
        for opacity: CGFloat in [0, 0.5, 1] {
            let image = bitmap(Color.clear.frame(width: 760, height: 470)
                .keylaneTheme(store: store, backgroundOpacity: opacity).environment(\.colorScheme, scheme), height: 470)
            let alpha = color(image, 380, 235, height: 470).alphaComponent
            let expected = try ThemeRGBA(theme.background.color).alpha * Double(opacity)
            precondition(abs(alpha - expected) < 0.03, "Expanded theme no longer follows backdrop reveal")
        }
    }
}
window.orderOut(nil)
print("PASS compact theme backgrounds: default dark/light, harbor/forest, transparent gaps, visible surfaces, clickable shortcuts, reduced transparency, and expanded reveal")
