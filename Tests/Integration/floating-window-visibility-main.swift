import AppKit
let app = NSApplication.shared
let window = NSPanel(contentRect: NSRect(x: 100,y: 100,width: 210,height: 210),styleMask: [.borderless],backing: .buffered,defer: false)
window.isReleasedWhenClosed = false
let motion = FloatingWindowVisibility(window: window)
let targetFrame = window.frame
func pump(_ t: TimeInterval) { RunLoop.current.run(until: Date(timeIntervalSinceNow: t)) }
motion.show()
pump(0.06)
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    precondition(window.alphaValue > 0 && window.alphaValue < 1)
}
motion.show() // repeated reveal must not interrupt the fade
pump(0.22)
precondition(window.alphaValue == 1 && window.frame == targetFrame)
var closed = false
if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
motion.hide { closed = true; window.orderOut(nil) }
pump(0.04)
motion.show() // interrupted close must never run its stale completion
pump(0.25)
precondition(!closed && window.isVisible && window.alphaValue == 1 && !window.ignoresMouseEvents)
}
motion.hide { closed = true; window.orderOut(nil) }
pump(0.22)
precondition(closed && !window.isVisible && window.frame == targetFrame)
motion.show(animated: false)
precondition(window.alphaValue == 1 && window.isVisible)
motion.hide(animated: false) { window.orderOut(nil) }
precondition(!window.isVisible)
print("PASS fade intermediate alpha, repeated show, interrupted close, stable hit frame, immediate path")
