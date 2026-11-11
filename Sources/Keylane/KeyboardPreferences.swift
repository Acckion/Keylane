import SwiftUI
import ServiceManagement

struct KeyboardPreferences: View {
    @ObservedObject var model: Model
    var body: some View {
        SettingsGroup("键盘") {
            SettingsRow("Keylane 热键") {
                ShortcutRecorder(shortcut: model.bindings["launcher"], title: "Keylane 热键",
                                 icon: AnyView(Image(systemName: "command"))) {
                    model.setShortcut("launcher", value: $0)
                }
            }
            Divider()
            SettingsRow("全局打开设置") {
                ShortcutRecorder(shortcut: model.bindings["settings"], title: "全局打开设置",
                                 icon: AnyView(Image(systemName: "gearshape"))) {
                    model.setShortcut("settings", value: $0)
                }
            }
            Divider()
            SettingsPicker("导航", selection: $model.navigation) { Text("方向键").tag("arrows"); Text("Vim").tag("vim"); Text("Emacs").tag("emacs") }
            Divider()
            SettingsPicker("双击左侧修饰键唤起", selection: $model.doubleTap) {
                Text("关闭").tag("off")
                Keycap(text: "Command").tag("command"); Keycap(text: "Option").tag("option"); Keycap(text: "Control").tag("control"); Keycap(text: "Shift").tag("shift")
            }.onChange(of: model.doubleTap) { _, _ in model.configureModifiers() }
            Divider()
            Toggle(isOn: $model.hyperkey) { Text("Caps Lock 作为 Hyperkey") }.onChange(of: model.hyperkey) { _, _ in model.configureModifiers() }
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
