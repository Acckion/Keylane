import AppKit
import Combine

/// Observe only events already delivered to this app. No global event tap or
/// accessibility permission is needed to show shortcut hints in a key panel.
final class LauncherModifiers: ObservableObject {
    @Published private(set) var commandHeld = false
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    func start() {
        update(NSEvent.modifierFlags)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.update([]) })
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        update([])
    }
    func update(_ flags: NSEvent.ModifierFlags) {
        let held = flags.contains(.command)
        if commandHeld != held { commandHeld = held }
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}
