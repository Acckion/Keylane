import AppKit
import KeylaneCore
import SwiftUI

final class ShortcutKeyboardSelection: ObservableObject {
    @Published var input = ShortcutKeyboardInput(selected: Shortcut(key: 3, modifiers: 256))
    var shortcut: Shortcut { input.selected }
    var previewModifiers: UInt32? { input.previewModifiers }
    @Published var choosing = false
    @Published var feedback: String?
}

struct ShortcutKeyboardPage: View {
    static let pageID = PageID(rawValue: "ShortcutKeyboard")

    let model: Model
    @ObservedObject var selection: ShortcutKeyboardSelection
    let showsToolbarControls: Bool
    @StateObject private var observation: ViewObservation
    @State private var query = ""
    @State private var stagedCommand: String?
    @State private var change: Change?
    @State private var inputMonitor: Any?

    private struct Change {
        let target: Shortcut
        let commandID: String
        let previous: Shortcut?
        let displaced: String?
    }

    init(model: Model, selection: ShortcutKeyboardSelection, showsToolbarControls: Bool = false) {
        self.model = model
        self.selection = selection
        self.showsToolbarControls = showsToolbarControls
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$disabledCommands)
        ] + (model.launcherModules.map { $0.shortcutSettingsUpdates() + [$0.availabilityChanges.eraseToAnyPublisher()] } ?? [])))
    }

    private var shortcut: Shortcut { selection.shortcut }
    private var owner: String? { model.bindings.first { $0.value == shortcut }?.key }
    private var validation: String? {
        ShortcutValidation.conflict(in: ["shortcut": shortcut])
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
        if showsToolbarControls {
            keyboardControls(commandName: owner.map { names[$0] ?? $0 })
        } else {
            keyboardContent(catalog, names: names, registry: registry)
        }
    }

    private func keyboardContent(_ catalog: [ShortcutCommandName], names: [String: String],
                                 registry: LauncherModuleRegistry?) -> some View {
        let bindingsByShortcut = Dictionary(model.bindings.sorted { $0.key < $1.key }.map { ($0.value, $0.key) },
                                            uniquingKeysWith: { first, _ in first })
        return keyboard(bindings: bindingsByShortcut, names: names)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("MacBook Air ANSI 键盘")
            .padding(.horizontal, 22)
            .padding(.top, VisualStyle.launcherTopInset + 10)
            .frame(maxHeight: .infinity, alignment: .top)
        .overlay {
            if selection.choosing {
                ZStack {
                    Color.black.opacity(0.26).contentShape(Rectangle())
                        .onTapGesture { closePicker() }
                        .accessibilityHidden(true)
                    Group {
                        if let change {
                            confirmation(change, names: names, registry: registry)
                        } else {
                            commandPicker(catalog, registry: registry)
                        }
                    }
                    .frame(width: 420)
                    .modifier(LauncherMenuSurface(open: true))
                }
                .padding(.bottom, VisualStyle.launcherBottomInset)
                .onExitCommand { if !SearchField.isComposing { closePicker() } }
            }
        }
        .onAppear(perform: startCapturing)
        .onDisappear(perform: stopCapturing)
        .onChange(of: selection.choosing) { _, choosing in
            if choosing {
                query = ""
                stagedCommand = nil
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

    private func keyboardControls(commandName: String?) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 8) {
                    Keycaps(keys: shortcut.keycaps)
                    Text(commandName ?? "未绑定")
                        .font(.caption).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(.secondary)
                }
                if let message = selection.feedback ?? validation {
                    Text(message)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).help(message)
                }
            }
            .frame(maxWidth: 345, alignment: .trailing)
            if commandName != nil {
                Button("解除绑定", action: unbind)
                    .buttonStyle(ContentActionButtonStyle())
                    .fixedSize()
            }
            Button(commandName == nil ? "绑定命令" : "更换命令") {
                selection.feedback = nil
                selection.choosing = true
            }
            .buttonStyle(ContentActionButtonStyle(active: true))
            .disabled(validation != nil)
            .fixedSize()
        }
        .frame(minHeight: 36)
        .opacity(selection.previewModifiers == nil ? 1 : 0)
        .accessibilityHidden(selection.previewModifiers != nil)
        .allowsHitTesting(selection.previewModifiers == nil)
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

    private func commandPicker(_ catalog: [ShortcutCommandName], registry: LauncherModuleRegistry?) -> some View {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = catalog.filter {
            $0.id != owner && (term.isEmpty || $0.title.localizedCaseInsensitiveContains(term)
                || model.aliases[$0.aliasKey ?? $0.id]?.localizedCaseInsensitiveContains(term) == true)
                && registry?.canBindFromShortcutKeyboard(.init(rawValue: $0.id)) == true
        }
        return SettingsGroup {
            SettingsSearchField(text: $query, placeholder: "搜索命令…", autofocus: true,
                                cancel: closePicker, submit: {
                if let command = commands.first { stagedCommand = command.id }
            })
            if commands.isEmpty {
                SettingsDescription("没有匹配的命令")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commands) { command in
                            Button {
                                stagedCommand = command.id
                            } label: {
                                HStack {
                                    Text(command.title).lineLimit(1)
                                    Spacer()
                                    if let current = model.bindings[command.id] {
                                        Text(current.label).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .background(stagedCommand == command.id ? Color.accentColor.opacity(0.13) : .clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(stagedCommand == command.id ? .isSelected : [])
                        }
                    }
                }.frame(height: CGFloat(min(commands.count, 6)) * 30)
            }
            HStack {
                Spacer()
                Button("取消", action: closePicker)
                Button("保存绑定") {
                    if let stagedCommand { assign(stagedCommand, registry: registry) }
                }.disabled(!commands.contains { $0.id == stagedCommand })
            }
        }.onChange(of: query) { _, _ in stagedCommand = nil }
    }

    private func keyboard(bindings: [Shortcut: String], names: [String: String]) -> some View {
        GeometryReader { proxy in
            let unit = proxy.size.width / 1030
            ZStack(alignment: .topLeading) {
                ForEach(Self.layout) { cap in
                    let displayedModifiers = selection.previewModifiers ?? shortcut.modifiers
                    let chord = cap.code.map { Shortcut(key: $0, modifiers: displayedModifiers) }
                    let bound = chord.flatMap { bindings[$0] }
                    let name = bound.map { names[$0] ?? $0 }
                    let active = cap.modifier != 0 && displayedModifiers & cap.modifier != 0
                    let selected = selection.previewModifiers == nil && cap.code == shortcut.key
                    Group {
                        if cap.code != nil || cap.modifier != 0 {
                            Button {
                                if let code = cap.code {
                                    selection.input.select(Shortcut(key: code, modifiers: displayedModifiers))
                                } else {
                                    selection.input.select(Shortcut(key: shortcut.key, modifiers: displayedModifiers ^ cap.modifier))
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
        guard validation == nil, id != owner else { return }
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
