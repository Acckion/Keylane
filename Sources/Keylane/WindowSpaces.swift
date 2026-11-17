import AppKit
import ApplicationServices
import Carbon
import Combine

enum WindowSpaces {
    private struct Desktop {
        let ids: [UInt64]
        let current: UInt64

        func adjacent(_ direction: Int) -> UInt64? {
            guard let index = ids.firstIndex(of: current), ids.indices.contains(index + direction) else { return nil }
            return ids[index + direction]
        }
    }

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static var pending = false

    private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        guard let skyLight, let symbol = dlsym(skyLight, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static func desktop(at point: CGPoint?) -> Desktop? {
        typealias Connection = @convention(c) () -> Int32
        typealias Displays = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard let connection = resolve("CGSMainConnectionID", as: Connection.self),
              let displays = resolve("CGSCopyManagedDisplaySpaces", as: Displays.self),
              let raw = displays(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        let display = point.flatMap { location -> String? in
            var id = CGDirectDisplayID()
            var count: UInt32 = 0
            guard CGGetDisplaysWithPoint(location, 1, &id, &count) == .success, count == 1,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            return CFUUIDCreateString(nil, uuid) as String
        } ?? "Main"
        let record = raw.first { ($0["Display Identifier"] as? String)?.caseInsensitiveCompare(display) == .orderedSame }
            ?? raw.first { ($0["Display Identifier"] as? String) == "Main" }
            ?? (raw.count == 1 ? raw.first : nil)
        guard let record, let current = (record["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
              let spaces = record["Spaces"] as? [[String: Any]] else { return nil }
        return Desktop(ids: spaces.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }, current: current.uint64Value)
    }

    static func switchSpace(_ direction: Int, animate: Bool, completion: @escaping (String?) -> Void) {
        let point = CGEvent(source: nil)?.location
        guard !pending else { completion("空间切换正在进行。"); return }
        guard let current = desktop(at: point) else { completion("无法读取当前空间。"); return }
        guard let destination = current.adjacent(direction) else { completion("该方向没有相邻的空间。"); return }
        let posted = animate ? sendShortcut(direction) : WindowSpaceGesture.post(direction: direction)
        guard posted else { completion("无法切换空间。请检查辅助功能和 Mission Control 快捷键设置。"); return }
        pending = true
        verify(completion: completion, until: { desktop(at: point)?.current == destination })
    }

    static func moveWindow(_ target: SystemNavigation.WindowTarget, app: NSRunningApplication, direction: Int,
                           completion: @escaping (String?) -> Void) {
        typealias Connection = @convention(c) () -> Int32
        typealias Membership = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
        typealias Move = @convention(c) (Int32, CFArray, UInt64) -> Void
        guard !pending else { completion("空间切换正在进行。"); return }
        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        guard let current = desktop(at: point), let destination = current.adjacent(direction) else {
            completion("目标显示器上没有相邻的空间。")
            return
        }
        let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let matching = visible.compactMap { item -> NSNumber? in
            guard item[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  item[kCGWindowLayer as String] as? Int == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  abs(frame.minX - target.frame.minX) < 3, abs(frame.minY - target.frame.minY) < 3,
                  abs(frame.width - target.frame.width) < 3, abs(frame.height - target.frame.height) < 3 else { return nil }
            return item[kCGWindowNumber as String] as? NSNumber
        }
        guard matching.count == 1,
              let connection = resolve("CGSMainConnectionID", as: Connection.self),
              let membership = resolve("SLSCopySpacesForWindows", as: Membership.self),
              let move = resolve("SLSMoveWindowsToManagedSpace", as: Move.self) else {
            completion("无法确认窗口所属的空间。")
            return
        }
        let id = connection()
        let windows = matching as CFArray
        let placed = {
            let spaces = membership(id, 7, windows)?.takeRetainedValue() as? [NSNumber]
            return spaces?.contains(where: { $0.uint64Value == destination }) == true
        }
        move(id, windows, destination)
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if placed() {
                pending = false
                completion(nil)
            } else {
                dragWindow(target, app: app, windowID: CGWindowID(matching[0].uint32Value),
                           direction: direction, destination: destination, displayPoint: point, placed: placed, completion: completion)
            }
        }
    }

    private static func dragWindow(_ target: SystemNavigation.WindowTarget, app: NSRunningApplication, windowID: CGWindowID,
                                   direction: Int, destination: UInt64, displayPoint: CGPoint, placed: @escaping () -> Bool,
                                   completion: @escaping (String?) -> Void) {
        guard app.isActive, !CGEventSource.buttonState(.hidSystemState, button: .left),
              CGPreflightPostEventAccess(), configuredKey(direction) != nil,
              let originalCursor = CGEvent(source: nil)?.location, let start = titleBarPoint(target),
              let source = CGEventSource(stateID: .hidSystemState) else {
            pending = false
            completion("无法移动该窗口。请确认窗口在前台、有可拖动的标题栏，并启用 Mission Control 左右快捷键。")
            return
        }
        let moved = CGPoint(x: start.x + 12, y: start.y)
        func mouse(_ type: CGEventType, at point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            ModifierShortcuts.postWithoutHyperRemapping(event)
        }
        mouse(.mouseMoved, at: start)
        mouse(.leftMouseDown, at: start)
        mouse(.leftMouseDragged, at: moved)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] ?? []
            let rect = (windows.first?[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:))
            guard app.isActive, let rect, abs(rect.minX - target.frame.minX) > 4, sendShortcut(direction) else {
                mouse(.leftMouseDragged, at: start)
                mouse(.leftMouseUp, at: start)
                CGWarpMouseCursorPosition(originalCursor)
                pending = false
                completion("窗口未能进入可跨空间拖动的状态。")
                return
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.2
            func releaseAfterSwitch() {
                let switched = desktop(at: displayPoint)?.current == destination
                guard switched || ProcessInfo.processInfo.systemUptime >= deadline else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: releaseAfterSwitch)
                    return
                }
                mouse(.leftMouseDragged, at: start)
                mouse(.leftMouseUp, at: start)
                CGWarpMouseCursorPosition(originalCursor)
                verify(completion: completion, until: placed)
            }
            releaseAfterSwitch()
        }
    }

    private static func titleBarPoint(_ target: SystemNavigation.WindowTarget) -> CGPoint? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        var title: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(target.window, kAXTitleUIElementAttribute as CFString, &title)
        for fraction in [0.5, 0.35, 0.65] {
            let point = CGPoint(x: target.frame.minX + fraction * target.frame.width,
                                y: target.frame.minY + 12)
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { continue }
            if CFEqual(target.window, hit) || title.map({ CFEqual($0, hit) }) == true { return point }
        }
        return nil
    }

    private static func verify(completion: @escaping (String?) -> Void, timeout: TimeInterval = 2,
                               until predicate: @escaping () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func poll() {
            if predicate() {
                pending = false
                completion(nil)
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                pending = false
                completion("macOS 未完成空间操作。请检查 Mission Control 中的空间配置。")
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: poll)
            }
        }
        poll()
    }

    struct SystemKey {
        let code: CGKeyCode
        let flags: CGEventFlags
    }

    static let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    static func configuredKey(_ direction: Int) -> SystemKey? {
        let preferences = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
            as? [String: [String: Any]]
        guard let entry = preferences?[direction < 0 ? "79" : "81"] else {
            return SystemKey(code: CGKeyCode(direction < 0 ? kVK_LeftArrow : kVK_RightArrow), flags: .maskControl)
        }
        guard (entry["enabled"] as? Bool) != false,
              let record = entry["value"] as? [String: Any], let params = record["parameters"] as? [Int],
              params.count >= 3, (0..<128).contains(params[1]) else { return nil }
        let flags = CGEventFlags(rawValue: UInt64(params[2]) & modifierMask.rawValue)
        return SystemKey(code: CGKeyCode(params[1]), flags: flags)
    }

    private static func sendShortcut(_ direction: Int) -> Bool {
        guard CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(), let key = configuredKey(direction),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = key.flags
            ModifierShortcuts.postWithoutHyperRemapping(event)
        }
        return true
    }
}

/// Intercepts only the two enabled Mission Control keys while the module runs.
final class WindowSpaceShortcuts: ObservableObject {
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "windowManagement.replaceSpaceShortcuts")
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keys: [Int: WindowSpaces.SystemKey] = [:]
    private var suppressed: Set<CGKeyCode> = []
    var available: () -> Bool = { false }
    var canHandle: (Int) -> Bool = { _ in true }
    var perform: (Int) -> Void = { _ in }

    @discardableResult
    func setEnabled(_ value: Bool) -> String? {
        if value, let error = install() { return error }
        if !value { stop() }
        enabled = value
        UserDefaults.standard.set(value, forKey: "windowManagement.replaceSpaceShortcuts")
        return nil
    }

    func refresh() {
        if enabled, available() { _ = install() }
        else { stop() }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
        keys = [:]
        suppressed.removeAll()
    }

    private func install() -> String? {
        guard available(), AXIsProcessTrusted() else { return "请先启用窗口管理并允许辅助功能。" }
        let current = [-1, 1].reduce(into: [Int: WindowSpaces.SystemKey]()) { $0[$1] = WindowSpaces.configuredKey($1) }
        guard !current.isEmpty else { return "请先在 Mission Control 设置中启用左右空间快捷键。" }
        keys = current
        if tap != nil { return nil }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<WindowSpaceShortcuts>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                owner.suppressed.removeAll()
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if owner.intercept(event, type: type) { return nil }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return "无法接管系统快捷键。请检查辅助功能和输入监控权限。"
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        return nil
    }

    private func intercept(_ event: CGEvent, type: CGEventType) -> Bool {
        guard available(), !IsSecureEventInputEnabled(),
              !ModifierShortcuts.isUnmodifiedSyntheticEvent(event),
              event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return false }
        let key = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp { return suppressed.remove(key) != nil }
        let flags = event.flags.intersection(WindowSpaces.modifierMask)
        guard let direction = keys.first(where: { _, shortcut in shortcut.code == key && shortcut.flags == flags })?.key,
              canHandle(direction) else { return false }
        if suppressed.insert(key).inserted {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.available(), self.canHandle(direction) else { return }
                self.perform(direction)
            }
        }
        return true
    }

    deinit { stop() }
}
