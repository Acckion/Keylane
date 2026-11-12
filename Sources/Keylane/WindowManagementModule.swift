import AppKit
import KeylaneCore
import Combine

enum WindowManagementModule {
    static func make(model: Model) -> LauncherModule {
        let permission = PermissionFeature("windowManagement.enabled", authorization: .accessibility, observeImmediately: false)
        var actions: [UUID: NavigationScanRequest] = [:]
        let commands: [(WindowPlacement, String, String, String, String)] = [
            (.left, "window-left-half", "左半屏", "Left Half", "rectangle.lefthalf.filled"),
            (.right, "window-right-half", "右半屏", "Right Half", "rectangle.righthalf.filled"),
            (.top, "window-top-half", "上半屏", "Top Half", "rectangle.tophalf.filled"),
            (.bottom, "window-bottom-half", "下半屏", "Bottom Half", "rectangle.bottomhalf.filled"),
            (.maximize, "window-maximize", "最大化窗口", "Maximize Window", "arrow.up.left.and.arrow.down.right"),
            (.center, "window-center", "居中窗口", "Center Window", "rectangle.center.inset.filled"),
            (.nextDisplay, "window-next-display", "移到下一台显示器", "Move Window to Next Display", "display.2"),
            (.restore, "window-restore", "恢复窗口位置和大小", "Restore Window Position and Size", "arrow.uturn.backward")
        ]
        return .init(id: .init(rawValue: "keylane.window-management"), title: "窗口管理", symbol: "macwindow", commands: commands.map { command in
            .init(declaration: .init(id: .init(rawValue: command.1),
                                     title: NavigationText.label(command.2, command.3),
                                     detail: NavigationText.label("窗口管理", "Window Management"), symbol: command.4,
                                     keywords: [command.2, command.3, "窗口管理", "Window Management"], destination: .action, settingsPage: "keylane.window-management"),
                  permission: permission, execute: { [weak model] origin in
                guard let model, let delegate = NSApp.delegate as? Delegate else { return }
                if origin == .shortcut { delegate.rememberPreviousApplication() }
                let id = UUID()
                let request = NavigationScanRequest()
                actions[id] = request
                SystemNavigation.shared.placeWindow(command.0, in: delegate.previousApplication, request: request) { [weak model, weak delegate] message in
                    guard actions.removeValue(forKey: id) != nil else { return }
                    if let message {
                        model?.error = message
                        delegate?.toast.show(message, style: .failure)
                    }
                    else { delegate?.hideLauncher() }
                }
            })
        }, services: [.init(start: permission.startObserving, stop: {
            permission.stopObserving()
            for request in actions.values { request.cancel() }
            actions.removeAll()
            SystemNavigation.shared.clearWindowPlacementHistory()
        })], searchUpdates: [permission.updates], permissionTitlebar: permission.titlebar("启用窗口管理"))
    }
}
