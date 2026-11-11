import SwiftUI
import KeylaneCore

enum LauncherEscapeBehavior: String {
    case backOrClose, closeWindow
}

enum PageNavigationKeys: String {
    case brackets, arrows

    var back: KeyEquivalent { self == .brackets ? "[" : .leftArrow }
    var forward: KeyEquivalent { self == .brackets ? "]" : .rightArrow }
}

struct KeyboardPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$launcherEscapeBehavior),
            ViewObservation.changes(model.$escapeClosesUtilityWindows),
            ViewObservation.changes(model.$navigation),
            ViewObservation.changes(model.$pageNavigationKeys),
            ViewObservation.changes(model.$doubleTap),
            ViewObservation.changes(model.$hyperkey),
            ViewObservation.changes(model.$hyperIncludesShift),
            ViewObservation.changes(model.$replaceHyperKeycaps)
        ]))
    }

    private func binding<Value>(_ key: ReferenceWritableKeyPath<Model, Value>, updatesModifiers: Bool = false) -> Binding<Value> {
        Binding(get: { model[keyPath: key] }, set: {
            model[keyPath: key] = $0
            if updatesModifiers { model.configureModifiers() }
        })
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("Escape 键行为", detail: "控制按下 Escape 时启动器如何返回或隐藏。",
                               selection: binding(\.launcherEscapeBehavior)) {
                    Text("返回上一层或隐藏窗口").tag(LauncherEscapeBehavior.backOrClose)
                    Text("隐藏窗口").tag(LauncherEscapeBehavior.closeWindow)
                }.settingsAnchor(.keyboardEscapeBehavior)
                Divider()
                SettingsRow("Escape 键关闭窗口", detail: "在设置或文件操作窗口中按 Escape 关闭窗口。") {
                    Toggle("Escape 键关闭窗口", isOn: binding(\.escapeClosesUtilityWindows))
                        .labelsHidden().toggleStyle(SettingsSwitchStyle())
                }.settingsAnchor(.keyboardCloseWindow)
                Divider()
                // TODO: Restore the previous input source safely after the launcher closes.
                SettingsPicker("自动切换输入源", detail: "唤起启动器时切换输入源，关闭后恢复原来的输入源。",
                               selection: .constant("pending")) {
                    Text("待实现").tag("pending")
                }.disabled(true).settingsAnchor(.keyboardInputSource)
                Divider()
                SettingsPicker("导航绑定", detail: "为支持键盘导航的列表和控件选择方向键或 Control 组合键。",
                               selection: binding(\.navigation)) {
                    Text("方向键").tag("arrows")
                    Text("Vim（⌃H、⌃L、⌃K、⌃J）").tag("vim")
                    Text("Emacs（⌃P、⌃N）").tag("emacs")
                }.settingsAnchor(.keyboardNavigation)
                Divider()
                SettingsPicker("页面导航键", detail: "在设置窗口中按住 Command，配合所选按键前进或后退。",
                               selection: binding(\.pageNavigationKeys)) {
                    Text("方括号").tag(PageNavigationKeys.brackets)
                    Text("左右方向键").tag(PageNavigationKeys.arrows)
                }.settingsAnchor(.keyboardPageNavigation)
            }
            SettingsGroup {
                SettingsPicker("Hyper Key", detail: "将 Caps Lock 映射为 Control、Option 和 Command，可选加入 Shift。",
                               selection: binding(\.hyperkey, updatesModifiers: true)) {
                    Text("无").tag(false)
                    Text("Caps Lock").tag(true)
                }.settingsAnchor(.keyboardHyperKey)
                Divider()
                SettingsRow("包含 Shift（⇧）") {
                    Toggle("包含 Shift", isOn: binding(\.hyperIncludesShift, updatesModifiers: true))
                        .labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
                Divider()
                SettingsRow("用 ✦ 显示 Hyper Key 组合") {
                    Toggle("用符号显示 Hyper Key 组合", isOn: binding(\.replaceHyperKeycaps))
                        .labelsHidden().toggleStyle(SettingsSwitchStyle())
                }
            }
            SettingsGroup {
                SettingsShortcutBindingRow(title: "Keylane 热键", shortcut: model.bindings["launcher"], symbol: "command") {
                    model.setShortcut("launcher", value: $0)
                }.settingsAnchor(.keyboard)
                Divider()
                SettingsPicker("双击左侧修饰键唤起", selection: binding(\.doubleTap, updatesModifiers: true)) {
                    Text("关闭").tag("off")
                    Text("Command").tag("command")
                    Text("Option").tag("option")
                    Text("Control").tag("control")
                    Text("Shift").tag("shift")
                }
            }
        }
    }
}
