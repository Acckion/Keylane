import AppKit
import SwiftUI
import KeylaneCore

struct AIFileToolSettings: View {
    @ObservedObject var preferences: AIFileToolPreferences
    @State private var folderError = ""
    var body: some View {
        SettingsGroup("AI 文件工具") {
            SettingsRow("允许 AI 访问文件", detail: "默认关闭。仅访问下方目录和当前项目。读取、编辑、复制、移动及废纸篓操作均逐次确认；不永久删除，敏感路径不开放。") {
                Toggle("允许 AI 访问文件", isOn: $preferences.enabled).labelsHidden().toggleStyle(SettingsSwitchStyle())
            }
        }
        SettingsListCard(title: "AI 已授权目录", detail: "Quick AI 与 AI Chat 共用；读取结果发送给所选模型。移除目录或关闭文件工具后，旧授权立即失效。", anchor: AIModule.fileAccess) {
            SettingsIconButton("添加 AI 文件访问目录", symbol: "plus", action: chooseDirectory)
                .disabled(preferences.scopes.count >= 16)
        } content: {
            if preferences.scopes.isEmpty { SettingsListEmptyState(title: "尚未添加目录；也可使用当前项目的工作目录。") }
            else {
                SettingsCompactList(items: preferences.scopes, id: \.id) { scope in
                    SettingsFolderRow(path: scope.path, selectable: true, showsActionsOnHover: true) {
                        SettingsRemoveItemButton(label: "移除 " + scope.path, help: "移除 AI 文件访问授权") { preferences.remove(scope.path) }
                    }
                }.padding(.bottom, 5)
            }
            if !folderError.isEmpty { SettingsDescription(folderError).padding(.vertical, 10) }
        }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { result in
            guard result == .OK, let selected = panel.url else { return }
            let url = selected.resolvingSymlinksInPath().standardizedFileURL
            do {
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                preferences.add(.init(path: url.path, bookmark: bookmark)); folderError = ""
            } catch { folderError = "无法保存目录授权，请重新选择。" }
        }
    }
}
