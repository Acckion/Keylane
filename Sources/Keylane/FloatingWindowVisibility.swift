import AppKit

/// Opacity-only transitions keep the window's drag destination and hit regions stable.
final class FloatingWindowVisibility {
    static let defaultShowDuration: TimeInterval = 0.18
    private weak var window: NSWindow?
    private var timer: Timer?
    private var disappearing = false

    init(window: NSWindow) { self.window = window }
    deinit { timer?.invalidate() }

    func show(animated: Bool = true, duration: TimeInterval = defaultShowDuration) {
        guard let window else { return }
        if window.isVisible, !disappearing { window.orderFrontRegardless(); return }
        cancel()
        if !window.isVisible { window.alphaValue = 0 }
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        transition(to: 1, duration: duration, animated: animated) {}
    }

    func hide(animated: Bool = true, completion: @escaping () -> Void) {
        guard let window else { return }
        guard !disappearing else { return }
        cancel()
        disappearing = true
        window.ignoresMouseEvents = true
        transition(to: 0, duration: 0.14, animated: animated) { [weak self] in
            self?.disappearing = false
            completion()
        }
    }

    func cancel() {
        timer?.invalidate(); timer = nil
        disappearing = false
        window?.ignoresMouseEvents = false
    }

    private func transition(to target: CGFloat, duration: TimeInterval, animated: Bool,
                            completion: @escaping () -> Void) {
        guard let window else { return }
        guard animated, window.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            window.alphaValue = target; completion(); return
        }
        let start = window.alphaValue
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self, let window = self.window else { timer.invalidate(); return }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / duration)
            let eased = t * t * (3 - 2 * t)
            window.alphaValue = start + (target - start) * eased
            if t == 1 {
                timer.invalidate(); self.timer = nil
                completion()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
