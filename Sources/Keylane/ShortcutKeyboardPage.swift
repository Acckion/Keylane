import KeylaneCore
import SwiftUI

struct ShortcutKeyboardPage: View {
    static let pageID = PageID(rawValue: "ShortcutKeyboard")
    let back: () -> Void

    let model: Model
    @StateObject private var observation: ViewObservation
    @State private var modifiers: UInt32 = 256
    @State private var key: UInt32 = 3
    @State private var choosing = false
    @State private var query = ""
    @State private var stagedCommand: String?
    @State private var change: Change?
    @State private var feedback: String?

    private struct Change {
        let target: Shortcut
        let commandID: String
        let previous: Shortcut?
        let displaced: String?
    }

    init(model: Model, back: @escaping () -> Void) {
        self.model = model
        self.back = back
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$aliases),
            ViewObservation.changes(model.$disabledCommands)
        ] + (model.launcherModules.map { $0.shortcutSettingsUpdates() + [$0.availabilityChanges.eraseToAnyPublisher()] } ?? [])))
    }

    private var shortcut: Shortcut { Shortcut(key: key, modifiers: modifiers) }
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
        let bindingsByShortcut = Dictionary(model.bindings.sorted { $0.key < $1.key }.map { ($0.value, $0.key) },
                                            uniquingKeysWith: { first, _ in first })
        return LauncherCreationForm(back: back) {
            keyboardControls(commandName: owner.map { names[$0] ?? $0 })
        } fields: {
            keyboard(bindings: bindingsByShortcut, names: names)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("MacBook Air ANSI 键盘")
                .padding(.horizontal, 22)
        }
        .overlay {
            if choosing {
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
        .onReceive(NotificationCenter.default.publisher(for: .launcherHidden)) { _ in closePicker() }
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
                if let message = feedback ?? validation {
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
                query = ""
                stagedCommand = nil
                feedback = nil
                choosing = true
            }
            .buttonStyle(ContentActionButtonStyle(active: true))
            .disabled(validation != nil)
            .fixedSize()
        }
        .frame(minHeight: 36)
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
        choosing = false
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
                    let chord = cap.code.map { Shortcut(key: $0, modifiers: modifiers) }
                    let bound = chord.flatMap { bindings[$0] }
                    let name = bound.map { names[$0] ?? $0 }
                    let active = cap.modifier != 0 && modifiers & cap.modifier != 0
                    let selected = cap.code == key
                    Group {
                        if cap.code != nil || cap.modifier != 0 {
                            Button {
                                if let code = cap.code { key = code }
                                else { modifiers ^= cap.modifier }
                                choosing = false
                                feedback = nil
                            } label: {
                                keycap(cap, name: name, active: active, selected: selected)
                            }.buttonStyle(.plain)
                                .help(name ?? cap.description)
                                .accessibilityLabel(chord?.label ?? cap.description)
                                .accessibilityValue(name ?? (cap.modifier != 0 ? (active ? "已按下" : "未按下") : "未绑定"))
                                .accessibilityAddTraits(active || selected ? .isSelected : [])
                        } else {
                            keycap(cap, name: nil, active: false, selected: false)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(width: cap.width * unit, height: cap.height * unit)
                    .position(x: (cap.x + cap.width / 2) * unit, y: (cap.y + cap.height / 2) * unit)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.aspectRatio(1030.0 / 412, contentMode: .fit)
    }

    private func keycap(_ cap: Key, name: String?, active: Bool, selected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        return VStack(spacing: 0) {
            if let legend = cap.legend {
                Text(legend).font(.system(size: 7)).foregroundStyle(.secondary)
            }
            Text(cap.label).font(.system(size: cap.label.count > 2 ? 8 : 11, weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.7)
            if let name {
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
            feedback = "快捷键或命令已变化，请重新选择。"
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
            feedback = message
        } catch {
            closePicker()
            feedback = error.localizedDescription
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

        cap(0, 0, 100, "esc")
        for (index, symbol) in ["☼", "☀", "▤", "⌕", "♩", "☾", "◁◁", "⏯", "▷▷", "◌", "◖", "◖))"].enumerated() {
            cap(107 + CGFloat(index) * 71.5, 0, 64.5, "F\(index + 1)", legend: symbol)
        }
        cap(965, 0, 65, "◯")
        cap(0, 70, 64.5, "`", legend: "~")
        row(70, 71.5, "1234567890", [18, 19, 20, 21, 23, 22, 26, 28, 25, 29], legends: "!@#$%^&*()")
        cap(786.5, 70, 64.5, "−", legend: "_")
        cap(858, 70, 64.5, "=", legend: "+")
        cap(930, 70, 100, "⌫")
        cap(0, 139, 100, "⇥")
        row(139, 107, "QWERTYUIOP", [12, 13, 14, 15, 17, 16, 32, 34, 31, 35])
        cap(822, 139, 64.5, "[", legend: "{")
        cap(893.5, 139, 64.5, "]", legend: "}")
        cap(965, 139, 65, "\\", legend: "|")
        cap(0, 209, 118, "⇪")
        row(209, 125, "ASDFGHJKL", [0, 1, 2, 3, 5, 4, 38, 40, 37])
        cap(768.5, 209, 64.5, ";", legend: ":")
        cap(840, 209, 64.5, "'", legend: "\"")
        cap(911.5, 209, 118.5, "↩")
        cap(0, 279, 153, "⇧", modifier: 512)
        row(279, 160, "ZXCVBNM", [6, 7, 8, 9, 11, 45, 46])
        cap(660.5, 279, 64.5, ",", legend: "<")
        cap(732, 279, 64.5, ".", legend: ">")
        cap(803.5, 279, 64.5, "/", legend: "?")
        cap(875, 279, 155, "⇧", modifier: 512)
        cap(0, 349, 64.5, "fn", legend: "◎")
        cap(71.5, 349, 64.5, "⌃", modifier: 4096)
        cap(143, 349, 64.5, "⌥", modifier: 2048)
        cap(214.5, 349, 82, "⌘", modifier: 256)
        cap(303.5, 349, 350, "", code: 49)
        cap(661, 349, 82, "⌘", modifier: 256)
        cap(750.5, 349, 64.5, "⌥", modifier: 2048)
        cap(822, 380, 64.5, "←", height: 32)
        cap(893.5, 349, 64.5, "↑", height: 31)
        cap(893.5, 380, 64.5, "↓", height: 32)
        cap(965, 380, 65, "→", height: 32)
        return keys
    }()
}
