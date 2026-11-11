import AppKit
import AVFoundation
import Contacts
import SwiftUI
import KeylaneCore

struct PermissionsPreferences: View {
    let model: Model
    let showsAdditionalPermissions: Bool
    @StateObject private var observation: ViewObservation
    @State private var hasRefreshed = false
    @State private var accessibilityAllowed = false
    @State private var inputMonitoringAllowed = false
    @State private var calendarAccess = CalendarAccess.notRequested
    @State private var cameraAccess = AVAuthorizationStatus.notDetermined
    @State private var contactsAccess = CNAuthorizationStatus.notDetermined

    init(model: Model, showsAdditionalPermissions: Bool = true) {
        self.model = model
        self.showsAdditionalPermissions = showsAdditionalPermissions
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.calendar.$requesting),
            ViewObservation.changes(model.calendar.$error),
            ViewObservation.changes(model.contacts.$requesting),
            ViewObservation.changes(model.contacts.$error),
            ViewObservation.changes(model.clipboard.$accessMessage),
            ViewObservation.changes(model.$modifierStatus),
            ViewObservation.changes(model.fileSearch.$options.map(\.roots).removeDuplicates()),
            ViewObservation.changes(model.fileSearch.$inaccessible)
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
                }.settingsAnchor(.accessibilityPermission)
                if showsAdditionalPermissions && (model.doubleTap != "off" || model.hyperkey) {
                    Divider()
                    SettingsActionRow(title: "修饰键快捷方式", detail: model.modifierStatus, actionTitle: "重新启用") {
                        model.configureModifiers()
                    }
                }
                Divider()
                permissionRow("输入监控", detail: "用于 Caps Lock Hyperkey 的键盘事件监听。",
                              status: inputMonitoringAllowed ? "已允许" : "未允许",
                              actionTitle: inputMonitoringAllowed ? "管理…" : "申请…") {
                    if !inputMonitoringAllowed { _ = CGRequestListenEventAccess() }
                    openPrivacy("ListenEvent")
                }.settingsAnchor(.inputMonitoringPermission)
                Divider()
                permissionRow("日历", detail: "读取日程和菜单栏摘要。",
                              status: calendarAccess.message,
                              actionTitle: calendarAccess == .notRequested || calendarAccess == .writeOnly ? "申请…" : "管理…",
                              requesting: model.calendar.requesting) {
                    if calendarAccess == .notRequested || calendarAccess == .writeOnly { model.calendar.requestAccess() }
                    else { model.calendar.openPrivacySettings() }
                }.settingsAnchor(.calendarAccess)
                if !model.calendar.error.isEmpty { Text(model.calendar.error).font(.caption).foregroundStyle(.secondary) }
                Divider()
                permissionRow("联系人", detail: "按姓名、公司、电话或邮箱搜索联系人。",
                              status: contactsStatus,
                              actionTitle: contactsAccess == .notDetermined ? "申请…" : "管理…",
                              requesting: model.contacts.requesting) {
                    if contactsAccess == .notDetermined { model.contacts.requestAccess() }
                    else { openPrivacy("Contacts") }
                }.settingsAnchor(.contactsPermission)
                if !model.contacts.error.isEmpty { Text(model.contacts.error).font(.caption).foregroundStyle(.secondary) }
                if showsAdditionalPermissions {
                    Divider()
                    permissionRow("相机", detail: "显示实时相机画面。", status: cameraStatus,
                                  actionTitle: "管理…") { openPrivacy("Camera") }
                        .settingsAnchor(.cameraPermission)
                    Divider()
                    SettingsActionRow(title: "自动化", detail: "管理 Finder 和快捷指令的访问权限。",
                                      actionTitle: "打开系统设置…") { openPrivacy("Automation") }
                        .settingsAnchor(.automationPermission)
                    Divider()
                    SettingsActionRow(title: "剪贴板访问",
                                      detail: model.clipboard.accessMessage.isEmpty ? "用于记录剪贴板历史。" : model.clipboard.accessMessage,
                                      actionTitle: "打开系统设置…") {
                        openPrivacy()
                    }.settingsAnchor(.pasteboardPermission)
                }
            }
            if showsAdditionalPermissions {
                SettingsGroup("文件与文件夹") {
                    SettingsActionRow(title: "文件搜索范围", actionTitle: "选择文件夹…") { model.fileSearch.addScope() }
                    Divider()
                    SettingsActionRow(title: "截图搜索范围", actionTitle: "选择文件夹…") { model.screenshots.chooseFolders() }
                    Divider()
                    SettingsActionRow(title: "系统文件与文件夹权限", actionTitle: "打开系统设置…") { openPrivacy("FilesAndFolders") }
                }.settingsAnchor(.folderPermissions)

                SettingsListCard(title: "文件搜索授权", detail: fileAccessDetail) {
                    SettingsIconButton("授权下载文件夹", symbol: "arrow.down.circle") {
                        model.fileSearch.addScope(suggested: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                    }
                } content: {
                    SettingsCompactList(items: model.fileSearch.options.roots, id: \.self) { path in
                        SettingsFolderRow(path: path, selectable: true, showsActionsOnHover: false) {
                            SettingsIconButton("重新授权 \(path)", symbol: "key", help: "重新选择文件夹以授权", compact: true) {
                                model.fileSearch.addScope(suggested: URL(fileURLWithPath: path))
                            }
                        }
                    }.padding(.bottom, 5)
                }.settingsAnchor(.fileSearchPermissions)
            }
        }
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshStatus() }
        .onChange(of: model.calendar.requesting) { _, requesting in if !requesting { refreshStatus() } }
        .onChange(of: model.contacts.requesting) { _, requesting in if !requesting { refreshStatus() } }
    }

    private var fileAccessDetail: String {
        model.fileSearch.inaccessible.isEmpty
            ? "重新选择文件夹以更新访问授权。"
            : "部分目录无法访问，请重新授权相应的文件夹。"
    }

    private var cameraStatus: String {
        switch cameraAccess {
        case .authorized: "已允许"
        case .denied: "已拒绝"
        case .restricted: "系统限制"
        case .notDetermined: "尚未申请"
        @unknown default: "请在系统设置中查看"
        }
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
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        contactsAccess = CNContactStore.authorizationStatus(for: .contacts)
        if hasRefreshed, (accessibilityAllowed && !wasAllowed) || (inputMonitoringAllowed && !couldMonitor) {
            model.configureModifiers()
        }
        hasRefreshed = true
    }

    private func openPrivacy(_ pane: String? = nil) {
        let suffix = pane.map { "?Privacy_\($0)" } ?? ""
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security" + suffix) else { return }
        NSWorkspace.shared.open(url)
    }
}
