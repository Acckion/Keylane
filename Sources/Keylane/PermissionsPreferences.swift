import AppKit
import Contacts
import SwiftUI
import KeylaneCore

struct PermissionsPreferences: View {
    let model: Model
    @StateObject private var observation: SettingsPageObservation
    @State private var hasRefreshed = false
    @State private var accessibilityAllowed = false
    @State private var inputMonitoringAllowed = false
    @State private var calendarAccess = CalendarAccess.notRequested
    @State private var contactsAccess = CNAuthorizationStatus.notDetermined

    init(model: Model) {
        self.model = model
        _observation = StateObject(wrappedValue: SettingsPageObservation([
            SettingsPageObservation.changes(model.calendar.$requesting),
            SettingsPageObservation.changes(model.calendar.$error),
            SettingsPageObservation.changes(model.contacts.$requesting),
            SettingsPageObservation.changes(model.contacts.$error)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                permissionRow("辅助功能", detail: "用于自动粘贴、窗口切换和菜单搜索。",
                              status: accessibilityAllowed ? "已允许" : "未允许",
                              actionTitle: accessibilityAllowed ? "管理…" : "申请…") {
                    if !accessibilityAllowed { model.requestKeyboardAccess() }
                    openPrivacy("Accessibility")
                }
            }.settingsAnchor(.accessibilityPermission)
            SettingsGroup {
                permissionRow("输入监控", detail: "用于 Caps Lock Hyperkey 的键盘事件监听。",
                              status: inputMonitoringAllowed ? "已允许" : "未允许",
                              actionTitle: inputMonitoringAllowed ? "管理…" : "申请…") {
                    if !inputMonitoringAllowed { _ = CGRequestListenEventAccess() }
                    openPrivacy("ListenEvent")
                }
            }.settingsAnchor(.inputMonitoringPermission)
            SettingsGroup {
                permissionRow("日历", detail: "读取日程和菜单栏摘要。",
                              status: calendarAccess.message,
                              actionTitle: calendarAccess == .notRequested || calendarAccess == .writeOnly ? "申请…" : "管理…",
                              requesting: model.calendar.requesting) {
                    if calendarAccess == .notRequested || calendarAccess == .writeOnly { model.calendar.requestAccess() }
                    else { model.calendar.openPrivacySettings() }
                }
                if !model.calendar.error.isEmpty { Text(model.calendar.error).font(.caption).foregroundStyle(.secondary) }
            }.settingsAnchor(.calendarAccess)
            SettingsGroup {
                permissionRow("联系人", detail: "按姓名、公司、电话或邮箱搜索联系人。",
                              status: contactsStatus,
                              actionTitle: contactsAccess == .notDetermined ? "申请…" : "管理…",
                              requesting: model.contacts.requesting) {
                    if contactsAccess == .notDetermined { model.contacts.requestAccess() }
                    else { openPrivacy("Contacts") }
                }
                if !model.contacts.error.isEmpty { Text(model.contacts.error).font(.caption).foregroundStyle(.secondary) }
            }.settingsAnchor(.contactsPermission)
            SettingsGroup {
                SettingsActionRow(title: "自动化", detail: "管理 Finder 和快捷指令的访问权限。",
                                  actionTitle: "打开系统设置…") { openPrivacy("Automation") }
            }.settingsAnchor(.automationPermission)
            SettingsGroup("文件与文件夹") {
                SettingsActionRow(title: "文件搜索范围", actionTitle: "选择文件夹…") { model.fileSearch.addScope() }
                Divider()
                SettingsActionRow(title: "截图搜索范围", actionTitle: "选择文件夹…") { model.screenshots.chooseFolders() }
                Divider()
                SettingsActionRow(title: "系统文件与文件夹权限", actionTitle: "打开系统设置…") { openPrivacy("FilesAndFolders") }
            }.settingsAnchor(.folderPermissions)
        }
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshStatus() }
        .onChange(of: model.calendar.requesting) { _, requesting in if !requesting { refreshStatus() } }
        .onChange(of: model.contacts.requesting) { _, requesting in if !requesting { refreshStatus() } }
    }

    private var contactsStatus: String {
        switch contactsAccess {
        case .authorized: "已允许"
        case .denied: "已拒绝"
        case .restricted: "系统限制"
        case .notDetermined: "尚未申请"
        @unknown default: "请在系统设置中查看"
        }
    }

    private func permissionRow(_ title: String, detail: String, status: String, actionTitle: String,
                               requesting: Bool = false, action: @escaping () -> Void) -> some View {
        SettingsRow(title, detail: detail) {
            HStack(spacing: 10) {
                Text(requesting ? "等待授权…" : status).font(.caption).foregroundStyle(.secondary)
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(requesting)
                    .accessibilityLabel("\(title)\(actionTitle)")
            }
        }
    }

    private func refreshStatus() {
        let wasAllowed = accessibilityAllowed
        let couldMonitor = inputMonitoringAllowed
        accessibilityAllowed = AXIsProcessTrusted()
        inputMonitoringAllowed = CGPreflightListenEventAccess()
        calendarAccess = .current
        contactsAccess = CNContactStore.authorizationStatus(for: .contacts)
        if hasRefreshed, (accessibilityAllowed && !wasAllowed) || (inputMonitoringAllowed && !couldMonitor) {
            model.configureModifiers()
        }
        hasRefreshed = true
    }

    private func openPrivacy(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
