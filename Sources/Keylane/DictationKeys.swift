import AppKit
import ApplicationServices
import Carbon

/// Reuses normal command shortcuts; the optional modifier has no registration until opted in.
final class DictationKeys {
    private weak var controller: DictationController?
    private var global: Any?
    private var local: Any?
    private var pending: DispatchWorkItem?
    private var held = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    init(controller: DictationController) { self.controller = controller }

    func configureModifier() {
        removeModifier()
        guard let controller, !controller.shortcutsSuspended, controller.canRun(), controller.settings.permission.available,
              controller.settings.options.modifierKey != nil, !controller.commandShortcutAssigned(), AXIsProcessTrusted() else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] in self?.observe($0) }
        local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown]) { [weak self] event in
            self?.observe(event); return event
        }
    }
    private func observe(_ event: NSEvent) {
        guard let controller, !controller.shortcutsSuspended, !controller.commandShortcutAssigned(), let key = controller.settings.options.modifierKey,
              controller.canRun(), controller.settings.permission.available, !IsSecureEventInputEnabled() else { return }
        guard event.type == .flagsChanged, event.keyCode == key else {
            pending?.cancel(); pending = nil
            if held && controller.settings.options.holdToTalk { held = false; controller.cancel() }
            return
        }
        let pressed = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(key))
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        let expected: NSEvent.ModifierFlags
        switch key { case 54, 55: expected = .command; case 56, 60: expected = .shift; case 58, 61: expected = .option; case 59, 62: expected = .control; default: expected = .function }
        if pressed {
            guard flags == expected, !held, pending == nil else { return }
            if controller.settings.options.holdToTalk {
                let item = DispatchWorkItem { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    self.pending = nil
                    guard controller.canRun(), controller.settings.permission.available, !controller.busy else { return }
                    self.held = true; controller.invokeDefaultShortcut()
                }
                pending = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
            } else { held = true }
        } else {
            pending?.cancel(); pending = nil
            guard held else { return }
            held = false
            if controller.settings.options.holdToTalk { controller.releaseShortcut() }
            else { controller.invokeDefaultShortcut() }
        }
    }

    func watchSession() {
        stopWatchingSession()
        guard AXIsProcessTrusted() else { return }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: 1 << CGEventType.keyDown.rawValue, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<DictationKeys>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown, let controller = owner.controller,
                  controller.busy, !ModifierShortcuts.isUnmodifiedSyntheticEvent(event), !IsSecureEventInputEnabled() else { return Unmanaged.passUnretained(event) }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            guard key == 36 || key == 53 else { return Unmanaged.passUnretained(event) }
            if key == 36 && !controller.recording { return Unmanaged.passUnretained(event) }
            let modifiers = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            let expected: CGEventFlags = controller.settings.options.modifiedFinishKeys ? .maskCommand : []
            guard modifiers == expected else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { [weak controller] in if key == 53 { controller?.cancel() } else { controller?.finish() } }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap, let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
            self.source = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
    func stopWatchingSession() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    private func removeModifier() {
        pending?.cancel(); pending = nil; held = false
        if let global { NSEvent.removeMonitor(global) }
        if let local { NSEvent.removeMonitor(local) }
        global = nil; local = nil
    }
    func stop() { removeModifier(); stopWatchingSession() }
    deinit { stop() }
}
