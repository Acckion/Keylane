import SwiftUI
import ServiceManagement

struct KeyboardPreferences: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("显示 / 隐藏启动器"); Spacer(); ShortcutRecorder(shortcut: model.bindings["launcher"], title: "显示 / 隐藏启动器", icon: AnyView(Image(systemName: "command"))) { model.setShortcut("launcher", value: $0) } }
            HStack { Text("全局打开设置"); Spacer(); ShortcutRecorder(shortcut: model.bindings["settings"], title: "全局打开设置", icon: AnyView(Image(systemName: "gearshape"))) { model.setShortcut("settings", value: $0) } }
            Text("更改快捷键前会检查占用；失败时保留原设置。").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) { Text("窗口内保留").font(.caption).foregroundStyle(.secondary); Keycaps(keys: ["⌘", "K"]); Keycaps(keys: ["⌘", ","]); Keycaps(keys: ["⌘", "1"]); Text("至").font(.caption); Keycaps(keys: ["⌘", "9"]) }
            Divider()
            SettingsPicker("导航", selection: $model.navigation) { Text("方向键").tag("arrows"); Text("Vim").tag("vim"); Text("Emacs").tag("emacs") }
            HStack { Text("向下 / 向上").font(.caption).foregroundStyle(.secondary); Keycaps(keys: model.navigation == "arrows" ? ["↓"] : ["⌃", model.navigation == "vim" ? "J" : "N"]); Keycaps(keys: model.navigation == "arrows" ? ["↑"] : ["⌃", model.navigation == "vim" ? "K" : "P"]) }
            SettingsPicker("双击左侧修饰键唤起", selection: $model.doubleTap) {
                Text("关闭").tag("off")
                Keycap(text: "Command").tag("command"); Keycap(text: "Option").tag("option"); Keycap(text: "Control").tag("control"); Keycap(text: "Shift").tag("shift")
            }.onChange(of: model.doubleTap) { _, _ in model.configureModifiers() }
            Toggle(isOn: $model.hyperkey) { HStack { Keycap(text: "Caps Lock"); Text("作为 Hyperkey"); Keycaps(keys: ["⌃", "⌥", "⇧", "⌘"]) } }.onChange(of: model.hyperkey) { _, _ in model.configureModifiers() }
            Text(model.modifierStatus).font(.caption).foregroundStyle(.secondary)
            HStack { Button("请求辅助功能权限") { model.requestKeyboardAccess() }.buttonStyle(.glass); Button("重新启用") { model.configureModifiers() }.buttonStyle(.glass) }
            Text("修饰键功能默认关闭。Hyperkey 仅运行期间生效；安全输入期间暂停。请在授权后实际测试键盘，其他键盘映射工具可能冲突。").font(.caption).foregroundStyle(.secondary)
        }
    }
}
