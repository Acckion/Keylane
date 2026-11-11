import SwiftUI
import KeylaneCore

struct LauncherBehaviorPreferences: View {
    let model: Model
    @StateObject private var observation: ViewObservation

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$placement),
            ViewObservation.changes(model.$launcherReturnDelay),
            ViewObservation.changes(model.$rootSearchSensitivity),
            ViewObservation.changes(model.$rootFileContentSearch),
            ViewObservation.changes(model.fileSearch.$options.map { [$0.enabled, $0.searchFromLauncher, $0.contentSearch] })
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                SettingsPicker("显示 Keylane 的位置",
                               selection: Binding(get: { model.placement }, set: { model.placement = $0 })) {
                    Text("鼠标所在屏幕").tag("activeScreen")
                    Text("主显示器").tag("primaryDisplay")
                    Text("记住上次位置").tag("remember")
                }.settingsAnchor(.windowPosition)
                Divider()
                SettingsPicker("返回主搜索", detail: "隐藏窗口达到指定时间后，再次唤起时清空查询并返回主搜索。",
                               selection: Binding(get: { model.launcherReturnDelay }, set: { model.launcherReturnDelay = $0 })) {
                    ForEach(LauncherReturnDelay.allCases, id: \.self) { delay in
                        Text(returnDelayTitle(delay)).tag(delay)
                    }
                }.settingsAnchor(.launcherReturnDelay)
                Divider()
                SettingsPicker("主搜索灵敏度", detail: "较低灵敏度包含更多模糊匹配，较高灵敏度优先显示名称或别名前缀匹配。",
                               selection: Binding(get: { model.rootSearchSensitivity }, set: { model.rootSearchSensitivity = $0 })) {
                    Text("低").tag(LauncherSearchRanking.Sensitivity.low)
                    Text("中").tag(LauncherSearchRanking.Sensitivity.medium)
                    Text("高").tag(LauncherSearchRanking.Sensitivity.high)
                }.settingsAnchor(.rootSearchSensitivity)
                Divider()
                // TODO: Add a local query history and restore it with Up in root search.
                SettingsActionRow(title: "搜索历史", detail: "通过方向键恢复近期搜索和清除历史的功能待实现。",
                                  actionTitle: "重置") {}.disabled(true).settingsAnchor(.launcherSearchHistory)
            }

            SettingsSectionTitle(title: "自定义搜索")
            SettingsGroup {
                SettingsRow("在主搜索中显示文件", detail: model.fileSearch.options.enabled
                            ? "在启动器中直接搜索文件名。" : "请先启用文件搜索扩展。") {
                    Toggle("在主搜索中显示文件", isOn: Binding(
                        get: { model.fileSearch.options.searchFromLauncher },
                        set: { model.fileSearch.options.searchFromLauncher = $0 }
                    )).labelsHidden().toggleStyle(SettingsSwitchStyle())
                        .disabled(!model.fileSearch.options.enabled)
                }.settingsAnchor(.fileSearchInline)
                Divider()
                SettingsRow("在主搜索中匹配文件内容", detail: "需要在文件搜索中开启内容搜索。") {
                    Toggle("在主搜索中匹配文件内容", isOn: Binding(
                        get: { model.rootFileContentSearch },
                        set: { model.rootFileContentSearch = $0 }
                    )).labelsHidden().toggleStyle(SettingsSwitchStyle())
                        .disabled(!model.fileSearch.options.enabled || !model.fileSearch.options.searchFromLauncher ||
                                  !model.fileSearch.options.contentSearch)
                }.settingsAnchor(.rootFileContentSearch)
                Divider()
                // TODO: Add an opt-in Contacts result provider for root search.
                SettingsRow("在主搜索中显示联系人", detail: "待实现") {
                    Toggle("在主搜索中显示联系人", isOn: .constant(false))
                        .labelsHidden().toggleStyle(SettingsSwitchStyle()).disabled(true)
                }.settingsAnchor(.rootContactsSearch)
            }

            SettingsSectionTitle(title: "备选命令")
            SettingsGroup {
                // TODO: Let users select and reorder commands to run with the root query.
                SettingsActionRow(title: "备选命令", detail: "从主搜索调用备选命令的功能待实现。",
                                  actionTitle: "添加备选命令") {}.disabled(true)
            }.settingsAnchor(.launcherFallbackCommands)
        }
    }

    private func returnDelayTitle(_ delay: LauncherReturnDelay) -> String {
        switch delay {
        case .immediately: "立即"
        case .after30Seconds: "30 秒后"
        case .after90Seconds: "90 秒后"
        case .after5Minutes: "5 分钟后"
        case .never: "从不"
        }
    }
}
