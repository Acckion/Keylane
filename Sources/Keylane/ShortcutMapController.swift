import AppKit
import ApplicationServices
import Carbon
import Combine
import KeylaneCore

/// Uses the existing cancellable menu scanner; never activates or executes menu items.
final class ShortcutMapController: ObservableObject {
    @Published private(set) var entries: [ShortcutMapEntry] = []
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    @Published private(set) var target: NSRunningApplication?
    @Published private(set) var systemAvailable = false
    @Published private(set) var systemIncomplete = false
    private var request: NavigationScanRequest?
    private var generation: UInt64 = 0
    private var timeout: DispatchWorkItem?

    private let trusted: () -> Bool
    private let scan: (NSRunningApplication, NavigationScanRequest, @escaping (NavigationScan) -> Void) -> Void
    private let preferences: UserDefaults
    private let timeoutInterval: Double

    init(trusted: @escaping () -> Bool = AXIsProcessTrusted,
         preferences: UserDefaults = .standard, timeoutInterval: Double = 7,
         scan: @escaping (NSRunningApplication, NavigationScanRequest, @escaping (NavigationScan) -> Void) -> Void = {
             SystemNavigation.shared.scan(.menus, target: $0, request: $1, completion: $2)
         }) {
        self.trusted = trusted; self.preferences = preferences
        self.timeoutInterval = timeoutInterval; self.scan = scan
    }

    var applications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    func load(_ app: NSRunningApplication?, completion: (() -> Void)? = nil) {
        stop()
        target = app
        let token = generation
        var raw: Unmanaged<CFArray>?
        let result = CopySymbolicHotKeys(&raw)
        let rows = raw?.takeRetainedValue() as? [[String: Any]] ?? []
        systemAvailable = result == noErr
        let enabledCount = rows.filter { ($0[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true }.count
        entries = rows.enumerated().compactMap { index, row in
            guard (row[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
                  let code = row[kHISymbolicHotKeyCode] as? NSNumber,
                  let modifiers = row[kHISymbolicHotKeyModifiers] as? NSNumber,
                  code.uint32Value < 128, modifiers.uint32Value & ~UInt32(256 | 512 | 2048 | 4096) == 0 else { return nil }
            return .init(id: "system:\(index)", shortcut: .init(key: code.uint32Value, modifiers: modifiers.uint32Value),
                         title: "系统快捷键", source: .system, path: "macOS 键盘快捷键（系统未提供操作名称）")
        }
        systemIncomplete = entries.count < enabledCount
        guard trusted() else {
            status = "读取应用菜单需要辅助功能权限。"; completion?(); return
        }
        guard let app, !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            status = "请选择要查看的应用。"; completion?(); return
        }
        let excluded = preferences.dictionary(forKey: "navigation.excludedMenuApplications") ?? [:]
        if excluded.keys.contains(where: { $0.caseInsensitiveCompare(app.bundleIdentifier ?? "") == .orderedSame }) {
            status = "此应用已在窗口与菜单设置中排除。"; completion?(); return
        }
        loading = true; status = "正在读取应用菜单…"
        let request = NavigationScanRequest()
        self.request = request
        // Unresponsive AX servers must not leave either the panel or a save waiting indefinitely.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.loading else { return }
            request.cancel(); self.request = nil; self.loading = false
            self.status = "应用菜单读取超时，结果不完整。"; completion?()
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)
        scan(app, request) { [weak self] scan in
            guard let self, self.generation == token, !request.isCancelled else { return }
            timeout.cancel(); self.timeout = nil; self.request = nil; self.loading = false
            guard !app.isTerminated else { self.status = "应用已退出，菜单结果不可用。"; completion?(); return }
            var unsupported = false
            let items: [ShortcutMapEntry] = scan.items.compactMap { item in
                guard let shortcut = item.shortcut else {
                    if !item.keys.isEmpty { unsupported = true }; return nil
                }
                return .init(id: "app:\(app.processIdentifier):\(item.id)", shortcut: shortcut,
                             title: item.title, source: .application, applicationID: app.bundleIdentifier ?? "pid:\(app.processIdentifier)",
                             path: item.detail, enabled: item.enabled)
            }
            self.entries += items
            self.status = scan.incomplete || unsupported || scan.items.isEmpty
                ? "部分应用菜单不可读取，结果不完整。" : "已读取应用菜单；应用内部及其他应用的全局快捷键可能不可见。"
            completion?()
        }
    }

    func stop() {
        generation &+= 1; request?.cancel(); request = nil; timeout?.cancel(); timeout = nil; loading = false
    }

    func overlaps(_ shortcut: Shortcut) -> [ShortcutMapEntry] {
        entries.filter { $0.conflict(with: shortcut, applicationID: target.map { $0.bundleIdentifier ?? "pid:\($0.processIdentifier)" }) != nil }
    }

    var coverage: String {
        status + (systemAvailable ? (systemIncomplete ? " 部分系统组合含 Fn 等尚未显示的按键。" : "") : " 系统快捷键读取失败。")
    }

    static var previousApplication: NSRunningApplication? {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { return front }
        return (NSApp.delegate as? Delegate)?.previousApplication
    }
}
