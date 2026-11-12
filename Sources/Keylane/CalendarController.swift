import AppKit
import Combine
import EventKit
import KeylaneCore

struct CalendarChoice: Identifiable, Equatable, Sendable { let id: String; let title: String; let source: String; let writable: Bool }
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
/// EventKit writes are performed only in response to explicit event actions.
final class CalendarController: ObservableObject {
    let permission: PermissionFeature
    var enabled: Bool { permission.available }
    private var permissionChanges: AnyCancellable?
    @Published var selectedDate = Date() { didSet { if presenting { refresh() } } }
    @Published private(set) var query = "" { didSet { maintainSelection() } }
    @Published var selectedCalendarIDs: Set<String>? { didSet { preferences.set(selectedCalendarIDs.map { Array($0) }, forKey: "calendar.selectedIDs"); refresh() } }
    @Published var menuDisplay: String { didSet { preferences.set(menuDisplay, forKey: "calendar.menuDisplay"); updateMenuBar() } }
    @Published var agendaCalendarID = "all" { didSet { maintainSelection() } }
    @Published var searchWindowMinutes: Int {
        didSet {
            preferences.set(searchWindowMinutes, forKey: "calendar.searchWindow")
            updateSearchEvents()
        }
    }
    @Published private(set) var searchEvents: [AgendaEvent] = []
    @Published var menuLeadMinutes: Int { didSet { preferences.set(menuLeadMinutes, forKey: "calendar.menuLead"); updateMenuBar() } }
    @Published var menuHideMinutes: Int { didSet { preferences.set(menuHideMinutes, forKey: "calendar.menuHide"); updateMenuBar() } }
    @Published var menuMeetingsOnly: Bool { didSet { preferences.set(menuMeetingsOnly, forKey: "calendar.menuMeetingsOnly"); updateMenuBar() } }
    @Published var calendarApplication: String { didSet { preferences.set(calendarApplication, forKey: "calendar.application") } }
    @Published var googleBrowser: String { didSet { preferences.set(googleBrowser, forKey: "calendar.googleBrowser") } }
    @Published var autoJoin: Bool { didSet { preferences.set(autoJoin, forKey: "calendar.autoJoin") } }
    @Published var confirmJoin: Bool { didSet { preferences.set(confirmJoin, forKey: "calendar.confirmJoin") } }
    @Published var previewBeforeJoining: Bool { didSet { preferences.set(previewBeforeJoining, forKey: "calendar.previewBeforeJoining") } }
    @Published var draft = CalendarEventDraft()
    @Published private(set) var saving = false
    @Published private(set) var formError = ""
    private(set) var editingEvent: AgendaEvent?
    var canSave: Bool { enabled && !saving && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var formTitle: String { editingEvent == nil ? "创建日程" : "保存日程" }
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
    var previewCamera: (() -> Void)?
    private let registry: MenuBarRegistry
    private let preferences: UserDefaults
    private let worker = DispatchQueue(label: "org.keylane.calendar", qos: .userInitiated)
    private var eventStore: EKEventStore?
    private var runtime: DispatchWorkItem?
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var started = false
    private var presenting = false
    private var dismissedUntil: [String: Date] = [:]
    private var recentAndUpcoming: [AgendaEvent] = []
    private var handledMeetings: [String: Date] = [:]
    private var joinPromptVisible = false
    init(registry: MenuBarRegistry, preferences: UserDefaults = .standard,
         authorization: PermissionFeature.Authorization = .calendar) {
        self.registry = registry; self.preferences = preferences
        permission = PermissionFeature("calendar.enabled", authorization: authorization, defaults: preferences, observeImmediately: false)
        menuDisplay = preferences.string(forKey: "calendar.menuDisplay") ?? "next"
        selectedCalendarIDs = preferences.stringArray(forKey: "calendar.selectedIDs").map(Set.init)
        searchWindowMinutes = preferences.object(forKey: "calendar.searchWindow") as? Int ?? 10
        menuLeadMinutes = preferences.object(forKey: "calendar.menuLead") as? Int ?? 15
        menuHideMinutes = preferences.integer(forKey: "calendar.menuHide")
        menuMeetingsOnly = preferences.bool(forKey: "calendar.menuMeetingsOnly")
        calendarApplication = preferences.string(forKey: "calendar.application") ?? ""
        googleBrowser = preferences.string(forKey: "calendar.googleBrowser") ?? ""
        autoJoin = preferences.bool(forKey: "calendar.autoJoin")
        confirmJoin = preferences.object(forKey: "calendar.confirmJoin") as? Bool ?? true
        previewBeforeJoining = preferences.bool(forKey: "calendar.previewBeforeJoining")
    }
    var filteredEvents: [AgendaEvent] {
        AgendaPolicy.matching(events.filter { agendaCalendarID == "all" || $0.calendarID == agendaCalendarID }, query: query)
    }
    var selectedEvent: AgendaEvent? { filteredEvents.first { $0.id == selectedID } }
    func start() {
        guard !started else { return }
        started = true
        runtime = DispatchWorkItem {}
        permission.startObserving()
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
        permission.stopObserving()
        runtime?.cancel(); runtime = nil
        generation += 1; started = false; pending?.cancel(); pending = nil
        timer?.invalidate(); timer = nil
        loading = false; requesting = false; saving = false
        endPresentation()
        events = []; upcoming = []; recentAndUpcoming = []; searchEvents = []; calendars = []; selectedID = nil; lastUpdated = nil
        stopObserving()
        registry.unregister(owner: "calendar")
        worker.async { [weak self] in self?.eventStore = nil }
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
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                self?.updateMenuBar()
                self?.updateSearchEvents()
                self?.checkAutoJoin()
            }
            self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        } else {
            stopObserving()
            registry.unregister(owner: "calendar")
        }
        refresh()
    }
    func updatePresentation(query: String) {
        guard started else { return }
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
        guard let runtime, !requesting else { return }
        requesting = true; error = ""
        worker.async { [weak self] in
            guard let self, !runtime.isCancelled else { return }
            let store = self.eventStore ?? EKEventStore()
            self.eventStore = store
            store.requestFullAccessToEvents { [weak self] _, failure in
                guard let self, !runtime.isCancelled else { return }
                self.worker.async {
                    if !runtime.isCancelled { self.eventStore?.reset() }
                }
                DispatchQueue.main.async {
                    guard !runtime.isCancelled else { return }
                    self.access = .current; self.requesting = false; self.error = failure?.localizedDescription ?? ""
                    self.refresh()
                }
            }
        }
    }
    func refresh() {
        precondition(Thread.isMainThread)
        guard let runtime else { return }
        generation += 1; let ticket = generation; pending?.cancel()
        access = .current
        permission.recheck()
        guard enabled, access == .allowed else {
            events = []; upcoming = []; recentAndUpcoming = []; searchEvents = []; calendars = []; selectedID = nil; loading = false; lastUpdated = nil; updateMenuBar(); writeAcceptanceReport(); return
        }
        let includesDay = presenting
        loading = includesDay
        let date = selectedDate; let selected = selectedCalendarIDs; let now = Date(); let calendar = Calendar.current
        let job = DispatchWorkItem { [weak self] in
            guard let self, !runtime.isCancelled else { return }
            let store = self.eventStore ?? EKEventStore()
            self.eventStore = store
            let all = store.calendars(for: .event)
            let choices = all.map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title, writable: $0.allowsContentModifications) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let targets = selected.map { ids in all.filter { ids.contains($0.calendarIdentifier) } } ?? all
            let dayStart = calendar.startOfDay(for: date)
            let today = calendar.startOfDay(for: now)
            guard let dayEnd = calendar.date(byAdding: .day, value: 14, to: dayStart),
                  let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) else {
                DispatchQueue.main.async {
                    guard ticket == self.generation else { return }
                    self.loading = false
                    self.error = "无法读取这个日期的日程。"
                }
                return
            }
            func fetch(_ start: Date, _ end: Date) -> [AgendaEvent] {
                guard !runtime.isCancelled, !targets.isEmpty else { return [] }
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: targets)
                return store.events(matching: predicate).filter { $0.status != .canceled }.map { event in
                    AgendaEvent(id: Self.occurrenceID(event),
                                calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                                title: event.title?.isEmpty == false ? String(event.title.prefix(1000)) : "无标题日程",
                                start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                                location: String((event.location ?? "").prefix(2000)), notes: String((event.notes ?? "").prefix(8000)),
                                calendarColor: Self.calendarColor(event.calendar),
                                accepted: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .accepted } ?? false,
                                meetingURL: Self.meetingURL(event),
                                editable: event.calendar.allowsContentModifications,
                                recurring: event.hasRecurrenceRules || event.isDetached,
                                busy: event.availability != .free && !(event.attendees?.contains {
                                    $0.isCurrentUser && $0.participantStatus == .declined
                                } ?? false))
                }
            }
            let daily = includesDay ? fetch(dayStart, dayEnd).sorted {
                let lhs = calendar.startOfDay(for: max(dayStart, $0.start))
                let rhs = calendar.startOfDay(for: max(dayStart, $1.start))
                if lhs != rhs { return lhs < rhs }
                if $0.allDay != $1.allDay { return $0.allDay }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            } : []
            let summary = fetch(today.addingTimeInterval(-1800), weekEnd)
            let future = AgendaPolicy.upcoming(summary, now: now)
            DispatchQueue.main.async {
                guard ticket == self.generation, self.enabled else { return }
                guard CalendarAccess.current == .allowed else { self.refresh(); return }
                if self.calendars != choices { self.calendars = choices }
                if self.events != daily { self.events = daily }
                if self.upcoming != future { self.upcoming = future }
                self.recentAndUpcoming = summary
                self.updateSearchEvents()
                self.loading = false
                self.lastUpdated = Date()
                if let selectedID = self.selectedCalendarIDs,
                   self.agendaCalendarID != "all", !selectedID.contains(self.agendaCalendarID) {
                    self.agendaCalendarID = "all"
                }
                if self.agendaCalendarID != "all", !choices.contains(where: { $0.id == self.agendaCalendarID }) {
                    self.agendaCalendarID = "all"
                }
                self.maintainSelection()
                self.updateMenuBar()
                self.writeAcceptanceReport()
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
    func openSystemCalendar() {
        error = ""
        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: calendarApplication)
            ?? URL(fileURLWithPath: "/System/Applications/Calendar.app")
        if !NSWorkspace.shared.open(app) { error = "无法打开日历应用。" }
    }
    func openPrivacySettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
    func show(_ event: AgendaEvent) { query = ""; agendaCalendarID = "all"; selectedDate = event.start; selectedID = event.id; reveal?(event) }
    private static func calendarColor(_ calendar: EKCalendar) -> UInt32? {
        guard let cgColor = calendar.cgColor,
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB) else { return nil }
        let components = [color.redComponent, color.greenComponent, color.blueComponent]
        return components.reduce(0) { ($0 << 8) | UInt32((min(1, max(0, $1)) * 255).rounded()) }
    }
    private func visibleEvents(now: Date) -> [AgendaEvent] {
        dismissedUntil = dismissedUntil.filter { $0.value > now }
        return upcoming.filter { $0.end > now && dismissedUntil[$0.id] == nil && (!menuMeetingsOnly || $0.meetingURL != nil) }
    }
    private func updateSearchEvents() {
        let rows = AgendaPolicy.nearStart(recentAndUpcoming, now: Date(), minutes: searchWindowMinutes)
        if rows != searchEvents { searchEvents = rows }
    }
    private func menuEvent(_ events: [AgendaEvent], now: Date) -> AgendaEvent? {
        AgendaPolicy.menuEvent(events, now: now, leadMinutes: menuLeadMinutes, hideAfterMinutes: menuHideMinutes,
                               meetingsOnly: menuMeetingsOnly)
    }
    private func updateMenuBar() {
        guard enabled else { return }
        let now = Date()
        let next = menuEvent(visibleEvents(now: now), now: now)
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
        let next = menuEvent(events, now: now)
        var commands: [MenuBarCommand] = []
        if access == .allowed {
            if let next, next.meetingURL != nil {
                commands.append(.init(title: "加入会议", symbol: "video", action: { [weak self] in self?.joinMeeting(next) }))
            }
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

struct CalendarEventDraft {
    var title = ""
    var calendarID = ""
    var start = Date()
    var end = Date().addingTimeInterval(3600)
    var allDay = false
    var blocking = false
    var location = ""
    var notes = ""
}

extension CalendarController {
    private static func occurrenceID(_ event: EKEvent) -> String {
        (event.eventIdentifier ?? event.calendarItemIdentifier) + ":" + String(event.startDate.timeIntervalSince1970)
    }

    private static let meetingDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func meetingURL(_ event: EKEvent) -> URL? {
        var candidates = [event.url].compactMap { $0 }
        if let detector = meetingDetector {
            let text = String(((event.location ?? "") + "\n" + (event.notes ?? "")).prefix(12_000))
            candidates += detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
        }
        let hosts = ["meet.google.com", "teams.microsoft.com", "teams.live.com", "zoom.us", "zoomgov.com", "webex.com"]
        return candidates.first { url in
            guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    func joinMeeting(_ event: AgendaEvent) {
        guard enabled, let url = event.meetingURL else { return }
        handledMeetings[event.id] = event.end
        error = ""
        if previewBeforeJoining { previewCamera?() }
        if url.host?.lowercased() == "meet.google.com",
           let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: googleBrowser) {
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: .init()) { [weak self] _, failure in
                if failure != nil { DispatchQueue.main.async { self?.error = "无法用所选浏览器打开会议链接。" } }
            }
        } else if !NSWorkspace.shared.open(url) {
            error = "无法打开会议链接。"
        }
    }

    private func checkAutoJoin() {
        guard enabled, autoJoin, !joinPromptVisible else { return }
        let now = Date()
        handledMeetings = handledMeetings.filter { $0.value > now }
        guard let event = upcoming.first(where: {
            !$0.allDay && $0.meetingURL != nil && $0.busy && $0.start <= now && $0.end > now
                && now.timeIntervalSince($0.start) < 60 && handledMeetings[$0.id] == nil && dismissedUntil[$0.id] == nil
        }) else { return }
        handledMeetings[event.id] = event.end
        if !confirmJoin {
            joinMeeting(event)
            return
        }
        joinPromptVisible = true
        let alert = NSAlert()
        alert.messageText = "加入「\(event.title)」？"
        alert.informativeText = "将在会议应用或浏览器中打开链接。"
        alert.addButton(withTitle: "加入会议")
        alert.addButton(withTitle: "取消")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.joinPromptVisible = false
            if response == .alertFirstButtonReturn, self.autoJoin, event.end > Date() { self.joinMeeting(event) }
        }
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            NSApp.activate()
            finish(alert.runModal())
        }
    }

    func prepareDraft(event: AgendaEvent? = nil, blocking: Bool = false) {
        editingEvent = event
        formError = ""
        let calendar = Calendar.current
        let now = Date()
        let start = calendar.dateInterval(of: .hour, for: now)?.end ?? now
        if let event {
            draft = .init(title: event.title, calendarID: event.calendarID, start: event.start,
                          end: event.allDay ? max(event.start, event.end.addingTimeInterval(-1)) : event.end,
                          allDay: event.allDay, location: event.location, notes: event.notes)
        } else {
            let selectedStart = calendar.isDate(selectedDate, inSameDayAs: now)
                ? start : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: selectedDate) ?? selectedDate
            draft = .init(title: blocking ? "忙碌" : "", start: selectedStart, end: selectedStart.addingTimeInterval(3600), blocking: blocking)
        }
    }

    func saveDraft(completion: @escaping () -> Void) {
        guard canSave else { return }
        let draft = draft
        let editing = editingEvent
        let calendar = Calendar.current
        let start = draft.allDay ? calendar.startOfDay(for: draft.start) : draft.start
        let end = draft.allDay ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: draft.end)) : draft.end
        guard let end, end > start else {
            formError = "结束时间必须晚于开始时间。"
            return
        }
        mutate(form: true, completion: { [weak self] in
            self?.selectedDate = start
            completion()
        }) { store in
            let event = try editing.map { try Self.resolve($0, in: store) } ?? EKEvent(eventStore: store)
            let target = draft.calendarID.isEmpty ? store.defaultCalendarForNewEvents : store.calendar(withIdentifier: draft.calendarID)
            guard let target, target.allowsContentModifications else { throw CalendarMutationError.readOnly }
            event.calendar = target
            if editing?.title != draft.title { event.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
            if editing?.start != start || editing?.end != end || editing?.allDay != draft.allDay {
                event.startDate = start
                event.endDate = end
                event.isAllDay = draft.allDay
            }
            if draft.blocking && target.supportedEventAvailabilities.contains(.busy) { event.availability = .busy }
            if editing?.location != draft.location { event.location = draft.location.isEmpty ? nil : draft.location }
            if editing?.notes != draft.notes { event.notes = draft.notes.isEmpty ? nil : draft.notes }
            try store.save(event, span: .thisEvent)
        }
    }

    func confirmDeletion(_ event: AgendaEvent) {
        guard enabled, event.editable, !saving, let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "删除「\(event.title)」？"
        alert.informativeText = event.recurring ? "只删除这一次日程。" : "此日程将从日历中移除。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.mutate(form: false, completion: {}) { store in
                try store.remove(Self.resolve(event, in: store), span: .thisEvent)
            }
        }
    }

    private static func resolve(_ summary: AgendaEvent, in store: EKEventStore) throws -> EKEvent {
        guard let calendar = store.calendar(withIdentifier: summary.calendarID), calendar.allowsContentModifications else {
            throw CalendarMutationError.readOnly
        }
        let predicate = store.predicateForEvents(withStart: summary.start.addingTimeInterval(-1),
                                                 end: summary.start.addingTimeInterval(1), calendars: [calendar])
        guard let event = store.events(matching: predicate).first(where: { occurrenceID($0) == summary.id }) else {
            throw CalendarMutationError.missing
        }
        return event
    }

    private func mutate(form: Bool, completion: @escaping () -> Void,
                        operation: @escaping (EKEventStore) throws -> Void) {
        guard enabled, let runtime, !saving else { return }
        saving = true
        if form { formError = "" } else { error = "" }
        worker.async { [weak self] in
            guard let self, !runtime.isCancelled else { return }
            let result = Result {
                guard CalendarAccess.current == .allowed else { throw CalendarMutationError.noAccess }
                let store = self.eventStore ?? EKEventStore()
                self.eventStore = store
                try operation(store)
            }
            DispatchQueue.main.async {
                guard !runtime.isCancelled else { return }
                self.saving = false
                switch result {
                case .success:
                    completion()
                    self.refresh()
                case .failure(let failure):
                    if form { self.formError = failure.localizedDescription }
                    else { self.error = failure.localizedDescription }
                }
            }
        }
    }

    func availabilityText() -> String {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: selectedDate)
        let days = (0..<7).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day),
                  let end = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day),
                  max(start, now) < end else { return nil }
            let intervals = AgendaPolicy.freeIntervals(in: DateInterval(start: max(start, now), end: end), events: events)
                .filter { $0.duration >= 15 * 60 }
            guard !intervals.isEmpty else { return nil }
            let times = intervals.map { Self.timeRange($0.start, $0.end) }.joined(separator: "、")
            return day.formatted(date: .abbreviated, time: .omitted) + "  " + times
        }
        return days.isEmpty ? "所选日期起七天内没有符合条件的空闲时段。" : days.joined(separator: "\n")
    }

    static func timeRange(_ start: Date, _ end: Date) -> String {
        start.formatted(date: .omitted, time: .shortened) + " – " + end.formatted(date: .omitted, time: .shortened)
    }
}

private enum CalendarMutationError: LocalizedError {
    case readOnly, missing, noAccess

    var errorDescription: String? {
        switch self {
        case .readOnly: "请选择可编辑的日历。"
        case .missing: "此日程已移动或删除，请刷新后重试。"
        case .noAccess: "需要日历完整访问权限。"
        }
    }
}
