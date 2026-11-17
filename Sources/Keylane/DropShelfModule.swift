import AppKit
import SwiftUI
import KeylaneCore

enum DropShelfModule {
    static func make(model: Model) -> LauncherModule {
        let controller = model.dropShelf
        let settingsID = "keylane.drop-shelf"
        let definitions: [(String, String, String, () -> Void)] = [
            ("drop-shelf-new", "新建暂存架", "tray.badge", { controller.create() }),
            ("drop-shelf-clipboard", "从剪贴板创建暂存架", "doc.on.clipboard", controller.clipboardShelf),
            ("drop-shelf-select", "选择暂存架", "tray.full", controller.selectShelf)
        ]
        let commands: [LauncherModule.Command] = definitions.map { id, title, symbol, execute in
            .init(declaration: .init(id: .init(rawValue: id), title: title, detail: "本地暂存与跨应用拖放", symbol: symbol,
                                     keywords: ["Shelf", "Dropover", "暂存", "拖放"], destination: .action, settingsPage: settingsID),
                  execute: { _ in (NSApp.delegate as? Delegate)?.hideLauncher(); execute() })
        }
        let anchor = SettingsItem(id: "dropShelf.behavior", page: settingsID, title: "暂存架交互", keywords: "摇晃 复制 拖出 最近 固定")
        return .init(id: .init(rawValue: settingsID), title: "暂存架", symbol: "tray", commands: commands,
                     settings: [.init(id: settingsID, title: "暂存架", symbol: "tray", subtitle: "收集文件、图片、链接与文字，再拖到目标应用。", order: 85,
                                      items: [anchor], content: { [weak model] in
            guard let model else { return AnyView(EmptyView()) }
            return AnyView(DropShelfPreferences(controller: controller, model: model, commands: commands, anchor: anchor))
        })], services: [.init(start: { [weak model] in if let model { controller.start(registry: model.menuBar) } }, stop: controller.stop)])
    }
}

private struct DropShelfPreferences: View {
    @ObservedObject var controller: DropShelfController
    @ObservedObject var model: Model
    let commands: [LauncherModule.Command]
    let anchor: SettingsItem
    var body: some View {
        SettingsPageSections {
            SettingsCard(anchor: anchor) {
                SettingsRow("摇晃指针创建暂存架", detail: "拖动内容时左右摇晃指针，在指针附近显示暂存架。") {
                    Toggle("摇晃指针创建暂存架", isOn: $controller.shakeEnabled).labelsHidden()
                }
                SettingsRow("默认复制到目标", detail: "关闭时遵循 macOS 拖放规则：同卷默认移动，按 Option 复制。移动由目标应用执行。") {
                    Toggle("默认复制到目标", isOn: $controller.copyByDefault).labelsHidden()
                }
                SettingsRow("拖出后保持打开", detail: "关闭时，目标接收成功后关闭暂存架；取消或拒绝时保留。") {
                    Toggle("拖出后保持打开", isOn: $controller.keepOpen).labelsHidden()
                }
                SettingsRow("最近与固定", detail: "最近 10 个暂存架可从菜单栏重新打开；固定架持续保留。清空与移除只影响暂存记录，不删除源文件。") { EmptyView() }
                if !controller.error.isEmpty { Text(controller.error).foregroundStyle(.red) }
            }
            ExtensionCommandPreferences(model: model, commands: commands)
        }
    }
}
