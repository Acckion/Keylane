import Carbon
import KeylaneCore
import SwiftUI

struct WindowManagementSettings: View {
    @ObservedObject var model: Model
    @ObservedObject var controller: WindowManagementController
    @ObservedObject var preferences: WindowManagementPreferences
    let anchor: SettingsItem
    @ObservedObject var shortcuts: WindowSpaceShortcuts
    @State private var expanded: Set<String> = []
    @State private var preset: Preset?
    @State private var removing: CustomWindowAction?
    @State private var replaceShortcuts = false
    @State private var message: String?

    private enum Preset: String, CaseIterable {
        case rectangle = "Rectangle"
        case spectacle = "Spectacle"

        var modifiers: UInt32 { self == .rectangle ? UInt32(controlKey | optionKey) : UInt32(cmdKey | optionKey) }

        var keys: [(String, Int, UInt32)] {
            let maximize = self == .rectangle ? kVK_Return : kVK_ANSI_F
            return [
                ("left-half", kVK_LeftArrow, modifiers), ("right-half", kVK_RightArrow, modifiers),
                ("top-half", kVK_UpArrow, modifiers), ("bottom-half", kVK_DownArrow, modifiers),
                ("maximize", maximize, modifiers), ("center", kVK_ANSI_C, modifiers)
            ]
        }
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsRow("窗口间距", detail: "相邻分屏窗口之间的间距。") { gapPicker($preferences.windowGap) }
                SettingsRow("屏幕边距", detail: "窗口与显示器可用区域边缘的距离。") { gapPicker($preferences.screenGap) }
                SettingsRow("循环", detail: "重复执行半屏命令时循环切换大小。") {
                    Picker("循环", selection: $preferences.cycling) {
                        ForEach(WindowManagementPreferences.Cycling.allCases, id: \.self) {
                            Text($0.label).tag($0)
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow("避让台前调度", detail: "为屏幕侧边的台前调度缩略图留出空间。") {
                    Toggle("避让台前调度", isOn: $preferences.respectStageManager).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow("快捷键预设", detail: "应用 Rectangle 或 Spectacle 的常用窗口管理快捷键。") {
                    Menu("应用预设") {
                        ForEach(Preset.allCases, id: \.self) { value in
                            Button(value.rawValue) { preset = value }
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("系统空间快捷键", detail: "使用 Mission Control 当前设置的左右空间快捷键。") {
                    Button(shortcuts.enabled ? "恢复系统快捷键" : "替换快捷键") {
                        if shortcuts.enabled { shortcuts.setEnabled(false) }
                        else { replaceShortcuts = true }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .settingsAnchor(anchor)

            SettingsGroup {
                newActionRow("创建窗口命令", symbol: "rectangle.badge.plus") { controller.edit(.init()) }
                newActionRow("创建窗口布局", symbol: "rectangle.split.2x1") { controller.edit(.init(windows: [])) }
            }
            if !controller.actions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("自定义命令和布局")
                    CommandSettingsList(items: controller.actions, id: \.id) { item in
                        entry(id: item.commandID, title: item.name,
                              symbol: item.windows == nil ? "rectangle.inset.filled" : "rectangle.split.2x1",
                              menu: [
                                .init(title: "编辑") { controller.edit(item) },
                                .init(title: "复制") { controller.duplicate(item) },
                                .init(title: "删除") { removing = item }
                              ])
                    }
                    Button("导出命令和布局") { controller.exportActions() }.padding(.leading, 16)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("命令")
                sectionTitle("移动和调整大小", secondary: true)
                commandList(WindowCommand.all.filter { !$0.isSpaceSwitch })
                sectionTitle("空间", secondary: true)
                commandList(WindowCommand.all.filter(\.isSpaceSwitch))
            }
        }
        .confirmationDialog("应用快捷键预设", isPresented: Binding(get: { preset != nil }, set: { if !$0 { preset = nil } }),
                            presenting: preset) { value in
            Button("应用 \(value.rawValue) 预设") { apply(value) }
        } message: { value in
            Text("将替换 \(value.keys.count) 条窗口命令的快捷键。")
        }
        .confirmationDialog("替换空间快捷键", isPresented: $replaceShortcuts) {
            Button("替换") { if let error = shortcuts.setEnabled(true) { message = error } }
        } message: {
            Text("窗口管理启用时，由 Keylane 接管当前的左右空间快捷键。可随时在这里恢复。")
        }
        .confirmationDialog("删除窗口命令或布局", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { item in
            Button("删除", role: .destructive) { controller.remove(item) }
        } message: { item in
            Text(item.name)
        }
        .alert("窗口管理", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    private func sectionTitle(_ title: String, secondary: Bool = false) -> some View {
        Text(title).font(secondary ? .subheadline : .headline)
            .foregroundStyle(secondary ? .secondary : .primary)
            .padding(.horizontal, 16)
            .accessibilityAddTraits(.isHeader)
    }

    private func gapPicker(_ selection: Binding<Int>) -> some View {
        Picker("间距", selection: selection) {
            Text("无").tag(0)
            Text("极小").tag(4)
            Text("小").tag(8)
            Text("中").tag(12)
            Text("大").tag(16)
            Text("极大").tag(24)
        }.labelsHidden().fixedSize()
    }

    private func newActionRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            SettingsRow {
                Label {
                    SettingsTitle(title)
                } icon: {
                    WindowCommandIcon(symbol: symbol)
                }
            } control: { Image(systemName: "plus.square") }
        }.buttonStyle(.plain)
        .accessibilityIdentifier(symbol)
    }

    private func commandList(_ commands: [WindowCommand]) -> some View {
        CommandSettingsList(items: commands, id: \.id, disclosure: { command in
            guard command.hasOptions else { return nil }
            return .init(isExpanded: Binding(get: { expanded.contains(command.id) }, set: { value in
                if value { expanded.insert(command.id) } else { expanded.remove(command.id) }
            }), content: { AnyView(commandOptions(command)) })
        }) { command in
            let menu: [CommandSettingsAction]
            if let geometry = command.fixedGeometry {
                menu = [.init(title: "复制为自定义命令") {
                    var copy = CustomWindowAction(geometry: geometry)
                    copy.name = command.title
                    controller.edit(copy)
                }]
            } else { menu = [] }
            return entry(id: command.id, title: command.title, symbol: command.symbol, region: command.region, menu: menu)
        }
    }

    private func entry(id: String, title: String, symbol: String, region: CGRect? = nil,
                       menu: [CommandSettingsAction]) -> CommandSettingsEntry<WindowCommandIcon> {
        CommandSettingsEntry(title: title, model: model, commandID: .init(rawValue: id),
                             isEnabled: Binding(get: { !model.disabledCommands.contains(id) },
                                                set: { value in
            if value { model.disabledCommands.remove(id) }
            else { model.disabledCommands.insert(id) }
        }), menu: menu) {
            WindowCommandIcon(symbol: symbol, region: region)
        }
    }

    @ViewBuilder private func commandOptions(_ command: WindowCommand) -> some View {
        switch command.action {
        case .almostMaximize:
            SettingsRow("百分比") {
                Picker("百分比", selection: option(\.percentage, command)) {
                    ForEach(Array(stride(from: 50, through: 95, by: 5)), id: \.self) { Text("\($0)%").tag($0) }
                }.labelsHidden().fixedSize()
            }
        case .adjustSize:
            SettingsRow("步长") {
                Picker("步长", selection: option(\.step, command)) {
                    ForEach([8, 16, 24, 32, 48, 64, 96, 128], id: \.self) { Text("\($0) 点").tag($0) }
                }.labelsHidden().fixedSize()
            }
        case .edge:
            optionToggle("沿另一方向居中", option(\.center, command))
        case .display:
            optionToggle("在显示器之间循环", option(\.wrap, command))
            optionToggle("保持宽高比", option(\.aspect, command))
        case .switchSpace:
            optionToggle("切换时使用系统动画", option(\.animateSpace, command))
        default:
            EmptyView()
        }
    }

    private func option<Value>(_ field: WritableKeyPath<WindowManagementPreferences.Options, Value>,
                               _ command: WindowCommand) -> Binding<Value> {
        Binding(get: { preferences.options(for: command)[keyPath: field] },
                set: { preferences.set(field, for: command, to: $0) })
    }

    private func optionToggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        SettingsRow(title) { Toggle(title, isOn: binding).labelsHidden().toggleStyle(.switch) }
    }

    private func apply(_ preset: Preset) {
        var bindings = model.bindings
        for (id, key, modifiers) in preset.keys { bindings["window-" + id] = Shortcut(key: UInt32(key), modifiers: modifiers) }
        do { try model.updateShortcuts(bindings) }
        catch { message = error.localizedDescription }
    }
}


struct WindowCommandIcon: View {
    let symbol: String
    var region: CGRect? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.15, green: 0.56, blue: 0.85).gradient)
            if let region {
                GeometryReader { geometry in
                    let size = geometry.size
                    RoundedRectangle(cornerRadius: 2).fill(.white)
                        .frame(width: region.width * size.width, height: region.height * size.height)
                        .offset(x: region.minX * size.width, y: region.minY * size.height)
                }
                .padding(4)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}
