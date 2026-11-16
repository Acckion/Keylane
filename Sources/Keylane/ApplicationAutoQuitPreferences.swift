import SwiftUI
import KeylaneCore

struct ApplicationAutoQuitPreferences: View {
    static let summary = "停止使用应用一段时间后自动退出。"

    let model: Model
    @ObservedObject private var autoQuit: ApplicationAutoQuit
    @ObservedObject private var catalog: ApplicationSettingsCatalog

    init(model: Model) {
        self.model = model
        autoQuit = model.applicationAutoQuit
        catalog = model.applicationSettingsCatalog
    }

    var body: some View {
        let names = Dictionary(uniqueKeysWithValues: catalog.items.map { ($0.id, $0.title) })
        let rules = autoQuit.rules.keys.map { path in
            let url = URL(fileURLWithPath: path)
            return ApplicationPreferenceItem(id: path, url: url, title: names[path] ?? model.appName(url), filename: url.lastPathComponent)
        }.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
        let duplicateNames = Dictionary(grouping: rules, by: \.title)
        SettingsPageSections {
            SettingsGroup {
                SettingsRow("默认自动退出时长") {
                    AutoQuitDurationPicker(label: "默认自动退出时长", minutes: autoQuit.defaultMinutes,
                                           defaultMinutes: nil, navigation: model.navigation, select: autoQuit.setDefaultMinutes)
                }
            }.settingsAnchor(.applicationAutoQuit)

            if rules.isEmpty {
                SettingsGroup {
                    SettingsRow("尚未添加应用", detail: "点右上角的加号，选择要自动退出的应用。") { EmptyView() }
                }
            } else {
                SettingsGroup {
                    ForEach(rules) { item in
                        if item.id != rules.first?.id { Divider().opacity(0.4) }
                        let minutes = autoQuit.minutes(for: item.url)
                        let duplicateName = duplicateNames[item.title, default: []].count > 1
                        let detail = minutes == 0 ? "原应用已移动、删除或替换。" : (duplicateName ? item.id : nil)
                        SettingsRow {
                            HStack(spacing: 9) {
                                WorkspaceItemIcon(path: item.id).frame(width: 18, height: 18).accessibilityHidden(true)
                                SettingsRowLabel(title: item.title, detail: detail)
                            }.help(item.id)
                        } control: {
                            HStack(spacing: 12) {
                                if minutes != 0 {
                                    AutoQuitDurationPicker(label: "\(item.title)的自动退出时长", minutes: minutes,
                                                           defaultMinutes: autoQuit.defaultMinutes, navigation: model.navigation) { value in
                                        guard autoQuit.minutes(for: item.url) != 0 else { return }
                                        autoQuit.setMinutes(value, for: item.url)
                                    }
                                }
                                SettingsRemoveItemButton(label: "移除 \(item.title)", help: "关闭此应用的自动退出") {
                                    autoQuit.removeRule(at: item.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
