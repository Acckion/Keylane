import SwiftUI

struct UpdatePreferences: View {
    @ObservedObject var updates: KeylaneReleaseCheck

    var body: some View {
        SettingsGroup("软件更新") {
            SettingsRow {
                SettingsCaption(title: "检查更新", detail: updates.status)
            } control: {
                if updates.busy { ProgressView().controlSize(.small) }
                Button("检查更新") { updates.check() }
                    .disabled(updates.busy || updates.ready)
            }
            if let update = updates.available {
                SettingsRow {
                    SettingsCaption(title: update.release.tag, detail: "构建 \(update.build)")
                } control: {
                    Link("从 GitHub 下载 DMG", destination: update.asset(update.release.imageName))
                    if updates.ready {
                        Button("安装并重启") { updates.installAndRestart() }
                    } else if PreparedKeylaneUpdate.currentTeam != nil {
                        Button("在应用内下载") { updates.download() }.disabled(updates.busy)
                    }
                }
            }
            SettingsRow {
                SettingsCaption(title: "自动更新", detail: "定期检查并下载经过验证的更新，下次退出 Keylane 时安装。")
            } control: {
                Toggle("自动更新", isOn: $updates.automatic).labelsHidden()
            }
            SettingsRow {
                SettingsCaption(title: "接受测试版更新", detail: "将 Alpha 和 Beta 纳入更新检查。")
            } control: {
                Toggle("接受测试版更新", isOn: $updates.includePrereleases).labelsHidden()
            }
            if PreparedKeylaneUpdate.currentTeam == nil {
                Text("当前构建的签名仅支持手动下载更新。").foregroundStyle(.secondary)
            }
        }
    }
}
