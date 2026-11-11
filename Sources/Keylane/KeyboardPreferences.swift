import SwiftUI

struct KeyboardPreferences: View {
    let model: Model
    @StateObject private var observation: SettingsPageObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: SettingsPageObservation([
            SettingsPageObservation.changes(model.$bindings),
            SettingsPageObservation.changes(model.$navigation),
            SettingsPageObservation.changes(model.$doubleTap),
            SettingsPageObservation.changes(model.$hyperkey)
        ]))
    }

    private func binding<Value>(_ key: ReferenceWritableKeyPath<Model, Value>) -> Binding<Value> {
        Binding(get: { model[keyPath: key] }, set: { model[keyPath: key] = $0 })
    }

    var body: some View {
        SettingsGroup("键盘") {
            SettingsShortcutBindingRow(title: "Keylane 热键", shortcut: model.bindings["launcher"], symbol: "command") {
                model.setShortcut("launcher", value: $0)
            }
            Divider()
            SettingsPicker("导航", selection: binding(\.navigation)) { Text("方向键").tag("arrows"); Text("Vim").tag("vim"); Text("Emacs").tag("emacs") }
            Divider()
            SettingsPicker("双击左侧修饰键唤起", selection: binding(\.doubleTap)) {
                Text("关闭").tag("off")
                Keycap(text: "Command").tag("command"); Keycap(text: "Option").tag("option"); Keycap(text: "Control").tag("control"); Keycap(text: "Shift").tag("shift")
            }.onChange(of: model.doubleTap) { _, _ in model.configureModifiers() }
            Divider()
            Toggle(isOn: binding(\.hyperkey)) { Text("Caps Lock 作为 Hyperkey") }.onChange(of: model.hyperkey) { _, _ in model.configureModifiers() }
            Divider()
            SettingsRow("辅助功能") {
                HStack(spacing: 8) {
                    Button("请求权限") { model.requestKeyboardAccess() }
                    Button("重新启用") { model.configureModifiers() }
                }.buttonStyle(ContentActionButtonStyle())
            }
        }
    }
}
