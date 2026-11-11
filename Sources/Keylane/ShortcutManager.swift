import AppKit
import Carbon
import KeylaneCore

final class ShortcutManager {
    private var refs: [String:EventHotKeyRef] = [:]
    private var specs: [String:Shortcut] = [:]
    private var ids: [UInt32:String] = [:]
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 1
    var fired: ((String) -> Void)?
    var suspended = false
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ShortcutManager>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x4B4C414E, let action = owner.ids[id.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { owner.fired?(action) }; return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit { stop() }
    /// Register replacements before removing existing shortcuts, retaining the old set on failure.
    func apply(_ proposed: [String:Shortcut]) throws {
        if let reason = ShortcutValidation.conflict(in: proposed) { throw Failure(reason) }
        if suspended { specs = proposed; return }
        var additions: [String:EventHotKeyRef] = [:]
        var newIDs: [UInt32:String] = [:]
        do {
            for action in proposed.keys.sorted() {
                guard let spec = proposed[action], specs[action] != spec else { continue }
                let registration = try register(spec)
                additions[action] = registration.reference
                newIDs[registration.id] = action
            }
        } catch { for reference in additions.values { UnregisterEventHotKey(reference) }; throw error }
        for (action, reference) in refs where proposed[action] != specs[action] { UnregisterEventHotKey(reference); refs.removeValue(forKey: action); ids = ids.filter { $0.value != action } }
        refs.merge(additions) { _, new in new }; ids.merge(newIDs) { _, new in new }; specs = proposed
    }
    /// Restore independent bindings even when one is invalid or reserved by another app.
    func restore(_ saved: [String: Shortcut]) throws {
        suspend()
        suspended = false
        specs = saved
        var registered = Set<Shortcut>()
        var failures: [String] = []
        let actions = (saved["launcher"] == nil ? [] : ["launcher"]) + saved.keys.filter { $0 != "launcher" }.sorted()
        for action in actions {
            guard let shortcut = saved[action] else { continue }
            do {
                if let reason = ShortcutValidation.conflict(in: [action: shortcut]) { throw Failure(reason) }
                guard !registered.contains(shortcut) else { throw Failure("快捷键与已恢复的绑定重复。") }
                let registration = try register(shortcut)
                refs[action] = registration.reference
                ids[registration.id] = action
                registered.insert(shortcut)
            } catch {
                failures.append("\(action)：\(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw Failure("部分快捷键未能恢复：\n" + failures.joined(separator: "\n"))
        }
    }

    private func register(_ shortcut: Shortcut) throws -> (id: UInt32, reference: EventHotKeyRef) {
        var reference: EventHotKeyRef?
        let id = nextID
        nextID += 1
        let result = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: 0x4B4C414E, id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else { throw Failure("快捷键已被系统或其他应用占用（\(result)）。") }
        return (id, reference)
    }

    func suspend() { for reference in refs.values { UnregisterEventHotKey(reference) }; refs = [:]; ids = [:]; suspended = true }
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
