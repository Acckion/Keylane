import AppKit
import Combine

struct MenuBarPresentation: Equatable {
    var title = ""
    var symbol: String?
    var toolTip: String
}

struct MenuBarCommand {
    let title: String
    var symbol: String? = nil
    var enabled = true
    var checked = false
    var children: [MenuBarCommand] = []
    var keyEquivalent = ""
    var iconColor: NSColor? = nil
    var isSectionHeader = false
    var isSeparator = false
    var action: (() -> Void)? = nil
    static var separator: Self { Self(title: "", isSeparator: true) }
    static func heading(_ title: String) -> Self { Self(title: title, enabled: false, isSectionHeader: true) }
}

/// Native status items share one lifecycle. Providers return cached UI data only;
/// fetching, permissions and refresh scheduling belong to the owning module.
final class MenuBarRegistry: NSObject, ObservableObject, NSMenuDelegate {
    struct Descriptor: Identifiable { let id: String; let owner: String; let title: String }
    private final class Registration {
        let descriptor: Descriptor
        let defaultVisible: Bool
        var presentation: MenuBarPresentation
        var commands: () -> [MenuBarCommand]
        var item: NSStatusItem?
        init(_ descriptor: Descriptor, defaultVisible: Bool, presentation: MenuBarPresentation, commands: @escaping () -> [MenuBarCommand]) {
            self.descriptor = descriptor; self.defaultVisible = defaultVisible; self.presentation = presentation; self.commands = commands
        }
    }
    private final class Action: NSObject {
        let perform: () -> Void
        init(_ perform: @escaping () -> Void) { self.perform = perform }
        @objc func invoke(_ sender: NSMenuItem) { if sender.isEnabled { perform() } }
    }
    @Published private(set) var descriptors: [Descriptor] = []
    private var registrations: [String: Registration] = [:]
    private let preferences: UserDefaults
    init(preferences: UserDefaults = .standard) { self.preferences = preferences }
    func register(id: String, owner: String, title: String, defaultVisible: Bool, presentation: MenuBarPresentation, commands: @escaping () -> [MenuBarCommand]) {
        precondition(Thread.isMainThread)
        if let entry = registrations[id] {
            precondition(entry.descriptor.owner == owner, "Menu bar ID belongs to another module")
            entry.commands = commands; update(id: id, presentation: presentation); return
        }
        let descriptor = Descriptor(id: id, owner: owner, title: title)
        registrations[id] = Registration(descriptor, defaultVisible: defaultVisible, presentation: presentation, commands: commands)
        descriptors = registrations.values.map(\.descriptor).sorted { $0.id < $1.id }
        reconcile(id)
    }
    func isEnabled(_ id: String) -> Bool {
        (preferences.object(forKey: "menuBar.visible." + id) as? Bool) ?? registrations[id]?.defaultVisible ?? false
    }
    func setEnabled(_ id: String, _ enabled: Bool) {
        precondition(Thread.isMainThread)
        guard registrations[id] != nil else { return }
        objectWillChange.send(); preferences.set(enabled, forKey: "menuBar.visible." + id); reconcile(id)
    }
    func update(id: String, presentation: MenuBarPresentation) {
        precondition(Thread.isMainThread)
        guard let entry = registrations[id], entry.presentation != presentation else { return }
        entry.presentation = presentation; apply(entry)
    }
    func unregister(owner: String) {
        precondition(Thread.isMainThread)
        for id in registrations.keys.filter({ registrations[$0]?.descriptor.owner == owner }) {
            removeItem(registrations[id]!); registrations.removeValue(forKey: id)
        }
        descriptors = registrations.values.map(\.descriptor).sorted { $0.id < $1.id }
    }
    func shutdown() {
        for entry in registrations.values { removeItem(entry) }
        registrations = [:]; descriptors = []
    }
    private func reconcile(_ id: String) {
        guard let entry = registrations[id] else { return }
        guard isEnabled(id) else { removeItem(entry); return }
        if entry.item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "Keylane." + id
            let menu = NSMenu(); menu.identifier = NSUserInterfaceItemIdentifier(id); menu.delegate = self
            item.menu = menu; item.isVisible = true; entry.item = item
        }
        apply(entry)
    }
    private func apply(_ entry: Registration) {
        guard let item = entry.item, let button = item.button else { return }
        let value = entry.presentation
        item.length = value.title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
        button.title = value.title.isEmpty || value.symbol == nil ? value.title : " " + value.title
        button.image = value.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: entry.descriptor.title) }
        button.image?.isTemplate = true; button.imagePosition = .imageLeading; button.toolTip = value.toolTip
        button.setAccessibilityLabel(entry.descriptor.title + (value.title.isEmpty ? "" : "，" + value.title))
    }
    private func removeItem(_ entry: Registration) {
        guard let item = entry.item else { return }
        item.menu?.cancelTracking(); item.menu?.delegate = nil; item.menu?.removeAllItems(); item.menu = nil
        NSStatusBar.system.removeStatusItem(item); entry.item = nil
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let id = menu.identifier?.rawValue, let entry = registrations[id] else { return }
        menu.removeAllItems()
        populate(menu, with: entry.commands())
    }
    private func populate(_ menu: NSMenu, with commands: [MenuBarCommand]) {
        menu.autoenablesItems = false
        for command in commands {
            if command.isSeparator { menu.addItem(.separator()); continue }
            if command.isSectionHeader { menu.addItem(.sectionHeader(title: command.title)); continue }
            let item = NSMenuItem(title: command.title, action: nil, keyEquivalent: command.keyEquivalent)
            item.isEnabled = command.enabled; item.state = command.checked ? .on : .off
            if let symbol = command.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                if let color = command.iconColor {
                    item.image = image.withSymbolConfiguration(.init(paletteColors: [color])) ?? image
                    item.image?.isTemplate = false
                } else {
                    item.image = image
                }
                if #available(macOS 27.0, *),
                   item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
                    // NSMenuItemImageVisibilityVisible in the macOS 27 AppKit header.
                    item.setValue(1, forKey: "preferredImageVisibility")
                }
            }
            if !command.children.isEmpty { let submenu = NSMenu(); populate(submenu, with: command.children); item.submenu = submenu }
            if let action = command.action { let target = Action(action); item.target = target; item.action = #selector(Action.invoke(_:)); item.representedObject = target }
            menu.addItem(item)
        }
    }
    // Internal inspection used by isolated integration checks, never exposing calendar content.
    func nativeItem(id: String) -> NSStatusItem? { registrations[id]?.item }
}
