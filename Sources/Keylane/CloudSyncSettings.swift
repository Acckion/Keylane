import SwiftUI
import KeylaneCore

struct CloudSyncSettings: View {
    @ObservedObject var sync: CloudSyncController
    var body: some View {
        SettingsPageSections {
            SettingsGroup("同步状态") {
                SettingsRow("iCloud Drive 文件夹", detail: sync.folderName) {
                    Button("选择文件夹…") { sync.chooseFolder() }
                }
                SettingsRow("自动同步", detail: sync.status) {
                    Button("立即同步") { sync.syncNow() }.disabled(!sync.enabled || sync.busy)
                }
                if let last = sync.lastSync {
                    SettingsRow("上次同步") { Text(last, style: .relative).foregroundStyle(.secondary) }
                }
            }
            SettingsGroup("同步内容") {
                ForEach(SyncCategory.allCases, id: \.self) { category in
                    SettingsRow(category.title, detail: detail(category)) {
                        if let count = sync.counts[category] { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                        Toggle(category.title, isOn: Binding(get: { sync.categories.contains(category) }, set: { sync.setCategory(category, enabled: $0) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            if !sync.devices.isEmpty {
                SettingsGroup("已同步的设备") {
                    ForEach(sync.devices, id: \.device) { device in
                        SettingsRow(device.deviceName + (device.device == sync.devices.first?.device ? "（本机）" : ""), detail: "最近更新：" + device.updated.formatted(date: .abbreviated, time: .shortened)) { EmptyView() }
                    }
                }
            }
            SettingsGroup("保留在本机") {
                SettingsRow("密码、API 密钥与权限", detail: "系统权限、目录授权、本机索引、脚本和截图文件不会上传。Apple 备忘录由其自身的 iCloud 设置管理。") { EmptyView() }
                SettingsRow("数据与冲突", detail: "开启后合并现有资料；手动删除会同步到其他设备，剪贴板自动过期只清理本机。关闭开关保留本机与云端资料。发生覆盖时会保留本机旧内容及条目标识。") { Button("查看恢复副本") { sync.revealRecovery() } }
                SettingsRow("iCloud Drive 隐私", detail: "同步文件包含你选择的内容；有权访问共享文件夹的人可以读取。iCloud 的传输与账户保护由 Apple 提供。") { EmptyView() }
            }
        }.settingsAnchor(SettingsItem.cloudSync)
    }
    private func detail(_ category: SyncCategory) -> String? {
        if category == .clipboard { return "独立选择是否同步文字、富文本、图片及文件引用；不会上传引用的原文件。" }
        if category == .chats { return "包含当前版本保存的对话正文、标题与置顶状态，不包含模型提供方的密钥。" }
        if category == .extensions { return "仅同步已支持的显示与操作偏好，不同步采集开关或系统授权。" }
        return nil
    }
}
