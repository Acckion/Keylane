import AppKit
import Carbon
import KeylaneCore

enum ShortcutRegistrationScope: Equatable {
    case native
    case unavailable
    case extensionActivation(UUID)
}

final class ShortcutManager {
    private struct Registration {
        let id: UInt32
        let reference: EventHotKeyRef
        let shortcut: Shortcut
        let scope: ShortcutRegistrationScope
    }

    private var registrations: [String: Registration] = [:]
    private var specs: [String: Shortcut] = [:]
    private var ids: [UInt32: String] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    var fired: ((String) -> Void)?
    var scopeForAction: (String) -> ShortcutRegistrationScope = { _ in .native }
    private var suspended = false

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4B4C414E, owner.enqueue(id: id.id) else { return OSStatus(eventNotHandledErr) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit { stop() }

    func enqueue(id: UInt32) -> Bool {
        guard ids[id] != nil else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self, let action = self.ids[id], let registration = self.registrations[action],
                  registration.id == id, registration.scope == self.scopeForAction(action) else { return }
            self.fired?(action)
        }
        return true
    }

    /// Register replacements before removing existing shortcuts, retaining the old set on failure.
    func apply(_ proposed: [String: Shortcut]) throws {
        if let reason = ShortcutValidation.conflict(in: proposed) { throw Failure(reason) }
        if suspended { specs = proposed; return }
        var additions: [String: Registration] = [:]
        do {
            for action in proposed.keys.sorted() {
                guard let shortcut = proposed[action], specs[action] != shortcut else { continue }
                let scope = scopeForAction(action)
                if scope != .unavailable { additions[action] = try register(shortcut, scope: scope) }
            }
        } catch {
            additions.values.forEach { UnregisterEventHotKey($0.reference) }
            throw error
        }
        for action in Array(registrations.keys) where proposed[action] != specs[action] { unregister(action) }
        additions.forEach { track($0.value, for: $0.key) }
        specs = proposed
    }

    /// Restore independent bindings even when one is invalid or reserved by another app.
    func restore(_ saved: [String: Shortcut]) throws {
        suspend()
        suspended = false
        specs = saved
        try registerMissing(saved)
    }

    /// Revoke old extension registrations before attempting to restore their saved bindings.
    func refreshExtensions() throws {
        guard !suspended else { return }
        removeStaleRegistrations()
        try registerMissing(specs.filter { action, _ in
            if case .extensionActivation = scopeForAction(action) { return true }
            return false
        })
    }

    func removeStaleRegistrations() {
        for (action, registration) in Array(registrations) where registration.scope != scopeForAction(action) {
            unregister(action)
        }
    }

    private func registerMissing(_ saved: [String: Shortcut]) throws {
        var registered = Set(registrations.values.map(\.shortcut))
        var failures: [String] = []
        let actions = (saved["launcher"] == nil ? [] : ["launcher"]) + saved.keys.filter { $0 != "launcher" }.sorted()
        for action in actions {
            guard registrations[action] == nil, let shortcut = saved[action] else { continue }
            let scope = scopeForAction(action)
            guard scope != .unavailable else { continue }
            do {
                if let reason = ShortcutValidation.conflict(in: [action: shortcut]) { throw Failure(reason) }
                guard !registered.contains(shortcut) else { throw Failure("快捷键与已恢复的绑定重复。") }
                track(try register(shortcut, scope: scope), for: action)
                registered.insert(shortcut)
            } catch {
                failures.append("\(action)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw Failure("部分快捷键未能恢复：\n" + failures.joined(separator: "\n")) }
    }

    private func register(_ shortcut: Shortcut, scope: ShortcutRegistrationScope) throws -> Registration {
        var reference: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let result = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: 0x4B4C414E, id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else { throw Failure("快捷键已被系统或其他应用占用（\(result)）。") }
        return Registration(id: id, reference: reference, shortcut: shortcut, scope: scope)
    }

    private func track(_ registration: Registration, for action: String) {
        registrations[action] = registration
        ids[registration.id] = action
    }

    private func unregister(_ action: String) {
        guard let registration = registrations.removeValue(forKey: action) else { return }
        ids.removeValue(forKey: registration.id)
        UnregisterEventHotKey(registration.reference)
    }

    func suspend() {
        for action in Array(registrations.keys) { unregister(action) }
        suspended = true
    }

    func resume() throws { try restore(specs) }
    func stop() { suspend(); if let handler { RemoveEventHandler(handler) }; handler = nil }
    struct Failure: LocalizedError { let errorDescription: String?; init(_ text: String) { errorDescription = text } }
}
extension Shortcut {
    var label: String { keycaps.joined() }
    var keycaps: [String] {
        let names: [UInt32:String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"Space",50:"`",51:"⌫",53:"Esc",123:"←",124:"→",125:"↓",126:"↑"]
        return [(4096, "⌃"), (2048, "⌥"), (512, "⇧"), (256, "⌘")].compactMap { mask, name in modifiers & UInt32(mask) != 0 ? name : nil } + [names[key] ?? "Key \(key)"]
    }
    init(event: NSEvent) {
        let flags = event.modifierFlags
        let mods: UInt32 = (flags.contains(.command) ? 256 : 0) | (flags.contains(.shift) ? 512 : 0) | (flags.contains(.option) ? 2048 : 0) | (flags.contains(.control) ? 4096 : 0)
        self.init(key: UInt32(event.keyCode), modifiers: mods)
    }
}
