import AppKit
import KeylaneCore

let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
let suite = "org.keylane.menu.fixture." + UUID().uuidString
let preferences = UserDefaults(suiteName: suite)!
let registry = MenuBarRegistry(preferences: preferences)
defer { registry.shutdown(); preferences.removePersistentDomain(forName: suite) }
var clicks = 0
var title = "初始动作"
func register() {
    registry.register(id: "fixture.one", owner: "fixture", title: "生成测试", defaultVisible: false, presentation: .init(symbol: "circle", toolTip: "fixture")) {
        [.heading("生成资料"), .init(title: title, symbol: "calendar", keyEquivalent: "o", iconColor: .systemOrange, action: { clicks += 1 }), .separator,
         .init(title: "子菜单", children: [.init(title: "执行", action: { clicks += 10 })]),
         .init(title: "不可用", enabled: false, action: { clicks += 100 })]
    }
}
register(); precondition(registry.nativeItem(id: "fixture.one") == nil)
registry.setEnabled("fixture.one", true)
let first = registry.nativeItem(id: "fixture.one")!
register(); precondition(registry.nativeItem(id: "fixture.one") === first && registry.descriptors.count == 1)
registry.update(id: "fixture.one", presentation: .init(title: "更新", symbol: "calendar", toolTip: "updated"))
precondition(first.button?.title == " 更新")
let menu = first.menu!; registry.menuNeedsUpdate(menu); precondition(menu.items.count == 5)
precondition(menu.items[0].isSectionHeader)
precondition(menu.items[1].keyEquivalent == "o" && menu.items[1].image?.isTemplate == false)
if #available(macOS 27.0, *) { precondition(menu.items[1].preferredImageVisibility == .visible) }
registry.update(id: "fixture.one", presentation: .init(title: "仅文字摘要", symbol: nil, toolTip: "summary"))
precondition(first.button?.title == "仅文字摘要" && first.button?.image == nil)

menu.performActionForItem(at: 1); precondition(clicks == 1)
menu.items[3].submenu!.performActionForItem(at: 0); precondition(clicks == 11)
menu.performActionForItem(at: 4); precondition(clicks == 11)
title = "刷新后的动作"; registry.menuNeedsUpdate(menu); precondition(menu.items[1].title == title && menu.items.count == 5)
for _ in 0..<50 { registry.setEnabled("fixture.one", false); precondition(registry.nativeItem(id: "fixture.one") == nil); registry.setEnabled("fixture.one", true) }
registry.unregister(owner: "unrelated"); precondition(registry.nativeItem(id: "fixture.one") != nil)
registry.unregister(owner: "fixture"); precondition(registry.descriptors.isEmpty)
register(); precondition(registry.nativeItem(id: "fixture.one") != nil) // persisted user choice
var authorized = false
var requests = 0
var resolvePermission: ((Bool) -> Void)?
let calendar = CalendarController(registry: registry, preferences: preferences, authorization: .init(
    check: { authorized }, request: { requests += 1; resolvePermission = $0 }, guidance: "Fixture permission"
))
func settlePermission() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

calendar.start()
precondition(!calendar.enabled && requests == 0)
precondition(registry.nativeItem(id: "calendar.agenda") == nil)
calendar.permission.setEnabled(true)
calendar.permission.setEnabled(true)
precondition(requests == 1 && !calendar.enabled)
resolvePermission?(false)
settlePermission()
precondition(!calendar.enabled && !preferences.bool(forKey: "calendar.enabled"))
precondition(registry.nativeItem(id: "calendar.agenda") == nil)

calendar.permission.setEnabled(true)
authorized = true
resolvePermission?(true)
settlePermission()
registry.setEnabled("calendar.agenda", true)
precondition(calendar.enabled && preferences.bool(forKey: "calendar.enabled"))
precondition(registry.nativeItem(id: "calendar.agenda") != nil)

authorized = false
calendar.permission.recheck()
settlePermission()
precondition(!calendar.enabled && !preferences.bool(forKey: "calendar.enabled"))
precondition(registry.nativeItem(id: "calendar.agenda") == nil)

calendar.permission.setEnabled(true)
calendar.permission.setEnabled(false)
authorized = true
resolvePermission?(true)
settlePermission()
precondition(!calendar.enabled && registry.nativeItem(id: "calendar.agenda") == nil)

calendar.permission.setEnabled(true)
settlePermission()
precondition(registry.nativeItem(id: "calendar.agenda") != nil)
calendar.stop()
precondition(registry.nativeItem(id: "calendar.agenda") == nil)
precondition(preferences.bool(forKey: "calendar.enabled"))
precondition(calendar.events.isEmpty && calendar.upcoming.isEmpty && calendar.calendars.isEmpty)
calendar.start()
precondition(registry.nativeItem(id: "calendar.agenda") != nil, "Calendar restores the previous menu bar visibility")
calendar.stop()
registry.shutdown(); precondition(registry.descriptors.isEmpty)
print("PASS native menu bar: registration, update, actions, persistence, permission opt-in, denial, revocation and stale response cancellation")
