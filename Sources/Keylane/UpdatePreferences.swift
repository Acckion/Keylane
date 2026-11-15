import SwiftUI
import KeylaneCore

struct UpdatePreferences: View {
    @ObservedObject var updates: KeylaneReleaseCheck

    var body: some View {
        SettingsGroup("软件更新") {
            SettingsRow {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsCaption(title: "检查更新", detail: updates.status)
                    if let lastCheckedAt = updates.lastCheckedAt {
                        Text("上次检查：\(lastCheckedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } control: {
                Button("更新日志") { updates.showsReleaseNotes = true }
                Button("检查更新") { updates.check() }
                    .disabled(updates.busy || updates.ready)
            }
            if let update = updates.available {
                SettingsRow {
                    SettingsCaption(title: update.release.tag,
                                    detail: "构建 \(update.build) · \(update.release.prerelease ? "测试版" : "正式版")")
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
                SettingsCaption(title: "自动更新", detail: PreparedKeylaneUpdate.currentTeam == nil
                    ? "定期检查更新。发现新版本后，可从 GitHub 手动下载。"
                    : "定期检查更新。通过签名与公证验证的更新会在下次退出时安装。")
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
        }.sheet(isPresented: $updates.showsReleaseNotes) {
            ReleaseNotesSheet(updates: updates)
        }
    }
}

private struct ReleaseNotesSheet: View {
    @ObservedObject var updates: KeylaneReleaseCheck
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTag: String?
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SettingsTitle("更新日志")
                Spacer()
                Link("在 GitHub 中查看", destination: KeylaneReleaseCheck.releasesURL)
            }
            if let releases = updates.releaseHistory, !releases.isEmpty {
                let release = releases.first { $0.tag == selectedTag } ?? releases[0]
                Picker("版本", selection: Binding(get: { release.tag }, set: { selectedTag = $0 })) {
                    ForEach(releases, id: \.tag) { entry in
                        Text(entry.tag + (entry.prerelease ? " · 测试版" : " · 正式版")).tag(entry.tag)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(release.title.flatMap { $0.isEmpty ? nil : $0 } ?? release.tag)
                            .font(.headline)
                        if let publishedAt = release.publishedAt {
                            Text(publishedAt, style: .date).foregroundStyle(.secondary)
                        }
                        ReleaseNotesBody(notes: release.notes)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                Link("查看此版本的发布页面",
                     destination: KeylaneReleaseCheck.releasesURL.appendingPathComponent("tag").appendingPathComponent(release.tag))
            } else if updates.releaseHistoryError {
                Text("无法读取 GitHub 更新日志。").foregroundStyle(.secondary)
                Button("重试") { refresh += 1 }
            } else if updates.releaseHistory != nil {
                Text("暂无发布记录。").foregroundStyle(.secondary)
            } else {
                ProgressView("正在读取更新日志…")
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .onAppear { selectedTag = updates.available?.release.tag }
        .task(id: refresh) { await updates.loadReleaseHistory() }
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http"].contains(url.scheme?.lowercased()) ? .systemAction : .discarded
        })
    }

}
