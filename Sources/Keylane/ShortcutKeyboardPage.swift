import AppKit
import KeylaneCore
import SwiftUI

final class ShortcutKeyboardSelection: ObservableObject {
    @Published var input = ShortcutKeyboardInput()
    var shortcut: Shortcut? { input.selected }
    var previewModifiers: UInt32? { input.previewModifiers }
    var displayedKeys: [String] {
        if let previewModifiers { return Shortcut.modifierKeycaps(previewModifiers) }
        return shortcut?.keycaps ?? []
    }

    @Published var choosing = false
    @Published var feedback: String?
}

struct ShortcutKeyboardPage: View {
    static let pageID = PageID(rawValue: "ShortcutKeyboard")

    let model: Model
    @ObservedObject var selection: ShortcutKeyboardSelection
    let menuOpen: Binding<Bool>?
    @StateObject private var observation: ViewObservation
    @State private var query = ""
    @State private var change: Change?
    @State private var inputMonitor: Any?

    private struct Change {
        let target: Shortcut
        let commandID: String
        let previous: Shortcut?
        let displaced: String?
    }

    init(model: Model, selection: ShortcutKeyboardSelection, menuOpen: Binding<Bool>? = nil) {
        self.model = model
        self.selection = selection
        self.menuOpen = menuOpen
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$disabledCommands)
        ] + (model.launcherModules.map { $0.shortcutSettingsUpdates() + [$0.availabilityChanges.eraseToAnyPublisher()] } ?? [])))
    }

    private var shortcut: Shortcut? { selection.shortcut }
    private var owner: String? { model.bindings.first { $0.value == shortcut }?.key }
    private var validation: String? {
        shortcut.flatMap { ShortcutValidation.conflict(in: ["shortcut": $0]) }
    }

    var body: some View {
        let registry = model.launcherModules
        let groups = registry?.shortcutCommandGroups ?? []
        let catalog = groups.flatMap { group in
            let fixed = group.commands.map { ShortcutCommandName(id: $0.declaration.id.rawValue, title: $0.declaration.title) }
            let binding = group.binding.map { [ShortcutCommandName(id: $0.id, title: $0.title)] } ?? []
            return fixed + binding + (group.dynamicCommands?.commandNames() ?? [])
        }
        let names = Dictionary(catalog.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        if let menuOpen {
            keyboardControls(catalog, names: names, registry: registry, open: menuOpen)
        } else {
            keyboardContent(names: names)
        }
    }

    private func keyboardContent(names: [String: String]) -> some View {
        let bindingsByShortcut = Dictionary(model.bindings.sorted { $0.key < $1.key }.map { ($0.value, $0.key) },
                                            uniquingKeysWith: { first, _ in first })
        return keyboard(bindings: bindingsByShortcut, names: names)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("MacBook Air ANSI 键盘")
            .padding(.horizontal, 22)
            .padding(.top, VisualStyle.launcherTopInset + 10)
            .frame(maxHeight: .infinity, alignment: .top)
        .onAppear(perform: startCapturing)
        .onDisappear(perform: stopCapturing)
        .onChange(of: selection.choosing) { _, choosing in
            if choosing {
                stopCapturing()
            } else { startCapturing() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherShown)) { _ in startCapturing() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { event in
            guard (event.object as? NSWindow) === (NSApp.delegate as? Delegate)?.window else { return }
            startCapturing()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { event in
            guard (event.object as? NSWindow) === (NSApp.delegate as? Delegate)?.window else { return }
            stopCapturing()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launcherHidden)) { _ in
            stopCapturing()
            closePicker()
        }
    }

    private func startCapturing() {
        guard inputMonitor == nil, !selection.choosing, model.pageID == Self.pageID,
              let delegate = NSApp.delegate as? Delegate, let window = delegate.window,
              window.isVisible, window.isKeyWindow else { return }
        delegate.shortcuts.suspend()
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak window] event in
            guard let window, window.isKeyWindow, model.pageID == Self.pageID else { return event }
            if let eventWindow = event.window, eventWindow !== window { return event }
            let pressed = Shortcut(event: event)
            if event.type == .flagsChanged {
                selection.input.modifiersChanged(pressed.modifiers)
                return event
            }
            if pressed.key == 53, pressed.modifiers == 0 {
                if event.isARepeat { return nil }
                if selection.input.cancelSelection() {
                    selection.feedback = nil
                    return nil
                }
                return event
            }
            if pressed.key == 36, pressed.modifiers == 0, !event.isARepeat,
               selection.shortcut != nil, selection.previewModifiers == nil, validation == nil {
                selection.feedback = nil
                selection.choosing = true
                return nil
            }
            // Bare keys remain available to the Launcher and never replace a captured chord.
            guard pressed.modifiers != 0, Self.editableCodes.contains(pressed.key) else { return event }
            if !event.isARepeat {
                selection.input.select(pressed)
            }
            selection.feedback = nil
            return nil
        }
    }

    private func stopCapturing() {
        selection.input.resetPreview()
        guard let inputMonitor else { return }
        NSEvent.removeMonitor(inputMonitor)
        self.inputMonitor = nil
        do { try (NSApp.delegate as? Delegate)?.shortcuts.resume() }
        catch { selection.feedback = error.localizedDescription }
    }

    private func bindingIcon(_ id: String) -> some View {
        let commandID = CommandID(rawValue: id)
        let registry = model.launcherModules
        let declaration = registry?.declaration(commandID)
        let module = registry?.moduleOwningCommand(commandID)
        let artwork = ModuleArtwork.command(commandID, settingsPage: declaration?.settingsPage, moduleID: module)
        return Group {
            if id.hasPrefix("app:") {
                WorkspaceItemIcon(path: String(id.dropFirst(4)))
            } else if id.hasPrefix("shortcut:") {
                ShortcutArtwork(image: model.systemShortcuts.icon(forCommandID: id))
            } else if let artwork {
                Image(nsImage: artwork).resizable().scaledToFit()
            } else {
                Image(systemName: declaration?.symbol ?? (id == "launcher" ? "command" : "bolt"))
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .frame(width: 15, height: 15)
        .accessibilityHidden(true)
    }

    private func keyboardControls(_ catalog: [ShortcutCommandName], names: [String: String],
                                  registry: LauncherModuleRegistry?, open: Binding<Bool>) -> some View {
        let enabled = shortcut != nil && selection.previewModifiers == nil && validation == nil
        let title = owner.map { names[$0] ?? $0 } ?? "绑定命令"
        let width: CGFloat = owner == nil ? 138 : 220
        let options = selection.choosing && open.wrappedValue
            ? ResultFilterPanel.matches(commandOptions(catalog, registry: registry),
                                        query: query.trimmingCharacters(in: .whitespacesAndNewlines))
            : []
        return ZStack(alignment: .topTrailing) {
            if open.wrappedValue, selection.choosing {
                if let change {
                    confirmation(change, names: names, registry: registry)
                        .frame(width: 300)
                        .onExitCommand { if !SearchField.isComposing { closePicker() } }
                } else {
                    ResultFilterPanel(selection: "", options: options, query: $query,
                                      searchPlaceholder: "搜索命令…", emptyTitle: "没有匹配的命令",
                                      navigation: model.navigation, width: 300, choose: { option in
                        if option.id == Self.unbindID { unbind() }
                        else { assign(option.id, registry: registry) }
                    }, dismiss: closePicker)
                }
            } else {
                LauncherHeaderMenuButton(title: title, symbol: "command", width: width,
                                         icon: owner.map { AnyView(bindingIcon($0)) }) {
                    guard enabled else { return }
                    selection.feedback = nil
                    selection.choosing = true
                }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help(selection.feedback ?? validation ?? title)
            }
        }
        .modifier(LauncherMenuSurface(open: open.wrappedValue && selection.choosing))
        .onChange(of: selection.choosing, initial: true) { _, choosing in
            if choosing {
                query = ""
                change = nil
            }
            if open.wrappedValue != choosing { open.wrappedValue = choosing }
        }
        .onChange(of: open.wrappedValue) { _, isOpen in
            if !isOpen && selection.choosing { closePicker() }
        }
    }

    private func confirmation(_ proposed: Change, names: [String: String], registry: LauncherModuleRegistry?) -> some View {
        let name = names[proposed.commandID] ?? proposed.commandID
        let moved = proposed.previous.map { "（原快捷键 \($0.label) 将解除）" } ?? ""
        let removed = proposed.displaced.map { "\n\(names[$0] ?? $0) 将解除 \(proposed.target.label)。" } ?? ""
        return SettingsGroup {
            SettingsTitle("确认改绑")
            SettingsDescription("\(name)将绑定到 \(proposed.target.label)\(moved)。" + removed)
            HStack {
                Spacer()
                Button("取消") { change = nil }
                Button("确认改绑") { save(proposed, registry: registry) }
            }
        }
    }

    private func closePicker() {
        selection.choosing = false
        change = nil
    }

    private static let unbindID = "keylane.unbind-shortcut"

    private func commandOptions(_ catalog: [ShortcutCommandName],
                                registry: LauncherModuleRegistry?) -> [ResultFilterOption] {
        var options: [ResultFilterOption] = []
        if owner != nil {
            options.append(.init(id: Self.unbindID, title: "解除绑定", symbol: "link.badge.minus", destructive: true))
        }
        for command in catalog where command.id != owner {
            let id = CommandID(rawValue: command.id)
            guard registry?.canBindFromShortcutKeyboard(id) == true else { continue }
            let declaration = registry?.declaration(id)
            let module = registry?.moduleOwningCommand(id)
            let artwork = command.id.hasPrefix("shortcut:") ? model.systemShortcuts.icon(forCommandID: command.id)
                : ModuleArtwork.command(id, settingsPage: declaration?.settingsPage, moduleID: module)
            let appPath = command.id.hasPrefix("app:") ? String(command.id.dropFirst(4)) : nil
            options.append(.init(id: command.id, title: command.title, symbol: declaration?.symbol ?? "command",
                                 iconPath: appPath, subtitle: model.bindings[command.id]?.label, artwork: artwork,
                                 keywords: model.aliases[command.aliasKey ?? command.id].map { [$0] } ?? []))
        }
        return options
    }

    private func keyboard(bindings: [Shortcut: String], names: [String: String]) -> some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 1030
            ZStack(alignment: .topLeading) {
                ForEach(Self.layout) { cap in
                    let displayedModifiers = selection.previewModifiers ?? shortcut?.modifiers ?? 0
                    let chord = cap.code.map { Shortcut(key: $0, modifiers: displayedModifiers) }
                    let bound = chord.flatMap { bindings[$0] }
                    let name = bound.map { names[$0] ?? $0 }
                    let active = cap.modifier != 0 && displayedModifiers & cap.modifier != 0
                    let selected = selection.previewModifiers == nil && cap.code != nil && cap.code == shortcut?.key
                    Group {
                        if cap.code != nil || cap.modifier != 0 {
                            Button {
                                if let code = cap.code {
                                    selection.input.select(Shortcut(key: code, modifiers: displayedModifiers))
                                } else {
                                    selection.input.toggleModifier(cap.modifier)
                                }
                                selection.choosing = false
                                selection.feedback = nil
                            } label: {
                                keycap(cap, name: name, iconID: selection.previewModifiers == nil ? nil : bound,
                                       active: active, selected: selected)
                            }.buttonStyle(.plain)
                                .help(name ?? cap.description)
                                .accessibilityLabel(chord?.label ?? cap.description)
                                .accessibilityValue(name ?? (cap.modifier != 0 ? (active ? "已按下" : "未按下") : "未绑定"))
                                .accessibilityAddTraits(active || selected ? .isSelected : [])
                        } else {
                            keycap(cap, name: nil, iconID: nil, active: false, selected: false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: cap.width * unit, height: cap.height * unit)
                    .position(x: (cap.x + cap.width / 2) * unit, y: (cap.y + cap.height / 2) * unit)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.aspectRatio(1030.0 / 412, contentMode: .fit)
    }

    private func keycap(_ cap: Key, name: String?, iconID: String?, active: Bool, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        return VStack(spacing: 0) {
            if let legend = cap.legend {
                Text(legend).font(.system(size: 7)).foregroundStyle(.secondary)
            }
            Text(cap.label).font(.system(size: cap.label.count > 2 ? 8 : 11, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let iconID {
                bindingIcon(iconID)
            } else if let name {
                Text(name).font(.system(size: 9)).lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(active ? 0.23 : name != nil ? 0.12 : 0.065), in: shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(selected ? 0.58 : active ? 0.24 : 0.09)) }
        .contentShape(shape)
    }

    private func assign(_ id: String, registry: LauncherModuleRegistry?) {
        guard let shortcut, validation == nil, id != owner else { return }
        let proposed = Change(target: shortcut, commandID: id, previous: model.bindings[id], displaced: owner)
        if proposed.previous != nil || proposed.displaced != nil { change = proposed }
        else { save(proposed, registry: registry) }
    }

    private func save(_ proposed: Change, registry: LauncherModuleRegistry?) {
        guard registry?.canBindFromShortcutKeyboard(.init(rawValue: proposed.commandID)) == true,
              model.bindings[proposed.commandID] == proposed.previous,
              model.bindings.first(where: { $0.value == proposed.target })?.key == proposed.displaced else {
            closePicker()
            selection.feedback = "快捷键或命令已变化，请重新选择。"
            return
        }
        var bindings = model.bindings
        if let displaced = proposed.displaced { bindings.removeValue(forKey: displaced) }
        bindings[proposed.commandID] = proposed.target
        saveBindings(bindings, message: "已保存")
    }

    private func unbind() {
        guard let owner else { return }
        var bindings = model.bindings
        bindings.removeValue(forKey: owner)
        saveBindings(bindings, message: "已解除绑定")
    }

    private func saveBindings(_ bindings: [String: Shortcut], message: String) {
        do {
            try model.updateShortcuts(bindings)
            closePicker()
            selection.feedback = message
        } catch {
            closePicker()
            selection.feedback = error.localizedDescription
        }
    }

    private struct Key: Identifiable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let label: String
        let legend: String?
        let code: UInt32?
        let modifier: UInt32
        var id: String { "\(x),\(y)" }
        var description: String { [label, legend].compactMap { $0 }.joined(separator: " ") }
    }

    private static let editableCodes = Set(layout.compactMap(\.code))

    private static let layout: [Key] = {
        var keys: [Key] = []
        func cap(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ label: String,
                 legend: String? = nil, code: UInt32? = nil, modifier: UInt32 = 0, height: CGFloat = 63) {
            keys.append(Key(x: x, y: y, width: width, height: height, label: label, legend: legend, code: code, modifier: modifier))
        }
        func row(_ y: CGFloat, _ x: CGFloat, _ letters: String, _ codes: [UInt32], legends: String = "") {
            let symbols = Array(legends)
            for (index, letter) in letters.enumerated() {
                cap(x + CGFloat(index) * 71.5, y, 64.5, String(letter),
                    legend: symbols.indices.contains(index) ? String(symbols[index]) : nil, code: codes[index])
            }
        }

        cap(0, 0, 100, "esc", code: 53)
        let functionCodes: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, symbol) in ["☼", "☀", "▤", "⌕", "♩", "☾", "◁◁", "⏯", "▷▷", "◌", "◖", "◖))"].enumerated() {
            cap(107 + CGFloat(index) * 71.5, 0, 64.5, "F\(index + 1)", legend: symbol, code: functionCodes[index])
        }
        cap(965, 0, 65, "◯")
        cap(0, 70, 64.5, "`", legend: "~", code: 50)
        row(70, 71.5, "1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29], legends: "!@#$%^&*()")
        cap(786.5, 70, 64.5, "−", legend: "_", code: 27)
        cap(858, 70, 64.5, "=", legend: "+", code: 24)
        cap(930, 70, 100, "⌫", code: 51)
        cap(0, 139, 100, "⇥", code: 48)
        row(139, 107, "QWERTYUIOP", [12, 13, 14, 15, 17, 16, 32, 34, 31, 35])
        cap(822, 139, 64.5, "[", legend: "{", code: 33)
        cap(893.5, 139, 64.5, "]", legend: "}", code: 30)
        cap(965, 139, 65, "\\", legend: "|", code: 42)
        cap(0, 209, 118, "⇪")
        row(209, 125, "ASDFGHJKL", [0, 1, 2, 3, 5, 4, 38, 40, 37])
        cap(768.5, 209, 64.5, ";", legend: ":", code: 41)
        cap(840, 209, 64.5, "'", legend: "\"", code: 39)
        cap(911.5, 209, 118.5, "↩", code: 36)
        cap(0, 279, 153, "⇧", modifier: 512)
        row(279, 160, "ZXCVBNM", [6, 7, 8, 9, 11, 45, 46])
        cap(660.5, 279, 64.5, ",", legend: "<", code: 43)
        cap(732, 279, 64.5, ".", legend: ">", code: 47)
        cap(803.5, 279, 64.5, "/", legend: "?", code: 44)
        cap(875, 279, 155, "⇧", modifier: 512)
        cap(0, 349, 64.5, "fn", legend: "◎")
        cap(71.5, 349, 64.5, "⌃", modifier: 4096)
        cap(143, 349, 64.5, "⌥", modifier: 2048)
        cap(214.5, 349, 82, "⌘", modifier: 256)
        cap(303.5, 349, 350, "", code: 49)
        cap(661, 349, 82, "⌘", modifier: 256)
        cap(750.5, 349, 64.5, "⌥", modifier: 2048)
        cap(822, 380, 64.5, "←", code: 123, height: 32)
        cap(893.5, 349, 64.5, "↑", code: 126, height: 31)
        cap(893.5, 380, 64.5, "↓", code: 125, height: 32)
        cap(965, 380, 65, "→", code: 124, height: 32)
        return keys
    }()
}
