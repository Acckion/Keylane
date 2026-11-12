import AppKit
import Combine
import EventKit
import KeylaneCore

struct CalendarChoice: Identifiable, Equatable, Sendable { let id: String; let title: String; let source: String }
enum CalendarAccess: String {
    case notRequested, allowed, denied, restricted, writeOnly
    static var current: Self {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .allowed
        case .notDetermined: return .notRequested
        case .restricted: return .restricted
        case .writeOnly: return .writeOnly
        default: return .denied
        }
    }
    var message: String {
        switch self {
        case .allowed: return "已连接系统日历"
        case .notRequested: return "尚未连接日历"
        case .denied: return "日历访问已被拒绝"
        case .restricted: return "系统限制了日历访问"
        case .writeOnly: return "读取日程需要完整访问权限"
        }
    }
}

/// One serial queue owns the EventKit store; only immutable summaries enter the UI.
/// No calendar data is written to disk, uploaded, or modified through EventKit.
final class CalendarController: ObservableObject {
    let permission: PermissionFeature
    var enabled: Bool { permission.available }
    private var permissionChanges: AnyCancellable?
    @Published var selectedDate = Date() { didSet { if presenting { refresh() } } }
    @Published private(set) var query = "" { didSet { maintainSelection() } }
    @Published var selectedCalendarIDs: Set<String>? { didSet { preferences.set(selectedCalendarIDs.map { Array($0) }, forKey: "calendar.selectedIDs"); refresh() } }
    @Published var menuDisplay: String { didSet { preferences.set(menuDisplay, forKey: "calendar.menuDisplay"); updateMenuBar() } }
    @Published private(set) var access: CalendarAccess = .notRequested
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var upcoming: [AgendaEvent] = []
    @Published private(set) var loading = false
    @Published private(set) var requesting = false
    @Published private(set) var error = ""
    @Published private(set) var selectedID: String?
    @Published private(set) var lastUpdated: Date?
    var reveal: ((AgendaEvent?) -> Void)?
    var showSettings: (() -> Void)?
    private let registry: MenuBarRegistry
    private let preferences: UserDefaults
    private let worker = DispatchQueue(label: "org.keylane.calendar", qos: .userInitiated)
    private lazy var eventStore = EKEventStore()
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false
    private var presenting = false
    private var dismissedUntil: [String: Date] = [:]
    init(registry: MenuBarRegistry, preferences: UserDefaults = .standard,
         authorization: PermissionFeature.Authorization = .calendar) {
        self.registry = registry; self.preferences = preferences
        permission = PermissionFeature("calendar.enabled", authorization: authorization, defaults: preferences)
        menuDisplay = preferences.string(forKey: "calendar.menuDisplay") ?? "next"
        selectedCalendarIDs = preferences.stringArray(forKey: "calendar.selectedIDs").map(Set.init)
    }
    var filteredEvents: [AgendaEvent] { AgendaPolicy.matching(events, query: query) }
    var selectedEvent: AgendaEvent? { filteredEvents.first { $0.id == selectedID } }
    func start() {
        guard !started else { return }
        started = true
        permissionChanges = permission.updates.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, self.started else { return }
            self.configure()
        }
        configure()
    }
    private func startObserving() {
        let center = NotificationCenter.default
        for name in [Notification.Name.EKEventStoreChanged, .NSCalendarDayChanged, NSNotification.Name.NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
    }
    func stop() {
        permissionChanges = nil
        generation += 1; started = false; pending?.cancel(); timer?.invalidate(); timer = nil
        loading = false
        endPresentation()
        stopObserving()
        registry.unregister(owner: "calendar")
    }
    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver); workspaceObservers = []
    }
    private func configure() {
        timer?.invalidate(); timer = nil
        if enabled {
            if observers.isEmpty { startObserving() }
            registry.register(id: "calendar.agenda", owner: "calendar", title: "日历", defaultVisible: false,
                              presentation: .init(symbol: "calendar", toolTip: "日历")) { [weak self] in self?.menuCommands() ?? [] }
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        } else {
            stopObserving()
            registry.unregister(owner: "calendar")
        }
        refresh()
    }
    func updatePresentation(query: String) {
        if !presenting {
            presenting = true
            refresh()
        }
        if self.query != query { self.query = query }
    }
    func endPresentation() {
        guard presenting else { return }
        presenting = false
        let interruptedRefresh = loading
        events = []
        selectedID = nil
        if !query.isEmpty { query = "" }
        if interruptedRefresh { refresh() }
    }
    func requestAccess() {
        guard !requesting else { return }
        requesting = true; error = ""
        worker.async { [weak self] in
            guard let self else { return }
            self.eventStore.requestFullAccessToEvents { [weak self] _, failure in
                guard let self else { return }
                self.worker.async { self.eventStore.reset() }
                DispatchQueue.main.async { self.access = .current; self.requesting = false; self.error = failure?.localizedDescription ?? ""; self.refresh() }
            }
        }
    }
    func refresh() {
        precondition(Thread.isMainThread)
        guard started || presenting else { return }
        generation += 1; let ticket = generation; pending?.cancel()
        access = .current
        permission.recheck()
        guard enabled, access == .allowed else {
            events = []; upcoming = []; calendars = []; selectedID = nil; loading = false; lastUpdated = nil; updateMenuBar(); writeAcceptanceReport(); return
        }
        let includesDay = presenting
        loading = includesDay
        let date = selectedDate; let selected = selectedCalendarIDs; let now = Date(); let calendar = Calendar.current
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let store = self.eventStore
            let all = store.calendars(for: .event)
            let choices = all.map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let targets = selected.map { ids in all.filter { ids.contains($0.calendarIdentifier) } } ?? all
            let dayStart = calendar.startOfDay(for: date)
            let today = calendar.startOfDay(for: now)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
                  let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) else {
                DispatchQueue.main.async {
                    guard ticket == self.generation else { return }
                    self.loading = false
                    self.error = "无法读取这个日期的日程。"
                }
                return
            }
            func fetch(_ start: Date, _ end: Date) -> [AgendaEvent] {
                guard !targets.isEmpty else { return [] }
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: targets)
                return store.events(matching: predicate).filter { $0.status != .canceled }.map { event in
                    AgendaEvent(id: (event.eventIdentifier ?? event.calendarItemIdentifier) + ":" + String(event.startDate.timeIntervalSince1970),
                                calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                                title: event.title?.isEmpty == false ? String(event.title.prefix(1000)) : "无标题日程",
                                start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                                location: String((event.location ?? "").prefix(2000)), notes: String((event.notes ?? "").prefix(8000)),
                                calendarColor: Self.calendarColor(event.calendar),
                                accepted: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .accepted } ?? false)
                }
            }
            let daily = includesDay ? AgendaPolicy.day(fetch(dayStart, dayEnd), date: date, calendar: calendar) : []
            let future = AgendaPolicy.upcoming(fetch(today, weekEnd), now: now)
            DispatchQueue.main.async {
                guard ticket == self.generation, self.enabled else { return }
                guard CalendarAccess.current == .allowed else { self.refresh(); return }
                if self.calendars != choices { self.calendars = choices }
                if self.events != daily { self.events = daily }
                if self.upcoming != future { self.upcoming = future }
                self.loading = false; self.error = ""; self.lastUpdated = Date(); self.maintainSelection(); self.updateMenuBar(); self.writeAcceptanceReport()
            }
        }
        pending = job
        worker.asyncAfter(deadline: .now() + 0.12, execute: job)
        updateMenuBar()
    }
    func select(_ id: String?) { selectedID = id }
    func move(_ delta: Int) { let rows = filteredEvents; let i = rows.firstIndex { $0.id == selectedID } ?? 0; let next = NavigationBounds.move(i, by: delta, count: rows.count); if rows.indices.contains(next) { selectedID = rows[next].id } }
    private func maintainSelection() {
        // A menu selection can target a different day while its query is in flight.
        guard !loading else { return }
        let rows = filteredEvents
        if !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
    }
    func setCalendar(_ id: String, enabled: Bool) {
        var ids = selectedCalendarIDs ?? Set(calendars.map(\.id))
        if enabled { ids.insert(id) } else { ids.remove(id) }; selectedCalendarIDs = ids
    }
    func shiftDay(_ value: Int) { if let date = Calendar.current.date(byAdding: .day, value: value, to: selectedDate) { selectedDate = date } }
    func showToday() { selectedDate = Date() }
    func openSystemCalendar() { if !NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) { error = "无法打开系统日历。" } }
    func openPrivacySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
    func show(_ event: AgendaEvent) { query = ""; selectedDate = event.start; selectedID = event.id; reveal?(event) }
    private static func calendarColor(_ calendar: EKCalendar) -> UInt32? {
        guard let cgColor = calendar.cgColor,
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB) else { return nil }
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        return components.reduce(0) { ($0 << 8) | UInt32((min(1, max(0, $1)) * 255).rounded()) }
    }
    private func visibleEvents(now: Date) -> [AgendaEvent] {
        dismissedUntil = dismissedUntil.filter { $0.value > now }
        return upcoming.filter { $0.end > now && dismissedUntil[$0.id] == nil }
    }
    private func updateMenuBar() {
        guard enabled else { return }
        let now = Date()
        let next = AgendaPolicy.nextTimed(visibleEvents(now: now), now: now)
        var title = ""
        var symbol: String? = "calendar"
        if menuDisplay == "next", access == .allowed, let next {
            let remaining = next.start.timeIntervalSince(now)
            let relative: String
            if remaining <= 0 { relative = "进行中" }
            else if remaining < 3600 { relative = "\(Int(ceil(remaining / 60))) 分钟后" }
            else { relative = next.start.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) }
            title = String(next.title.prefix(22)) + " · " + relative
            symbol = nil
        } else if menuDisplay == "date" {
            title = now.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
        registry.update(id: "calendar.agenda", presentation: .init(title: title, symbol: symbol, toolTip: access == .allowed ? "查看日程" : access.message))
    }
    private func menuCommands() -> [MenuBarCommand] {
        let now = Date()
        let events = visibleEvents(now: now)
        let next = AgendaPolicy.nextTimed(events, now: now)
        var commands: [MenuBarCommand] = []
        if access == .allowed {
            commands.append(.init(title: "打开系统日历", symbol: "calendar", action: { [weak self] in self?.openSystemCalendar() }))
            if let next {
                commands.append(.init(title: "忽略当前日程", symbol: "xmark.circle", action: { [weak self] in
                    self?.dismissedUntil[next.id] = next.end
                    self?.updateMenuBar()
                }))
            }
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            var hasRows = false
            for offset in 0...1 {
                guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
                let rows = AgendaPolicy.ordered(events.filter { calendar.isDate(max($0.start, today), inSameDayAs: date) })
                guard !rows.isEmpty else { continue }
                hasRows = true
                commands.append(.separator)
                let label = offset == 0 ? "今天" : "明天"
                commands.append(.heading(label + " · " + date.formatted(.dateTime.month().day())))
                for event in rows.prefix(12) {
                    let time = event.allDay ? "全天" : event.start.formatted(date: .omitted, time: .shortened) + " – " + event.end.formatted(date: .omitted, time: .shortened)
                    let symbol = event.id == next?.id ? "circle.fill" : event.accepted ? "checkmark.circle" : "circle"
                    let color = event.calendarColor.map { rgb in
                        NSColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
                    } ?? .systemOrange
                    commands.append(.init(title: time + "  " + String(event.title.prefix(60)), symbol: symbol, iconColor: color, action: { [weak self] in self?.show(event) }))
                }
            }
            if !hasRows { commands += [.separator, .heading(loading ? "正在加载…" : "今天和明天没有待开始的日程")] }
            if !dismissedUntil.isEmpty {
                commands += [.separator, .init(title: "恢复已忽略日程", symbol: "arrow.uturn.backward", action: { [weak self] in
                    self?.dismissedUntil.removeAll()
                    self?.updateMenuBar()
                })]
            }
        } else {
            commands.append(.heading(access.message))
            if access == .notRequested || access == .writeOnly {
                commands.append(.init(title: "连接日历…", symbol: "calendar.badge.plus", enabled: !requesting, action: { [weak self] in self?.requestAccess() }))
            } else {
                commands.append(.init(title: "日历隐私设置…", symbol: "lock", action: { [weak self] in self?.openPrivacySettings() }))
            }
        }
        commands += [.separator,
                     .init(title: "日历设置…", symbol: "gearshape", keyEquivalent: ",", action: { [weak self] in self?.showSettings?() }),
                     .init(title: "在 Keylane 中打开", symbol: "command", keyEquivalent: "o", action: { [weak self] in
                         if let next { self?.show(next) } else { self?.reveal?(nil) }
                     })]
        return commands
    }
    private func writeAcceptanceReport() {
        guard ProcessInfo.processInfo.environment["KEYLANE_CALENDAR_ACCEPTANCE"] == "1" else { return }
        let report: [String: Any] = ["authorized": access == .allowed, "calendarCount": calendars.count, "dayEventCount": events.count, "upcomingCount": upcoming.count, "statusItemPresent": registry.nativeItem(id: "calendar.agenda") != nil, "timestamp": Date().timeIntervalSince1970]
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/Diagnostics/calendar-acceptance.json")
        worker.async { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); if let data = try? JSONSerialization.data(withJSONObject: report) { try? data.write(to: url, options: .atomic) } }
    }
}
