import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum SystemActionsModule {
    static let id = ModuleID(rawValue: "keylane.system")
    static let volumePage = PageID(rawValue: "SetSystemVolume")

    static func migratePreferences(model: Model, commands: [LauncherModule.Command]) {
        let defaults = UserDefaults.standard
        let key = LauncherModuleRegistry.disabledModulesPreferenceKey
        var disabled = Set(defaults.stringArray(forKey: key) ?? [])
        let actionsDisabled = disabled.remove("keylane.system-tools") != nil
        let settingsDisabled = disabled.remove("keylane.system-settings") != nil
        guard actionsDisabled || settingsDisabled else { return }

        if actionsDisabled && settingsDisabled {
            disabled.insert(id.rawValue)
        } else {
            let commandIDs = actionsDisabled
                ? commands.map { $0.declaration.id.rawValue }
                : SystemSettingsCatalog.pages.map(\.id)
            model.disabledCommands.formUnion(commandIDs)
        }
        defaults.set(disabled.sorted(), forKey: key)
    }

    static func make(model: Model, languages: [String] = Locale.preferredLanguages) -> LauncherModule {
        let chinese = SystemSettingsCatalog.prefersChinese(languages)
        let volume = SystemVolumeDraft()
        let keyboard = model.systemKeyboardPermission
        let controls = model.systemControlsPermission
        let events = model.systemEventsPermission

        func command(_ id: String, _ zh: String, _ en: String, _ icon: String,
                     aliases: [String] = [], permission: PermissionFeature? = nil,
                     destination: LauncherCommandDeclaration.Destination = .action,
                     perform: @escaping () -> Void) -> LauncherModule.Command {
            .init(declaration: .init(id: .init(rawValue: id), title: chinese ? zh : en,
                                     detail: chinese ? "系统" : "System", symbol: icon,
                                     keywords: [zh, en] + aliases, destination: destination,
                                     settingsPage: nil),
                  permission: permission, execute: { _ in perform() })
        }

        let commands = [
            command("color", "取色", "Pick Color", "eyedropper") { SystemTools.shared.colorPicker() },
            command("speak", "朗读", "Read Clipboard", "speaker.wave.2",
                    aliases: ["朗读剪贴板"], permission: model.clipboardSpeech) { SystemTools.shared.readClipboard() },
            command("stop-speaking", "停止朗读", "Stop Reading", "stop.circle") { SystemTools.shared.stopReading() },
            command("finder", "个人文件夹", "Open Home", "folder", aliases: ["打开个人文件夹", "Finder"]) {
                NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
            },
            command("dismiss-notifications", "清除通知", "Dismiss Notifications", "bell.slash", permission: controls) {
                SystemControls.dismissNotifications()
            },
            command("eject-all-disks", "推出所有外部磁盘", "Eject All Disks", "eject", aliases: ["推出磁盘", "弹出磁盘"]) {
                SystemActions.ejectAllDisks()
            },
            command("empty-trash", "清空废纸篓", "Empty Trash", "trash.slash", permission: model.finderAutomation) {
                SystemActions.runAutomation(.emptyTrash)
            },
            command("hide-other-applications", "隐藏其他应用", "Hide All Apps Except Frontmost", "eye.slash",
                    aliases: ["Hide Other Apps"]) { SystemActions.hideOtherApplications() },
            command("lock-screen", "锁定屏幕", "Lock Screen", "lock.fill",
                    aliases: ["锁屏"], permission: model.lockScreenPermission) { SystemActions.lockScreen() },
            command("log-out", "注销", "Log Out", "rectangle.portrait.and.arrow.right", permission: events) {
                SystemActions.runAutomation(.logOut)
            },
            command("next-track", "下一曲", "Next Track", "forward.end.fill", permission: keyboard) {
                SystemActions.postMediaKey(.next)
            },
            command("open-trash", "打开废纸篓", "Open Trash", "trash") { SystemActions.openTrash() },
            command("play-pause", "播放或暂停", "Play / Pause", "playpause.fill",
                    aliases: ["播放", "暂停", "Play Pause"], permission: keyboard) { SystemActions.postMediaKey(.playPause) },
            command("previous-track", "上一曲", "Previous Track", "backward.end.fill", permission: keyboard) {
                SystemActions.postMediaKey(.previous)
            },
            command("quit-all-applications", "退出所有应用", "Quit All Apps", "rectangle.portrait.and.arrow.right") {
                SystemActions.quitApplications(keepingFrontmost: false)
            },
            command("quit-other-applications", "退出其他应用", "Quit All Apps Except Frontmost", "rectangle.portrait.and.arrow.right",
                    aliases: ["Quit Other Apps"]) { SystemActions.quitApplications(keepingFrontmost: true) },
            command("restart-mac", "重启 Mac", "Restart", "restart", aliases: ["重新启动", "Restart Mac"], permission: events) {
                SystemActions.runAutomation(.restart)
            },
            command("restart-frontmost-application", "重启前台应用", "Restart Frontmost App", "arrow.clockwise") { [weak model] in
                guard let model else { return }
                model.applicationResultActions.restartFrontmost(model: model)
            },
            command("set-output-volume", "设置音量", "Set Volume", "speaker.wave.2", destination: .page(volumePage)) {},
            command("show-desktop", "显示桌面", "Show Desktop", "macwindow", permission: keyboard) {
                SystemActions.showDesktop()
            },
            command("show-screen-saver", "启动屏幕保护程序", "Show Screen Saver", "sparkles.tv",
                    aliases: ["屏保", "Screen Saver"]) { SystemActions.showScreenSaver() },
            command("shut-down", "关机", "Shut Down", "power", permission: events) {
                SystemActions.runAutomation(.shutDown)
            },
            command("sleep-mac", "让 Mac 睡眠", "Sleep", "moon.zzz", aliases: ["Sleep Mac", "系统睡眠", "休眠"]) {
                SystemActions.requestPowerAction(.sleep)
            },
            command("sleep-displays", "让显示器睡眠", "Sleep Displays", "display", aliases: ["显示器睡眠", "关闭屏幕"]) {
                SystemActions.requestPowerAction(.sleepDisplays)
            },
            command("toggle-bluetooth", "切换蓝牙", "Toggle Bluetooth", "wave.3.right", permission: controls) {
                SystemControls.toggle(.bluetooth)
            },
            command("toggle-hidden-files", "切换隐藏文件显示", "Toggle Hidden Files", "eye.slash",
                    aliases: ["显示隐藏文件"], permission: keyboard) { SystemActions.toggleHiddenFiles() },
            command("toggle-output-mute", "切换静音", "Toggle Mute", "speaker.slash", aliases: ["Mute", "Unmute", "取消静音"]) {
                SystemActions.toggleOutputMute()
            },
            command("toggle-stage-manager", "切换台前调度", "Toggle Stage Manager", "rectangle.inset.filled.on.rectangle",
                    aliases: ["舞台管理器"], permission: controls) { SystemControls.toggle(.stageManager) },
            command("toggle-system-appearance", "切换系统外观", "Toggle System Appearance", "circle.lefthalf.filled",
                    aliases: ["深色模式", "浅色模式", "Dark Mode", "Light Mode"], permission: events) {
                SystemActions.runAutomation(.appearance)
            },
            command("volume-down", "降低音量", "Turn Volume Down", "speaker.minus",
                    aliases: ["Volume Down"], permission: keyboard) { SystemActions.postMediaKey(.volumeDown, hideLauncher: false) },
            command("volume-up", "提高音量", "Turn Volume Up", "speaker.plus",
                    aliases: ["Volume Up"], permission: keyboard) { SystemActions.postMediaKey(.volumeUp, hideLauncher: false) },
            command("unhide-applications", "显示所有隐藏应用", "Unhide All Hidden Apps", "eye",
                    aliases: ["Show Hidden Apps"]) { SystemActions.unhideApplications() }
        ] + [0, 25, 50, 75, 100].map { percent in
            command("set-output-volume-\(percent)", "设置音量为 \(percent)%", "Set Volume to \(percent)%",
                    percent == 0 ? "speaker.slash" : "speaker.wave.2") { _ = SystemActions.setOutputVolume(percent) }
        }

        let permissions = [model.lockScreenPermission, model.clipboardSpeech, keyboard, controls, events]
        let title = chinese ? "设置音量" : "Set Volume"
        let submit = { [weak model] in
            guard let model, SystemActions.setOutputVolume(volume.percent) else { return }
            model.pageID = .root
        }
        let moduleTitle = chinese ? "系统" : "System"
        let settingsPageID = id.rawValue
        let actionsItem = SettingsItem(id: "keylane.system-tools", page: settingsPageID,
                                       title: chinese ? "系统操作" : "System Actions",
                                       keywords: ([moduleTitle] + commands.flatMap { $0.declaration.keywords }).joined(separator: " "))
        let settingsItem = SettingsItem(id: "keylane.system-settings", page: settingsPageID,
                                        title: chinese ? "系统设置" : "System Settings",
                                        keywords: "System Settings 系統設定 系统设置直达")
        let search = SettingsSearchControls()
        let settings = LauncherSettingsPage(
            id: settingsPageID, title: moduleTitle, symbol: "gearshape",
            subtitle: chinese ? "管理系统操作和直达 macOS 系统设置的命令。" : "Manage system actions and shortcuts to macOS settings.",
            order: 128, items: [actionsItem, settingsItem], trailingToolbar: {
                AnyView(SettingsToolbarSearch(title: chinese ? "搜索系统命令" : "Search System Commands", selection: search))
            }, content: { [weak model] in
                guard let model else { return AnyView(EmptyView()) }
                return AnyView(SystemCommandPreferences(model: model, commands: commands, actionsItem: actionsItem,
                                                        settingsItem: settingsItem, search: search))
            }
        )
        return .init(id: id, title: moduleTitle, symbol: "gearshape", commands: commands,
                     providers: [SystemSettingsCommands.provider(model: model)], pages: [.init(
                        id: volumePage, placeholder: "", badge: (title, "speaker.wave.2"), contentPlacement: .form,
                        content: { [weak model] in
                            AnyView(SystemVolumeView(draft: volume, title: title) { model?.pageID = .root })
                        },
                        submit: submit, shortcutSubmit: submit, primaryTitle: { chinese ? "设置音量" : "Set Volume" },
                        primaryEnabled: { volume.available },
                        updates: volume.$available.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                        enter: { _ in volume.load(); return nil },
                        resume: { volume.load() }
                     )], settings: [settings], services: [.init(start: {
                         permissions.forEach { $0.startObserving() }
                     }, stop: {
                         permissions.forEach { $0.stopObserving() }
                         SystemControls.cancel()
                         SystemTools.shared.stopSystemTools()
                     })], searchUpdates: (permissions + [model.finderAutomation]).map(\.updates),
                     dynamicCommandSettings: SystemSettingsCommands.shortcutSettings(model: model))
    }
}

private final class SystemVolumeDraft: ObservableObject {
    @Published var percent = 0
    @Published var available = false

    func load() {
        let current = SystemOutputVolume.current()
        available = current != nil
        if let current { percent = current }
    }
}

private struct SystemVolumeView: View {
    @ObservedObject var draft: SystemVolumeDraft
    let title: String
    let back: () -> Void

    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            LauncherCreationField(title) {
                if draft.available {
                    HStack {
                        Slider(value: Binding(get: { Double(draft.percent) }, set: { draft.percent = Int($0) }), in: 0...100, step: 1)
                            .accessibilityLabel(title)
                        Text("\(draft.percent)%").monospacedDigit().frame(minWidth: 46, alignment: .trailing)
                    }
                } else {
                    Text("当前音频输出设备不支持系统音量调节。").foregroundStyle(.secondary)
                }
            }
        }
    }
}
