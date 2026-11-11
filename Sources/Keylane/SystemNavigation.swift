import AppKit
import ApplicationServices
import Carbon

enum NavigationMode {
    case windows, menus

    var title: String {
        switch self {
        case .windows: return NavigationText.label("切换窗口", "Switch Windows")
        case .menus: return NavigationText.label("搜索菜单项", "Search Menu Items")
        }
    }
    var symbol: String { self == .windows ? "macwindow.on.rectangle" : "menubar.rectangle" }
    var action: String {
        switch self {
        case .windows: return NavigationText.label("切换窗口", "Switch Window")
        case .menus: return NavigationText.label("执行菜单项", "Run Menu Item")
        }
    }
}

enum NavigationText {
    static func label(_ chinese: String, _ english: String) -> String {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
    }
}

struct NavigationItem: Identifiable {
    let id: Int
    let title: String
    let detail: String
    let application: NSRunningApplication
    let element: AXUIElement
    var keys: [String] = []
    var minimized = false
    var enabled = true
}

struct NavigationScan {
    var items: [NavigationItem] = []
    var incomplete = false
}

final class NavigationScanRequest {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// AX calls can block on another process. All queries, action calls, and history
/// updates run on this queue; SwiftUI only receives finished snapshots.
final class SystemNavigation {
    static let shared = SystemNavigation()
    private let queue = DispatchQueue(label: "org.keylane.navigation", qos: .userInitiated)
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var recent: [(pid: pid_t, window: AXUIElement)] = []

    private init() {}

    func observeFocus(of app: NSRunningApplication) {
        guard AXIsProcessTrusted(), app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = app.processIdentifier
        queue.async {
            if self.observedPID != pid {
                if let observer = self.observer {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
                }
                self.observer = nil
                self.observedPID = nil
                var newObserver: AXObserver?
                if AXObserverCreate(pid, { _, element, _, context in
                    guard let context else { return }
                    let service = Unmanaged<SystemNavigation>.fromOpaque(context).takeUnretainedValue()
                    service.queue.async {
                        let pid = pidFor(element)
                        guard pid > 0, service.observedPID == pid else { return }
                        service.recordFocus(service.applicationElement(pid), pid: pid)
                    }
                }, &newObserver) == .success, let newObserver,
                   AXObserverAddNotification(newObserver, self.applicationElement(pid),
                       kAXFocusedWindowChangedNotification as CFString,
                       Unmanaged.passUnretained(self).toOpaque()) == .success {
                    self.observer = newObserver
                    self.observedPID = pid
                    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(newObserver), .commonModes)
                }
            }
            self.recordFocus(self.applicationElement(pid), pid: pid)
        }
    }

    private func recordFocus(_ application: AXUIElement, pid: pid_t) {
        guard pid > 0, let window = element(application, kAXFocusedWindowAttribute) else { return }
        recent.removeAll { $0.pid == pid && CFEqual($0.window, window) }
        recent.insert((pid, window), at: 0)
        if recent.count > 128 { recent.removeLast() }
    }

    func scan(_ mode: NavigationMode, target: NSRunningApplication?,
              completion: @escaping (NavigationScan) -> Void) -> NavigationScanRequest {
        let request = NavigationScanRequest()
        let apps = mode == .windows ? NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        } : []
        queue.async {
            guard !request.isCancelled else { return }
            let results: NavigationScan
            switch mode {
            case .windows: results = self.windows(apps, request: request)
            case .menus: results = target.map { self.menuItems($0, request: request) } ?? NavigationScan()
            }
            DispatchQueue.main.async { if !request.isCancelled { completion(results) } }
        }
        return request
    }

    func perform(_ item: NavigationItem, mode: NavigationMode, completion: @escaping (String?) -> Void) {
        let app = item.application
        guard AXIsProcessTrusted(), !app.isTerminated else {
            completion(NavigationText.label("目标应用已退出或辅助功能权限已关闭。", "The app quit or Accessibility access was turned off."))
            return
        }
        if app.isHidden { app.unhide() }
        let requestedActivation: Bool
        if app.isActive {
            requestedActivation = true
        } else {
            NSApplication.shared.yieldActivation(to: app)
            requestedActivation = app.activate(from: .current)
        }
        queue.async {
            if !requestedActivation, !app.isActive, !app.isTerminated {
                let application = self.applicationElement(app.processIdentifier)
                AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            // Give the target a chance to restore its menu validation and active Space.
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_200_000_000
            while !app.isActive, !app.isTerminated, DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            let message: String?
            if app.isTerminated || !app.isActive {
                message = NavigationText.label("无法切换到目标应用。", "Could not activate the target app.")
            } else {
                switch mode {
                case .windows:
                    if self.value(item.element, kAXMinimizedAttribute) as? Bool == true {
                        AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    }
                    let result = AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
                    if result == .success {
                        let application = self.applicationElement(app.processIdentifier)
                        let focusDeadline = ProcessInfo.processInfo.systemUptime + 0.3
                        var focused = self.element(application, kAXFocusedWindowAttribute)
                        while let current = focused, !CFEqual(current, item.element),
                              app.isActive, ProcessInfo.processInfo.systemUptime < focusDeadline {
                            Thread.sleep(forTimeInterval: 0.03)
                            focused = self.element(application, kAXFocusedWindowAttribute)
                        }
                        self.recordFocus(application, pid: app.processIdentifier)
                        if let focused, !CFEqual(focused, item.element) {
                            message = NavigationText.label("系统未将焦点切换到所选窗口。", "macOS did not focus the selected window.")
                        } else {
                            message = nil
                        }
                    } else {
                        message = NavigationText.label("无法切换到该窗口，窗口可能已关闭。", "Could not switch to this window. It may have closed.")
                    }
                case .menus:
                    if self.value(item.element, kAXEnabledAttribute) as? Bool == false {
                        message = NavigationText.label("该菜单项当前不可用。", "This menu item is currently unavailable.")
                    } else if !app.isActive {
                        message = NavigationText.label("目标应用失去焦点，菜单操作已取消。", "The target app lost focus. The menu action was cancelled.")
                    } else {
                        let result = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
                        message = result == .success ? nil :
                            NavigationText.label("系统未确认菜单操作。请检查目标应用。", "macOS did not confirm the menu action. Check the target app.")
                    }
                }
            }
            DispatchQueue.main.async { completion(message) }
        }
    }

    private func windows(_ apps: [NSRunningApplication], request: NavigationScanRequest) -> NavigationScan {
        let visible = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { info -> (pid_t, CGRect)? in
                guard info[kCGWindowLayer as String] as? Int == 0,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
                return (pid, rect)
            }
        let pids = Set(apps.map(\.processIdentifier))
        recent.removeAll { !pids.contains($0.pid) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var scan = NavigationScan()
        var ranked: [(NavigationItem, Int, Int)] = []
        for app in apps {
            if request.isCancelled { break }
            if ProcessInfo.processInfo.systemUptime > deadline { scan.incomplete = true; break }
            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? ""
            let application = applicationElement(pid)
            let (error, raw) = read(application, kAXWindowsAttribute)
            if error == .cannotComplete { scan.incomplete = true }
            for window in raw as? [AXUIElement] ?? [] {
                if request.isCancelled { break }
                if ProcessInfo.processInfo.systemUptime > deadline { scan.incomplete = true; break }
                let attributes = values(window, [kAXTitleAttribute, kAXMinimizedAttribute, kAXPositionAttribute, kAXSizeAttribute])
                let title = (attributes[0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let historyIndex = recent.firstIndex { $0.pid == pid && CFEqual($0.window, window) } ?? Int.max
                let frame = windowFrame(position: attributes[2], size: attributes[3])
                let visibleIndex = visible.firstIndex { entry in
                    guard entry.0 == pid, let frame else { return false }
                    let rect = entry.1
                    return abs(rect.minX - frame.minX) < 3 && abs(rect.minY - frame.minY) < 3 &&
                           abs(rect.width - frame.width) < 3 && abs(rect.height - frame.height) < 3
                } ?? Int.max
                let item = NavigationItem(id: ranked.count, title: title.isEmpty ? NavigationText.label("无标题窗口", "Untitled Window") : title,
                                          detail: name, application: app, element: window, minimized: attributes[1] as? Bool ?? false)
                ranked.append((item, historyIndex, visibleIndex))
            }
        }
        scan.items = ranked.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return $0.0.id < $1.0.id
        }.map(\.0)
        return scan
    }

    private func menuItems(_ app: NSRunningApplication, request: NavigationScanRequest) -> NavigationScan {
        let application = applicationElement(app.processIdentifier)
        let (error, raw) = read(application, kAXMenuBarAttribute)
        guard let bar = asElement(raw) else { return NavigationScan(incomplete: error == .cannotComplete) }
        var scan = NavigationScan()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var visited = Set<AXUIElement>()

        func visit(_ node: AXUIElement, path: [String], depth: Int) {
            guard !request.isCancelled else { return }
            guard depth <= 18, ProcessInfo.processInfo.systemUptime < deadline else { scan.incomplete = true; return }
            guard visited.insert(node).inserted else { return }
            let attrs = values(node, [kAXRoleAttribute, kAXTitleAttribute, kAXChildrenAttribute, kAXEnabledAttribute,
                                      kAXMenuItemCmdCharAttribute, kAXMenuItemCmdVirtualKeyAttribute,
                                      kAXMenuItemCmdGlyphAttribute, kAXMenuItemCmdModifiersAttribute])
            let role = attrs[0] as? String
            let title = attrs[1] as? String ?? ""
            let children = attrs[2] as? [AXUIElement] ?? []
            if role == kAXMenuItemRole && children.isEmpty && !title.isEmpty {
                let keys = NavigationShortcut.keys(character: attrs[4] as? String,
                                                   virtualKey: attrs[5] as? Int, glyph: attrs[6] as? Int, modifiers: attrs[7] as? Int)
                scan.items.append(NavigationItem(id: scan.items.count, title: title,
                                                 detail: path.joined(separator: " › "), application: app,
                                                 element: node, keys: keys, enabled: attrs[3] as? Bool ?? true))
            } else {
                let childPath = title.isEmpty || role == kAXMenuRole || role == kAXMenuBarRole ? path : path + [title]
                for child in children { visit(child, path: childPath, depth: depth + 1) }
            }
        }
        visit(bar, path: [], depth: 0)
        return scan
    }

    private func applicationElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        return app
    }

    private func asElement(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func element(_ node: AXUIElement, _ key: String) -> AXUIElement? { asElement(value(node, key)) }

    private func read(_ node: AXUIElement, _ key: String) -> (AXError, CFTypeRef?) {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(node, key as CFString, &result)
        return (error, result)
    }

    private func value(_ node: AXUIElement, _ key: String) -> CFTypeRef? { read(node, key).1 }

    private func values(_ node: AXUIElement, _ keys: [String]) -> [Any] {
        var result: CFArray?
        if AXUIElementCopyMultipleAttributeValues(node, keys as CFArray, [], &result) == .success,
           let values = result as? [Any], values.count == keys.count { return values }
        return keys.map { value(node, $0) ?? NSNull() }
    }

    private func windowFrame(position: Any, size: Any) -> CGRect? {
        let p = position as CFTypeRef
        let s = size as CFTypeRef
        guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              AXValueGetValue(s as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }
}

private func pidFor(_ element: AXUIElement) -> pid_t {
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return pid
}

enum NavigationShortcut {
    private static let special: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Escape: "Esc",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Space: "Space", kVK_Home: "↖",
            kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
            kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]
    private static let glyphs: [Int: String] = [
        kMenuEnterGlyph: "⌤", kMenuReturnGlyph: "↩", kMenuSpaceGlyph: "Space",
        kMenuDeleteLeftGlyph: "⌫", kMenuDeleteRightGlyph: "⌦", kMenuEscapeGlyph: "Esc",
        kMenuLeftArrowGlyph: "←", kMenuRightArrowGlyph: "→", kMenuUpArrowGlyph: "↑",
        kMenuDownArrowGlyph: "↓", kMenuPageUpGlyph: "⇞", kMenuPageDownGlyph: "⇟",
        kMenuNorthwestArrowGlyph: "↖", kMenuSoutheastArrowGlyph: "↘"
    ]

    static func keys(character: String?, virtualKey: Int?, glyph: Int?, modifiers: Int?) -> [String] {
        let function = glyph.flatMap { (kMenuF1Glyph...kMenuF12Glyph).contains($0) ? "F\($0 - kMenuF1Glyph + 1)" : nil }
        let key = virtualKey.flatMap { special[$0] } ?? glyph.flatMap { glyphs[$0] } ?? function
            ?? character?.trimmingCharacters(in: .controlCharacters).uppercased()
        guard let key, !key.isEmpty else { return [] }
        let flags = modifiers ?? 0
        var keys: [String] = []
        if flags & 4 != 0 { keys.append("⌃") }
        if flags & 2 != 0 { keys.append("⌥") }
        if flags & 1 != 0 { keys.append("⇧") }
        if flags & 8 == 0 { keys.append("⌘") }
        return keys + [key]
    }
}
