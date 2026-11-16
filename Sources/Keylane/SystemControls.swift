import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Operates the controls macOS exposes to Accessibility for the current session.
enum SystemControls {
    enum Control {
        case bluetooth, stageManager

        var title: String { self == .bluetooth ? "蓝牙" : "台前调度" }

        func matches(_ element: AXUIElement) -> Bool {
            let names = self == .bluetooth
                ? ["bluetooth", "controlcenter-bluetooth", "com.apple.controlcenter.bluetooth", "蓝牙", "藍牙"]
                : ["stage manager", "controlcenter-stagemanager", "controlcenter-stage-manager",
                   "com.apple.controlcenter.stagemanager", "台前调度", "幕前調度"]
            let labels = elementNames(element)
            return names.contains { name in
                labels.contains { label in
                    label == name || [",", "，", ":", "："].contains { label.hasPrefix(name + $0) }
                }
            }
        }
    }

    private static var task: Task<Void, Never>?

    static func cancel() {
        task?.cancel()
        task = nil
    }

    static func toggle(_ control: Control) {
        withPanel("控制中心", bundleID: "com.apple.controlcenter", shortcut: kVK_ANSI_C) { center in
            guard !Task.isCancelled else { return }
            let candidates = descendants(of: windows(center)).filter(control.matches)
            if toggleControl(in: candidates) { return }
            // Some Control Center layouts put the switch inside its own panel.
            if let details = candidates.first(where: { ["AXButton", "AXMenuButton"].contains(role($0)) }), press(details) {
                await pause()
                guard !Task.isCancelled else { return }
                if toggleControl(in: descendants(of: windows(center)).filter(control.matches)) { return }
            }
            SystemActions.feedback("找不到可用的\(control.title)开关。请检查控制中心的控件。", style: .failure)
        }
    }

    static func dismissNotifications() {
        withPanel("通知中心", bundleID: "com.apple.notificationcenterui", shortcut: kVK_ANSI_N) { notifications in
            for count in 0..<50 {
                guard !Task.isCancelled else { return }
                guard let target = descendants(of: windows(notifications)).lazy.compactMap(dismissAction).first else {
                    let cleared = count > 0
                    SystemActions.feedback(cleared ? "已清除通知。" : "没有可清除的通知。", style: cleared ? .success : .neutral)
                    return
                }
                guard AXUIElementPerformAction(target.0, target.1 as CFString) == .success else {
                    SystemActions.feedback("部分通知无法清除。", style: .failure)
                    return
                }
                await pause()
            }
            if !Task.isCancelled { SystemActions.feedback("已尝试清除 50 组通知。请检查通知中心是否还有剩余。") }
        }
    }

    private static let clearNames: Set<String> = [
        "clear", "clear all", "全部清除", "清除全部", "清除", "全部清除通知", "清除所有",
        "alle löschen", "tout effacer", "borrar todo", "すべてクリア", "모두 지우기"
    ]

    private static func dismissAction(_ item: AXUIElement) -> (AXUIElement, String)? {
        let role = role(item)
        guard ["AXGroup", "AXButton", "AXListItem", "AXCell"].contains(role) else { return nil }
        let dismissNames = clearNames.union(["axdismiss", "axclose", "close", "dismiss", "关闭", "關閉"])
        if let action = actions(item).first(where: { dismissNames.contains(actionName($0)) }) {
            return (item, action)
        }
        // Match only the system's named clear buttons. A notification's title may contain arbitrary text.
        if role == "AXButton", elementNames(item).contains(where: clearNames.contains) {
            return (item, kAXPressAction)
        }
        return nil
    }

    private static func actionName(_ action: String) -> String {
        let lowered = action.lowercased()
        guard lowered.hasPrefix("name:") else { return lowered }
        return lowered.dropFirst("name:".count).prefix(while: { !$0.isNewline }).trimmingCharacters(in: .whitespaces)
    }

    private static func withPanel(_ title: String, bundleID: String, shortcut: Int,
                                  action: @escaping @MainActor (AXUIElement) async -> Void) {
        cancel()
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            SystemActions.feedback("\(title)需要辅助功能权限。", style: .failure)
            return
        }
        guard let panel = application(bundleID) else {
            SystemActions.feedback("\(title)当前不可用。", style: .failure)
            return
        }
        (NSApp?.delegate as? Delegate)?.hideLauncher()
        task = Task { @MainActor in
            let wasOpen = isOpen(panel)
            if !wasOpen {
                // Fn+C and Fn+N are macOS shortcuts, including on versions that use MenuBarAgent.
                guard SystemActions.postShortcut(CGKeyCode(shortcut), flags: .maskSecondaryFn) else {
                    SystemActions.feedback("无法打开\(title)。", style: .failure)
                    return
                }
                for _ in 0..<4 {
                    await pause()
                    if Task.isCancelled || isOpen(panel) { break }
                }
            }
            guard !Task.isCancelled else { return }
            guard isOpen(panel) else {
                SystemActions.feedback("无法打开\(title)。", style: .failure)
                return
            }
            await action(panel)
            if !wasOpen, !Task.isCancelled, isOpen(panel) {
                _ = SystemActions.postShortcut(CGKeyCode(shortcut), flags: .maskSecondaryFn)
            }
        }
    }

    private static func toggleControl(in candidates: [AXUIElement]) -> Bool {
        for item in candidates {
            if let named = actions(item).first(where: {
                ["axtoggle", "toggle", "turn on", "turn off", "切换", "打开", "关闭", "開啟", "關閉"].contains(actionName($0))
            }) {
                return AXUIElementPerformAction(item, named as CFString) == .success
            }
            if ["AXCheckBox", "AXSwitch", "AXToggle"].contains(role(item))
                || attribute(item, kAXSubroleAttribute) as? String == "AXToggle" {
                return press(item)
            }
        }
        return false
    }

    private static func pause() async { try? await Task.sleep(for: .milliseconds(250)) }

    private static func application(_ id: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }

    private static func isOpen(_ app: AXUIElement) -> Bool {
        attribute(app, kAXExpandedAttribute) as? Bool ?? !windows(app).isEmpty
    }

    private static func windows(_ app: AXUIElement) -> [AXUIElement] {
        attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    private static func descendants(of roots: [AXUIElement]) -> [AXUIElement] {
        var queue = roots
        var index = 0
        var seen = Set<AXUIElement>()
        var result: [AXUIElement] = []
        while index < queue.count && index < 350 {
            let item = queue[index]
            index += 1
            guard seen.insert(item).inserted else { continue }
            result.append(item)
            queue.append(contentsOf: attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? [])
        }
        return result
    }

    private static func elementNames(_ item: AXUIElement) -> [String] {
        [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute].compactMap {
            (attribute(item, $0) as? String)?.lowercased()
        }
    }

    private static func role(_ item: AXUIElement) -> String { attribute(item, kAXRoleAttribute) as? String ?? "" }

    private static func attribute(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success ? value : nil
    }

    private static func actions(_ item: AXUIElement) -> [String] {
        var result: CFArray?
        return AXUIElementCopyActionNames(item, &result) == .success ? result as? [String] ?? [] : []
    }

    private static func press(_ item: AXUIElement) -> Bool {
        AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }
}
