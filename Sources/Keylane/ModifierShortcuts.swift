import AppKit
import ApplicationServices
import Carbon
import KeylaneCore

/// No persistent system key remapping. Event tap is opt-in and removed on disable/quit.
final class ModifierShortcuts {
    private static let unmodifiedEventMarker: Int64 = 0x4B4C4E455241574B

    static func postWithoutHyperRemapping(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: unmodifiedEventMarker)
        event.post(tap: .cghidEventTap)
    }

    private var global: Any?
    private var local: Any?
    private var tracker = ModifierTapTracker()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var hyperHeld = false
    private var hyperFlags: CGEventFlags = []
    var activate: (() -> Void)?
    var doubleTap: String = "off"
    var hyperEnabled = false
    func configure(doubleTap: String, hyper: Bool, includeShift: Bool) -> String? {
        stop(); self.doubleTap = doubleTap; hyperEnabled = hyper
        hyperFlags = [.maskCommand, .maskControl, .maskAlternate]
        if includeShift { hyperFlags.insert(.maskShift) }
        guard doubleTap != "off" || hyper else { return nil }
        guard AXIsProcessTrusted() else { return "需要辅助功能权限才能使用修饰键快捷方式；授权后点击重新启用。" }
        if doubleTap != "off" {
            global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in self?.observe(event) }
            local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in self?.observe(event); return event }
        }
        if hyper {
            let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<ModifierShortcuts>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }; owner.hyperHeld = false; return Unmanaged.passUnretained(event) }
                if IsSecureEventInputEnabled() { owner.hyperHeld = false; return Unmanaged.passUnretained(event) }
                if event.getIntegerValueField(.eventSourceUserData) == ModifierShortcuts.unmodifiedEventMarker {
                    return Unmanaged.passUnretained(event)
                }
                let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                if key == 57 {
                    owner.hyperHeld = CGEventSource.keyState(.hidSystemState, key: 57)
                    return nil
                }
                if owner.hyperHeld {
                    event.flags.remove(.maskAlphaShift)
                    event.flags.formUnion(owner.hyperFlags)
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
            guard let tap else { stop(); return "无法启用 Hyperkey，请检查辅助功能和输入监控权限。" }
            source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return nil
    }
    private func observe(_ event: NSEvent) {
        guard !IsSecureEventInputEnabled() else { tracker.cancel(); return }
        guard event.type == .flagsChanged else { tracker.cancel(); return }
        let target: (UInt16, NSEvent.ModifierFlags)
        switch doubleTap { case "command": target = (55,.command); case "option": target = (58,.option); case "control": target = (59,.control); case "shift": target = (56,.shift); default: return }
        guard event.keyCode == target.0 else { tracker.cancel(); return }
        let flags = event.modifierFlags.intersection([.command,.option,.control,.shift])
        guard flags.isEmpty || flags == target.1 else { tracker.cancel(); return }
        if tracker.update(pressed: flags.contains(target.1), time: event.timestamp) { activate?() }
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global) }; global = nil
        if let local { NSEvent.removeMonitor(local) }; local = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }; tap = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; source = nil
        hyperHeld = false; tracker.cancel()
    }
    deinit { stop() }
}
