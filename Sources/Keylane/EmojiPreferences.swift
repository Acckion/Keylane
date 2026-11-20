import SwiftUI
import KeylaneCore

struct EmojiPreferences: View {
    @ObservedObject var controller: EmojiSearchController
    let model: Model
    @StateObject private var observation: ViewObservation
    private let command = CommandID(rawValue: "emoji-symbols")

    init(controller: EmojiSearchController, model: Model) {
        self.controller = controller
        self.model = model
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases), ViewObservation.changes(model.$bindings),
            ViewObservation.changes(model.$disabledCommands)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsCard(anchor: .emojiColumns) {
                SettingsTitle("列数")
                GridColumnChoices(counts: EmojiSearchController.columnCounts, selection: $controller.columns)
            }
            SettingsCard(anchor: .emojiBehavior) {
                SettingsPicker("主要操作", selection: $controller.primaryAction) {
                    ForEach(EmojiSearchController.PrimaryAction.allCases, id: \.self) { action in
                        Text(action.title).tag(action)
                    }
                }
                Divider()
                SettingsRow("Emoji 肤色") {
                    HStack(spacing: 4) {
                        ForEach(Array(EmojiSearchController.skinTones.enumerated()), id: \.offset) { index, glyph in
                            Button { controller.skinTone = index } label: {
                                Text(glyph).font(.system(size: 17)).frame(width: 30, height: 30)
                                    .background(.primary.opacity(controller.skinTone == index ? 0.12 : 0),
                                                in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(["默认肤色", "浅肤色", "中浅肤色", "中等肤色", "中深肤色", "深肤色"][index])
                            .accessibilityAddTraits(controller.skinTone == index ? .isSelected : [])
                        }
                    }
                }
                Divider()
                Toggle(isOn: $controller.disablesInlinePicker) {
                    SettingsCaption(title: "停用内联 Emoji 选择器", detail: "在启动器搜索框中键入冒号时，不打开 Emoji 选择器。")
                }
            }
            SettingsSectionTitle(title: "命令")
            CommandSettingsList(items: [command], id: \.rawValue) { id in
                CommandSettingsEntry(title: "搜索 Emoji 与符号", model: model, commandID: id,
                                     isEnabled: Binding(get: { !model.disabledCommands.contains(id.rawValue) }, set: {
                    if $0 { model.disabledCommands.remove(id.rawValue) }
                    else { model.disabledCommands.insert(id.rawValue) }
                })) {
                    SettingsIcon(symbol: "face.smiling", artwork: ModuleArtwork.command(id, settingsPage: "keylane.emoji"))
                }
            }
            SettingsSectionTitle(title: "AI 扩展")
            ExtensionCommandPreferences(model: model, commands: model.launcherModules?.aiCommands(in: EmojiAIActions.moduleID) ?? [])
            SettingsDescription("推荐由你主动运行，不会随每次输入请求模型。结果只使用本地目录中的字符。")
        }
    }
}
