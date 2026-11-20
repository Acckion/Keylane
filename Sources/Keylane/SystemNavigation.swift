import AppKit
import ApplicationServices
import Carbon
import KeylaneCore

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
    var shortcut: Shortcut? = nil
    var minimized = false
    var enabled = true
    let identity = UUID()
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

struct WindowPlacementOptions {
    var windowGap: CGFloat = 0
    var screenGap: CGFloat = 0
    var respectStageManager = false
    var halfFractions: [CGFloat] = [0.5]
    var cycleDisplays = false
}

/// AX calls can block on another process. All queries, action calls, and history
/// updates run on this queue; SwiftUI only receives finished snapshots.
final class SystemNavigation {
    static let shared = SystemNavigation()
    private let queue = DispatchQueue(label: "org.keylane.navigation", qos: .userInitiated)
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var recent: [(pid: pid_t, window: AXUIElement)] = []

    private var previousFrames: [(window: AXUIElement, frame: CGRect)] = []

    private init() {}

    struct WindowTarget {
        let window: AXUIElement
        let frame: CGRect
        let display: CGRect
    }

    enum WindowOperation {
        case place(WindowPlacement), half(WindowEdge), fullscreen, minimize, minimizeDisplay
    }

    static func displayFrames(respectingStageManager: Bool = false) -> [CGRect] {
        screenFrames(respectingStageManager: respectingStageManager).map(\.area)
    }

    private static func screenFrames(respectingStageManager: Bool) -> [(bounds: CGRect, area: CGRect)] {
        let screens = NSScreen.screens
        let top = screens.first?.frame.maxY ?? 0
        func windowCoordinates(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
        }
        let manager = respectingStageManager ? UserDefaults(suiteName: "com.apple.WindowManager") : nil
        let reserveStrip = manager?.bool(forKey: "GloballyEnabled") == true
            && !(manager?.bool(forKey: "AutoHide") ?? false)
        let stripOnRight = reserveStrip && UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") == "left"
        return screens.map { screen in
            var frame = screen.visibleFrame
            if reserveStrip, frame.width > 240 {
                if !stripOnRight { frame.origin.x += 100 }
                frame.size.width -= 100
            }
            return (windowCoordinates(screen.frame), windowCoordinates(frame))
        }
    }

    static func displayArea(at point: CGPoint?, in screens: [(bounds: CGRect, area: CGRect)]) -> CGRect? {
        point.flatMap { point in screens.first { $0.bounds.contains(point) }?.area } ?? screens.first?.area
    }

    func placeWindow(_ placement: WindowPlacement, in app: NSRunningApplication?, request: NavigationScanRequest = .init(),
                     completion: @escaping (String?) -> Void) {
        manageWindow(.place(placement), in: app, request: request, completion: completion)
    }

    func manageWindow(_ operation: WindowOperation, in app: NSRunningApplication?, options: WindowPlacementOptions = .init(),
                      expected: WindowTarget? = nil, displayAt point: CGPoint? = nil,
                      request: NavigationScanRequest = .init(), completion: @escaping (String?) -> Void) {
        guard AXIsProcessTrusted() else {
            completion(NavigationText.label("请在系统设置中允许 Keylane 使用辅助功能。", "Allow Keylane in Accessibility settings."))
            return
        }
        let screens = Self.screenFrames(respectingStageManager: options.respectStageManager)
        let displays = screens.map(\.area)
        let minimizeDisplay: CGRect?
        let runningApps: [NSRunningApplication]
        if case .minimizeDisplay = operation {
            minimizeDisplay = Self.displayArea(at: point, in: screens)
            runningApps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        } else {
            minimizeDisplay = nil
            runningApps = []
        }
        queue.async {
            guard !request.isCancelled else { return }
            let message: String?
            if case .minimizeDisplay = operation {
                message = self.minimizeWindows(on: minimizeDisplay, apps: runningApps, request: request)
            } else if let app, !app.isTerminated,
                      let target = self.focusedWindow(pid: app.processIdentifier, displays: displays) {
                if let expected, !CFEqual(expected.window, target.window) {
                    message = NavigationText.label("焦点窗口已变化。", "The focused window changed.")
                } else {
                    message = self.apply(operation, to: target, displays: displays, options: options)
                }
            } else {
                message = NavigationText.label("目标应用没有可调整的聚焦窗口。", "The target app has no focused window to arrange.")
            }
            DispatchQueue.main.async { if !request.isCancelled { completion(message) } }
        }
    }

    func windowTarget(in app: NSRunningApplication?, options: WindowPlacementOptions,
                      request: NavigationScanRequest, completion: @escaping (WindowTarget?) -> Void) {
        let displays = Self.displayFrames(respectingStageManager: options.respectStageManager)
        queue.async {
            guard !request.isCancelled else { return }
            let target = app.flatMap { AXIsProcessTrusted() ? self.focusedWindow(pid: $0.processIdentifier, displays: displays) : nil }
            DispatchQueue.main.async { if !request.isCancelled { completion(target) } }
        }
    }

    func clearWindowPlacementHistory() { queue.async { self.previousFrames.removeAll() } }

    private func focusedWindow(pid: pid_t, displays: [CGRect]) -> WindowTarget? {
        guard let window = element(applicationElement(pid), kAXFocusedWindowAttribute),
              let frame = frame(of: window),
              let index = WindowPlacement.displayIndex(for: frame, displays: displays) else { return nil }
        return WindowTarget(window: window, frame: frame, display: displays[index])
    }

    private func apply(_ operation: WindowOperation, to target: WindowTarget,
                       displays: [CGRect], options: WindowPlacementOptions) -> String? {
        let window = target.window
        let fullscreen = value(window, "AXFullScreen") as? Bool == true
        switch operation {
        case .fullscreen:
            return setFlag(!fullscreen, key: "AXFullScreen", on: window) ? nil :
                NavigationText.label("窗口无法切换全屏。", "Could not toggle full screen.")
        case .minimize:
            return setFlag(true, key: kAXMinimizedAttribute, on: window) ? nil :
                NavigationText.label("窗口无法最小化。", "Could not minimize the window.")
        default:
            break
        }
        guard !fullscreen else {
            return NavigationText.label("请先退出窗口的全屏模式。", "Exit full screen before arranging this window.")
        }
        let current = target.frame
        let saved = previousFrames.first { CFEqual($0.window, window) }?.frame
        let placement: WindowPlacement
        switch operation {
        case .place(let command):
            placement = command
        case .half(let edge):
            let fractions = options.halfFractions
            let regions: [WindowPlacement] = fractions.map { fraction in
                switch edge {
                case .left: .region(CGRect(x: 0, y: 0, width: fraction, height: 1))
                case .right: .region(CGRect(x: 1 - fraction, y: 0, width: fraction, height: 1))
                case .top: .region(CGRect(x: 0, y: 0, width: 1, height: fraction))
                case .bottom: .region(CGRect(x: 0, y: 1 - fraction, width: 1, height: fraction))
                }
            }
            let matched = regions.firstIndex {
                guard let frame = $0.frame(for: current, displays: displays, windowGap: options.windowGap, screenGap: options.screenGap) else { return false }
                return framesMatch(current, frame)
            }
            if options.cycleDisplays, matched != nil, displays.count > 1,
               let next = WindowPlacement.nextDisplay.frame(for: current, displays: displays),
               let region = regions.first,
               let frame = region.frame(for: next, displays: displays, windowGap: options.windowGap, screenGap: options.screenGap) {
                return updateFrame(frame, from: current, window: window)
            }
            placement = regions[(matched.map { $0 + 1 } ?? 0) % regions.count]
        default:
            return nil
        }
        guard let frame = placement.frame(for: current, displays: displays, previous: saved,
                                          windowGap: options.windowGap, screenGap: options.screenGap) else {
            return placement == .restore
                ? NavigationText.label("此窗口没有可恢复的位置。", "There is no saved position for this window.")
                : NavigationText.label("没有可用的目标位置或显示器。", "No destination frame or display is available.")
        }
        return updateFrame(frame, from: current, window: window, restoring: placement == .restore)
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 2 && abs(lhs.minY - rhs.minY) <= 2 &&
        abs(lhs.width - rhs.width) <= 2 && abs(lhs.height - rhs.height) <= 2
    }

    private func updateFrame(_ target: CGRect, from current: CGRect, window: AXUIElement, restoring: Bool = false) -> String? {
        guard current != target else { return nil }
        guard writeFrame(target, to: window, resizing: current.size != target.size),
              let actual = frame(of: window), framesMatch(actual, target) else {
            let actual = frame(of: window)
            if actual != current {
                _ = writeFrame(current, to: window, resizing: actual?.size != current.size)
            }
            return NavigationText.label("窗口不支持所选布局，请检查窗口状态。", "The window could not apply this layout. Check its current state.")
        }
        previousFrames.removeAll { CFEqual($0.window, window) }
        if !restoring { previousFrames.insert((window, current), at: 0) }
        if previousFrames.count > 64 { previousFrames.removeLast() }
        return nil
    }

    private func setFlag(_ flag: Bool, key: String, on window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(window, key as CFString, flag ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    private func minimizeWindows(on display: CGRect?, apps: [NSRunningApplication], request: NavigationScanRequest) -> String? {
        guard let display else { return NavigationText.label("未找到当前显示器。", "Could not find the current display.") }
        let displays = Self.visibleWindows()
        var refused = 0
        for app in apps where !app.isTerminated && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if request.isCancelled { break }
            let candidates = displays[app.processIdentifier] ?? []
            guard candidates.contains(where: { display.contains(CGPoint(x: $0.midX, y: $0.midY)) }) else { continue }
            let windows = value(applicationElement(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
            for window in windows {
                if request.isCancelled { break }
                guard value(window, "AXFullScreen") as? Bool != true, let frame = frame(of: window),
                      display.contains(CGPoint(x: frame.midX, y: frame.midY)),
                      candidates.contains(where: { framesMatch($0, frame) }) else { continue }
                if !setFlag(true, key: kAXMinimizedAttribute, on: window) { refused += 1 }
            }
        }
        return refused == 0 ? nil : NavigationText.label("部分窗口无法最小化。", "Some windows could not be minimized.")
    }

    private static func visibleWindows() -> [pid_t: [CGRect]] {
        let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var windows: [pid_t: [CGRect]] = [:]
        for info in descriptions {
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            windows[pid, default: []].append(rect)
        }
        return windows
    }

    func snapshotLayout(options: WindowPlacementOptions, request: NavigationScanRequest,
                        completion: @escaping ([WindowLayoutEntry]) -> Void) {
        let displays = Self.displayFrames(respectingStageManager: options.respectStageManager)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        queue.async {
            let visible = Self.visibleWindows()
            var entries: [WindowLayoutEntry] = []
            for app in apps {
                guard !request.isCancelled else { return }
                guard let bundleID = app.bundleIdentifier, let matches = visible[app.processIdentifier] else { continue }
                let windows = self.value(self.applicationElement(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
                for window in windows {
                    guard !request.isCancelled else { return }
                    guard self.value(window, "AXFullScreen") as? Bool != true,
                          let frame = self.frame(of: window), matches.contains(where: { self.framesMatch($0, frame) }),
                          let index = WindowPlacement.displayIndex(for: frame, displays: displays),
                          entries.filter({ $0.display == index }).count < 8 else { continue }
                    let display = displays[index]
                    var entry = WindowLayoutEntry(bundleID: bundleID)
                    entry.display = index
                    entry.windowTitle = self.value(window, kAXTitleAttribute) as? String ?? ""
                    entry.geometry.width = .init(frame.width, percentage: false)
                    entry.geometry.height = .init(frame.height, percentage: false)
                    entry.geometry.x = .init(frame.minX - display.minX, percentage: false)
                    entry.geometry.y = .init(frame.minY - display.minY, percentage: false)
                    entries.append(entry)
                }
            }
            DispatchQueue.main.async { if !request.isCancelled { completion(entries) } }
        }
    }

    func applyLayout(_ entries: [(entry: WindowLayoutEntry, pid: pid_t)], layout: CustomWindowAction,
                     otherWindows: CustomWindowAction.OtherWindows,
                     options: WindowPlacementOptions, request: NavigationScanRequest, completion: @escaping (Int) -> Void) {
        let displays = Self.displayFrames(respectingStageManager: options.respectStageManager)
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        queue.async {
            var used: [AXUIElement] = []
            var front: (pid: pid_t, window: AXUIElement)?
            var failed = 0
            let visible = Self.visibleWindows()
            // Assign explicit titles before a wildcard can claim the same AX window.
            let orderedEntries = entries.filter { !$0.entry.windowTitle.isEmpty }
                + entries.filter { $0.entry.windowTitle.isEmpty }
            for (entry, pid) in orderedEntries {
                guard !request.isCancelled else { return }
                guard displays.indices.contains(entry.display),
                      let destination = layout.displayFrame(for: entry, in: displays[entry.display], windowGap: options.windowGap,
                                                            screenGap: options.screenGap) else {
                    failed += 1
                    continue
                }
                let deadline = ProcessInfo.processInfo.systemUptime + 1.5
                let application = self.applicationElement(pid)
                var candidate: (AXUIElement, CGRect)?
                repeat {
                    let windows = self.value(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
                    candidate = windows.lazy.compactMap { window -> (AXUIElement, CGRect)? in
                        guard !used.contains(where: { CFEqual($0, window) }),
                              self.value(window, "AXFullScreen") as? Bool != true,
                              (entry.windowTitle.isEmpty || self.value(window, kAXTitleAttribute) as? String == entry.windowTitle),
                              let frame = self.frame(of: window) else { return nil }
                        return (window, frame)
                    }.first
                    if candidate == nil { Thread.sleep(forTimeInterval: 0.05) }
                } while candidate == nil && !request.isCancelled && ProcessInfo.processInfo.systemUptime < deadline
                guard !request.isCancelled else { return }
                guard let (window, frame) = candidate else { failed += 1; continue }
                used.append(window)
                if self.value(window, kAXMinimizedAttribute) as? Bool == true {
                    _ = self.setFlag(false, key: kAXMinimizedAttribute, on: window)
                }
                if self.updateFrame(destination, from: frame, window: window) != nil { failed += 1 }
                else if layout.frontWindowID == entry.id { front = (pid, window) }
            }
            if otherWindows != .keep, failed == 0, !used.isEmpty {
                for app in apps {
                    guard !request.isCancelled else { return }
                    guard let matches = visible[app.processIdentifier] else { continue }
                    let windows = self.value(self.applicationElement(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
                    for window in windows {
                        guard !request.isCancelled else { return }
                        guard !used.contains(where: { CFEqual($0, window) }),
                              self.value(window, "AXFullScreen") as? Bool != true,
                              let frame = self.frame(of: window), matches.contains(where: { self.framesMatch($0, frame) }) else { continue }
                        if otherWindows == .minimize {
                            if !self.setFlag(true, key: kAXMinimizedAttribute, on: window) { failed += 1 }
                        } else if let close = self.element(window, kAXCloseButtonAttribute) {
                            if AXUIElementPerformAction(close, kAXPressAction as CFString) != .success { failed += 1 }
                        }
                    }
                }
            }
            DispatchQueue.main.async { [failures = failed, front] in
                guard !request.isCancelled else { return }
                guard let front else { completion(failures); return }
                guard let app = NSRunningApplication(processIdentifier: front.pid) else { completion(failures + 1); return }
                let window = NavigationItem(id: 0, title: "", detail: "", application: app, element: front.window)
                self.perform(window, mode: .windows, request: request) { error in
                    completion(failures + (error == nil ? 0 : 1))
                }
            }
        }
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        let attributes = values(window, [kAXPositionAttribute, kAXSizeAttribute])
        return windowFrame(position: attributes[0], size: attributes[1])
    }

    private func writeFrame(_ frame: CGRect, to window: AXUIElement, resizing: Bool) -> Bool {
        var origin = frame.origin
        var size = frame.size
        var movable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &movable) == .success,
              movable.boolValue, let position = AXValueCreate(.cgPoint, &origin) else { return false }
        if resizing {
            var resizable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success,
                  resizable.boolValue, let dimensions = AXValueCreate(.cgSize, &size) else { return false }
            // AppKit can clamp a resize to the space available at the old position.
            // Set the origin first, then resize and reapply the origin if the app adjusted it.
            guard AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success,
                  AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions) == .success else { return false }
        }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success
    }

    func observeFocus(of app: NSRunningApplication) {
        guard AXIsProcessTrusted(), app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = app.processIdentifier
        queue.async {
            if self.observedPID != pid {
                self.removeFocusObserver()
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

    func stopObservingFocus() {
        queue.async {
            self.removeFocusObserver()
            self.recent.removeAll()
        }
    }

    private func removeFocusObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = nil
    }

    private func recordFocus(_ application: AXUIElement, pid: pid_t) {
        guard pid > 0, let window = element(application, kAXFocusedWindowAttribute) else { return }
        recent.removeAll { $0.pid == pid && CFEqual($0.window, window) }
        recent.insert((pid, window), at: 0)
        if recent.count > 128 { recent.removeLast() }
    }

    @discardableResult
    func scan(_ mode: NavigationMode, target: NSRunningApplication?,
              request: NavigationScanRequest = .init(), windowApplications: [NSRunningApplication]? = nil,
              completion: @escaping (NavigationScan) -> Void) -> NavigationScanRequest {
        let apps = mode == .windows ? (windowApplications ?? NSWorkspace.shared.runningApplications).filter {
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

    func perform(_ item: NavigationItem, mode: NavigationMode, request: NavigationScanRequest = .init(), completion: @escaping (String?) -> Void) {
        guard !request.isCancelled else { return }
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
            guard !request.isCancelled else { return }
            if !requestedActivation, !app.isActive, !app.isTerminated {
                let application = self.applicationElement(app.processIdentifier)
                AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            // Give the target a chance to restore its menu validation and active Space.
            let deadline = DispatchTime.now().uptimeNanoseconds + 1_200_000_000
            while !request.isCancelled, !app.isActive, !app.isTerminated, DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            guard !request.isCancelled else { return }
            let message: String?
            if app.isTerminated || !app.isActive {
                message = NavigationText.label("无法切换到目标应用。", "Could not activate the target app.")
            } else {
                switch mode {
                case .windows:
                    if self.value(item.element, kAXMinimizedAttribute) as? Bool == true {
                        AXUIElementSetAttributeValue(item.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    }
                    guard !request.isCancelled else { return }
                    let result = AXUIElementPerformAction(item.element, kAXRaiseAction as CFString)
                    if result == .success {
                        let application = self.applicationElement(app.processIdentifier)
                        let focusDeadline = ProcessInfo.processInfo.systemUptime + 0.3
                        var focused = self.element(application, kAXFocusedWindowAttribute)
                        while let current = focused, !CFEqual(current, item.element),
                              !request.isCancelled, app.isActive, ProcessInfo.processInfo.systemUptime < focusDeadline {
                            Thread.sleep(forTimeInterval: 0.03)
                            focused = self.element(application, kAXFocusedWindowAttribute)
                        }
                        if !request.isCancelled { self.recordFocus(application, pid: app.processIdentifier) }
                        if let focused, !CFEqual(focused, item.element) {
                            message = NavigationText.label("系统未将焦点切换到所选窗口。", "macOS did not focus the selected window.")
                        } else {
                            message = nil
                        }
                    } else {
                        message = NavigationText.label("无法切换到该窗口，窗口可能已关闭。", "Could not switch to this window. It may have closed.")
                    }
                case .menus:
                    let current = self.values(item.element, [kAXRoleAttribute, kAXTitleAttribute, kAXEnabledAttribute])
                    guard !request.isCancelled else { return }
                    if current[0] as? String != kAXMenuItemRole || current[1] as? String != item.title {
                        message = NavigationText.label("该菜单项已变化，请刷新结果。", "This menu item changed. Refresh the results.")
                    } else if current[2] as? Bool != true {
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
            DispatchQueue.main.async { if !request.isCancelled { completion(message) } }
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

    enum PasteMenuResult {
        case performed, useKeyboard, cancelled, failed
    }

    func pasteFile(in app: NSRunningApplication, isCurrent: @escaping () -> Bool,
                   completion: @escaping (PasteMenuResult) -> Void) {
        queue.async {
            let activationDeadline = ProcessInfo.processInfo.systemUptime + 1
            while !app.isActive, !app.isTerminated, ProcessInfo.processInfo.systemUptime < activationDeadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            let result: PasteMenuResult
            if !app.isActive {
                result = .cancelled
            } else if let item = self.menuItems(app, request: .init(), matchingShortcut: ["⌘", "V"]).items.first {
                let readinessDeadline = ProcessInfo.processInfo.systemUptime + 0.35
                var enabled = self.value(item.element, kAXEnabledAttribute) as? Bool == true
                while !enabled, app.isActive, ProcessInfo.processInfo.systemUptime < readinessDeadline {
                    Thread.sleep(forTimeInterval: 0.025)
                    enabled = self.value(item.element, kAXEnabledAttribute) as? Bool == true
                }
                if !app.isActive || !DispatchQueue.main.sync(execute: isCurrent) {
                    result = .cancelled
                } else if !enabled {
                    result = .useKeyboard
                } else {
                    let press = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
                    switch press {
                    case .success: result = .performed
                    case .actionUnsupported, .notImplemented: result = .useKeyboard
                    default: result = .failed
                    }
                }
            } else {
                result = .useKeyboard
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func menuItems(_ app: NSRunningApplication, request: NavigationScanRequest,
                           matchingShortcut: [String]? = nil) -> NavigationScan {
        let application = applicationElement(app.processIdentifier)
        let (error, raw) = read(application, kAXMenuBarAttribute)
        guard let bar = asElement(raw) else { return NavigationScan(incomplete: error == .cannotComplete) }
        var scan = NavigationScan()
        let physicalKeys = NavigationShortcut.physicalKeys()
        let deadline = ProcessInfo.processInfo.systemUptime + (matchingShortcut == nil ? 5 : 0.5)
        var visited = Set<AXUIElement>()

        func visit(_ node: AXUIElement, path: [String], depth: Int) {
            guard !request.isCancelled, matchingShortcut == nil || scan.items.isEmpty else { return }
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
                guard matchingShortcut == nil || matchingShortcut == keys else { return }
                scan.items.append(NavigationItem(id: scan.items.count, title: title,
                                                 detail: path.joined(separator: " › "), application: app,
                                                 element: node, keys: keys, shortcut: NavigationShortcut.chord(character: attrs[4] as? String, virtualKey: attrs[5] as? Int, glyph: attrs[6] as? Int, modifiers: attrs[7] as? Int, physicalKeys: physicalKeys), enabled: attrs[3] as? Bool ?? true))
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

    /// Some AX menu providers omit CmdVirtualKey. Resolve their character using the
    /// current ASCII-capable layout rather than assuming US key positions.
    static func physicalKeys() -> [String: UInt32] {
        let readLayout: () -> Data? = {
            guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
            return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        }
        let data = Thread.isMainThread ? readLayout() : DispatchQueue.main.sync(execute: readLayout)
        guard let data else { return [:] }
        return data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
            var result: [String: UInt32] = [:]
            for modifiers in [UInt32(0), UInt32(shiftKey >> 8), UInt32(optionKey >> 8), UInt32((shiftKey | optionKey) >> 8)] {
                for code in UInt16(0)..<128 {
                    var dead: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 8)
                    let error = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), modifiers,
                                               UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                               &dead, characters.count, &length, &characters)
                    guard error == noErr, length > 0 else { continue }
                    let text = String(utf16CodeUnits: characters, count: length).uppercased()
                    // Modifier-specific entries disambiguate symbols produced by Shift/Option.
                    let key = "\(modifiers):\(text)"
                    if result[key] == nil { result[key] = UInt32(code) }
                }
            }
            return result
        }
    }

    static func chord(character: String?, virtualKey: Int?, glyph: Int?, modifiers: Int?,
                      physicalKeys: [String: UInt32]) -> Shortcut? {
        if let shortcut = ShortcutMapConversion.menu(virtualKey: virtualKey, modifiers: modifiers) { return shortcut }
        let flags = modifiers ?? 0
        guard flags & ~15 == 0 else { return nil }
        let label = keys(character: character, virtualKey: nil, glyph: glyph, modifiers: modifiers).last
        let layoutModifiers = UInt32((flags & 1 != 0 ? shiftKey : 0) | (flags & 2 != 0 ? optionKey : 0)) >> 8
        let code = label.flatMap { label in
            special.first { $0.value == label }.map { UInt32($0.key) }
                ?? physicalKeys["\(layoutModifiers):\(label)"] ?? physicalKeys["0:\(label)"]
        }
        return ShortcutMapConversion.menu(virtualKey: code.map(Int.init), modifiers: modifiers)
    }

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
