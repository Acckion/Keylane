import SwiftUI
import AppKit
import KeylaneCore

struct CalendarPage: View {
    @ObservedObject var controller: CalendarController

    var body: some View {
        Group {
            if !controller.enabled || controller.access != .allowed {
                CalendarConnectionView(controller: controller)
            } else {
                agenda
            }
        }
        .overlay(alignment: .bottom) {
            if !controller.error.isEmpty {
                Text(controller.error).font(.caption).foregroundStyle(.orange)
                    .padding(10).padding(.bottom, VisualStyle.launcherBottomInset)
            }
        }
    }

    private var agenda: some View {
        let calendar = Calendar.current
        let firstDay = calendar.startOfDay(for: controller.selectedDate)
        let rows = controller.filteredEvents
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: max(firstDay, $0.start)) }
        return SelectableResultList(selection: controller.selectedID, query: controller.query,
                                    firstResult: rows.first?.id, revealAfterLoading: !controller.loading) {
            if controller.query.isEmpty { summary(rows) }
            ForEach(grouped.keys.sorted(), id: \.self) { day in
                ResultListSection(title: dayLabel(day, calendar: calendar), isFirst: day == grouped.keys.min()) {
                    ForEach(grouped[day] ?? []) { event in row(event) }
                }
            }
            if rows.isEmpty && !controller.loading {
                Text("没有匹配的日程").foregroundStyle(.secondary).padding(10)
            }
        }
    }

    private func summary(_ rows: [AgendaEvent]) -> some View {
        let now = Date()
        let daysEvents = AgendaPolicy.day(rows, date: controller.selectedDate)
        let next = AgendaPolicy.nextTimed(rows, now: now)
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("我的日程").font(.title2.weight(.semibold))
                Text("\(dayLabel(controller.selectedDate, calendar: .current)) · \(daysEvents.count) 项日程").foregroundStyle(.secondary)
                DatePicker("起始日期", selection: $controller.selectedDate, displayedComponents: .date)
                    .labelsHidden().controlSize(.small)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let next {
                VStack(alignment: .leading, spacing: 8) {
                    Text(next.start <= now ? "正在进行" : "接下来的日程").font(.caption).foregroundStyle(.secondary)
                    Text(next.title).lineLimit(1)
                    Text(next.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(10).accessibilityElement(children: .combine)
    }

    private func row(_ event: AgendaEvent) -> some View {
        let color = event.calendarColor.map { rgb in
            Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        } ?? .accentColor
        return ResultListButton(id: event.id, action: { controller.select(event.id) }) {
            ResultListRow(selected: event.id == controller.selectedID, height: 42) {
                Circle().fill(color.opacity(0.18)).overlay { Circle().strokeBorder(color, lineWidth: 1.5) }
                    .frame(width: 21, height: 21)
            } content: {
                HStack(spacing: 12) {
                    Text(event.allDay ? "全天" : CalendarController.timeRange(event.start, event.end))
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).frame(width: 112, alignment: .leading)
                    HighlightedResultText(text: event.title, query: controller.query).font(VisualStyle.rowText).lineLimit(1)
                    Spacer(minLength: 0)
                    if event.meetingURL != nil { Image(systemName: "video").accessibilityLabel("包含会议链接") }
                    if event.recurring { Image(systemName: "repeat").accessibilityLabel("重复日程") }
                }
            }.opacity(event.end < Date() ? 0.58 : 1)
        }
    }

    private func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let formatted = date.formatted(.dateTime.month().day().weekday(.wide))
        if calendar.isDateInToday(date) { return "今天 · " + formatted }
        if calendar.isDateInTomorrow(date) { return "明天 · " + formatted }
        return formatted
    }
}

struct CalendarEventForm: View {
    @ObservedObject var controller: CalendarController
    let back: () -> Void
    @FocusState private var titleFocused: Bool

    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            LauncherCreationField("标题") {
                LauncherCreationControl(focused: titleFocused) {
                    TextField("日程标题", text: $controller.draft.title).textFieldStyle(.plain).focused($titleFocused)
                }
            }
            LauncherCreationField("日历") {
                LauncherCreationControl {
                    Picker("日历", selection: $controller.draft.calendarID) {
                        Text("默认日历").tag("")
                        ForEach(controller.calendars.filter(\.writable)) { Text($0.title).tag($0.id) }
                    }.labelsHidden()
                }
            }
            dateField("开始", date: Binding(get: { controller.draft.start }, set: { start in
                let previous = controller.draft.start
                if controller.draft.allDay {
                    let calendar = Calendar.current
                    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: previous),
                                                       to: calendar.startOfDay(for: start)).day ?? 0
                    if let end = calendar.date(byAdding: .day, value: days, to: controller.draft.end) {
                        controller.draft.end = end
                    }
                } else {
                    controller.draft.end = controller.draft.end.addingTimeInterval(start.timeIntervalSince(previous))
                }
                controller.draft.start = start
            }))
            dateField("结束", date: $controller.draft.end)
            if !controller.draft.allDay {
                LauncherCreationField("时长") {
                    LauncherCreationControl {
                        Picker("时长", selection: Binding(
                            get: { Int(controller.draft.end.timeIntervalSince(controller.draft.start) / 60) },
                            set: { minutes in controller.draft.end = controller.draft.start.addingTimeInterval(TimeInterval(minutes) * 60) }
                        )) {
                            let duration = Int(controller.draft.end.timeIntervalSince(controller.draft.start) / 60)
                            ForEach(Array(Set([15, 30, 45, 60, 90, 120, duration])).sorted(), id: \.self) {
                                Text($0 > 0 ? "\($0) 分钟" : "未设置").tag($0)
                            }
                        }.labelsHidden()
                    }
                }
            }
            LauncherCreationField("全天") { Toggle("全天", isOn: $controller.draft.allDay).labelsHidden().toggleStyle(.checkbox) }
            LauncherCreationField("地点") {
                LauncherCreationControl { TextField("添加地点", text: $controller.draft.location).textFieldStyle(.plain) }
            }
            LauncherCreationField("备注") {
                LauncherCreationControl {
                    TextField("添加备注", text: $controller.draft.notes, axis: .vertical).textFieldStyle(.plain).lineLimit(3...8)
                }
            }
            if !controller.formError.isEmpty {
                LauncherCreationField("") { Text(controller.formError).foregroundStyle(.red) }
            }
            Color.clear.frame(height: VisualStyle.launcherBottomInset)
        }
        .task { titleFocused = true }
    }

    private func dateField(_ title: String, date: Binding<Date>) -> some View {
        LauncherCreationField(title) {
            LauncherCreationControl {
                DatePicker(title, selection: date, displayedComponents: controller.draft.allDay ? .date : [.date, .hourAndMinute])
                    .labelsHidden()
            }
        }
    }
}

struct CalendarConnectionView: View {
    @ObservedObject var controller: CalendarController
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(controller.access.message).font(.headline)
            Text("连接后查看本机日程，并在菜单栏展示摘要。macOS 将请求日历完整访问权限，以便查看和管理日程。").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if controller.access == .notRequested || controller.access == .writeOnly {
                Button(controller.requesting ? "正在等待授权…" : "连接日历…") { controller.requestAccess() }.disabled(controller.requesting)
            } else { Button("打开日历隐私设置") { controller.openPrivacySettings() } }
        }.buttonStyle(ContentActionButtonStyle()).frame(maxWidth: 310).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CalendarAgendaFilter: View {
    @ObservedObject var controller: CalendarController
    @Binding var open: Bool
    let navigation: String

    var body: some View {
        let calendars = controller.calendars.filter { controller.selectedCalendarIDs?.contains($0.id) ?? true }
        let options = [ResultFilterOption(id: "all", title: "全部日历", symbol: "calendar")]
            + calendars.map { ResultFilterOption(id: $0.id, title: $0.title, symbol: "calendar") }
        ResultTypeFilter(selection: $controller.agendaCalendarID, options: options,
                         open: $open, navigation: navigation, width: 158, searchPlaceholder: "搜索日历…")
    }
}

struct MenuBarPreferences: View {
    @ObservedObject var registry: MenuBarRegistry
    var body: some View {
        SettingsGroup {
            ForEach(Array(registry.descriptors.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 { Divider() }
                Toggle(descriptor.title, isOn: Binding(get: { registry.isEnabled(descriptor.id) }, set: { registry.setEnabled(descriptor.id, $0) }))
            }
        }.settingsAnchor(.menuBar)
    }
}

struct EnabledCalendarsPreferences: View {
    @ObservedObject var controller: CalendarController

    var body: some View {
        let groups = Dictionary(grouping: controller.calendars, by: \.source)
        SettingsPageSections {
            ForEach(groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { source in
                SettingsSectionTitle(title: source)
                SettingsGroup {
                    let rows = groups[source] ?? []
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, calendar in
                        if index > 0 { Divider() }
                        Toggle(isOn: Binding(
                            get: { controller.selectedCalendarIDs?.contains(calendar.id) ?? true },
                            set: { controller.setCalendar(calendar.id, enabled: $0) }
                        )) {
                            HStack(spacing: 9) {
                                Circle().fill(color(calendar.color)).frame(width: 12, height: 12)
                                    .accessibilityHidden(true)
                                Text(calendar.title)
                            }
                        }
                    }
                }
            }
            if groups.isEmpty {
                SettingsGroup {
                    Text("系统中没有可用日历").foregroundStyle(.secondary)
                }
            }
        }.settingsAnchor(.calendarSelection)
    }

    private func color(_ rgb: UInt32?) -> Color {
        guard let rgb else { return .secondary }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

struct CalendarPreferences: View {
    let model: Model

    var body: some View {
        CalendarSettingsGroups(model: model, controller: model.calendar, registry: model.menuBar)
    }
}

private struct CalendarSettingsGroups: View {
    let model: Model
    let controller: CalendarController
    @StateObject private var observation: ViewObservation
    @ObservedObject var registry: MenuBarRegistry
    @State private var calendarApps: [URL] = []
    @State private var browsers: [URL] = []

    init(model: Model, controller: CalendarController, registry: MenuBarRegistry) {
        self.model = model
        self.controller = controller
        self.registry = registry
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(model.$aliases.map { $0["calendar"] }),
            ViewObservation.changes(model.$bindings.map { $0["calendar"] }),
            controller.permission.updates,
            ViewObservation.changes(controller.$access),
            ViewObservation.changes(controller.$calendars),
            ViewObservation.changes(controller.$selectedCalendarIDs),
            ViewObservation.changes(controller.$searchWindowMinutes),
            ViewObservation.changes(controller.$menuTiming),
            ViewObservation.changes(controller.$menuHideMinutes),
            ViewObservation.changes(controller.$menuMeetingsOnly),
            ViewObservation.changes(controller.$calendarApplication),
            ViewObservation.changes(controller.$googleBrowser),
            ViewObservation.changes(controller.$autoJoin),
            ViewObservation.changes(controller.$confirmJoin),
            ViewObservation.changes(controller.$previewBeforeJoining),
            ViewObservation.changes(model.$disabledCommands),
            ViewObservation.changes(controller.$error)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                Button {
                    model.settingsPage = CalendarLauncherModule.enabledCalendarsSettingsID
                } label: {
                    HStack {
                        Text("已启用的日历")
                        Spacer()
                        Image(systemName: "chevron.forward").foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!controller.enabled || controller.access != .allowed)
            }

            SettingsGroup {
                SettingsPicker("在主搜索中显示日程", selection: Binding(
                    get: { controller.searchWindowMinutes }, set: { controller.searchWindowMinutes = $0 }
                )) {
                    Text("关闭").tag(0)
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("开始前后 \($0) 分钟").tag($0) }
                }
                Divider()
                applicationPicker("默认日历应用", defaultTitle: "系统日历", apps: calendarApps, selection: Binding(
                    get: { controller.calendarApplication }, set: { controller.calendarApplication = $0 }
                ))
                Divider()
                applicationPicker("Google Meet 浏览器", defaultTitle: "系统默认浏览器", apps: browsers, selection: Binding(
                    get: { controller.googleBrowser }, set: { controller.googleBrowser = $0 }
                ))
            }.settingsAnchor(.calendarDisplay)

            SettingsGroup {
                SettingsRow("自动加入会议", detail: "会议开始时打开日程中的会议链接。") {
                    Toggle("自动加入会议", isOn: Binding(get: { controller.autoJoin }, set: { controller.autoJoin = $0 }))
                        .labelsHidden()
                }
                Toggle("加入前确认", isOn: Binding(get: { controller.confirmJoin }, set: { controller.confirmJoin = $0 }))
                    .toggleStyle(.checkbox).disabled(!controller.autoJoin)
                Divider()
                SettingsRow("相机预览", detail: "加入会议时调用 Keylane 工具中的相机预览。") {
                    Toggle("相机预览", isOn: Binding(get: { controller.previewBeforeJoining }, set: { controller.previewBeforeJoining = $0 }))
                        .labelsHidden()
                }
            }.settingsAnchor(.calendarMeetings)

            SettingsGroup {
                SettingsPicker("在菜单栏中显示日程", selection: Binding(
                    get: { registry.isEnabled("calendar.agenda") ? controller.menuTiming : .never },
                    set: controller.setMenuTiming
                )) {
                    ForEach(AgendaMenuTiming.allCases, id: \.self) { timing in
                        Text(menuTimingTitle(timing)).tag(timing)
                    }
                }
                Toggle("仅显示带会议链接的日程", isOn: Binding(
                    get: { controller.menuMeetingsOnly }, set: { controller.menuMeetingsOnly = $0 }
                )).toggleStyle(.checkbox)
                Divider()
                SettingsPicker("隐藏当前日程", selection: Binding(
                    get: { controller.menuHideMinutes }, set: { controller.menuHideMinutes = $0 }
                )) {
                    Text("自动").tag(0)
                    ForEach([2, 5, 10, 15], id: \.self) { Text("开始后 \($0) 分钟").tag($0) }
                }
            }
            .disabled(!controller.enabled)
            .settingsAnchor(.calendarMenuBar)

            SettingsSectionTitle(title: "日历命令")
            CommandSettingsList(items: ["create-calendar-event", "calendar"], id: \.self) { id in
                CommandSettingsEntry(
                    title: id == "calendar" ? "我的日程" : "创建日程",
                    model: model, commandID: .init(rawValue: id),
                    isEnabled: Binding(get: { !model.disabledCommands.contains(id) }, set: {
                        if $0 { model.disabledCommands.remove(id) } else { model.disabledCommands.insert(id) }
                    }),
                    perform: { model.runCommand(.init(rawValue: id), origin: .menu) },
                    icon: { SettingsIcon(symbol: "calendar", artwork: ModuleArtwork.settings("calendar")) }
                )
            }.id("calendar-command")
            if !controller.error.isEmpty {
                Text(controller.error).font(.caption).foregroundStyle(.orange)
            }
        }.task {
            let workspace = NSWorkspace.shared
            if let calendarURL = URL(string: "webcal://calendar.example/calendar.ics") {
                calendarApps = workspace.urlsForApplications(toOpen: calendarURL)
            }
            if let meetURL = URL(string: "https://meet.google.com") {
                browsers = workspace.urlsForApplications(toOpen: meetURL)
            }
        }
    }

    private func menuTimingTitle(_ timing: AgendaMenuTiming) -> String {
        switch timing {
        case .always: "始终"
        case .upcoming: "即将开始的日程"
        case .oneHour: "提前 1 小时"
        case .atStart: "日程开始时"
        case .never: "从不"
        default: "提前 \(timing.rawValue) 分钟"
        }
    }

    private func applicationPicker(_ title: String, defaultTitle: String, apps: [URL], selection: Binding<String>) -> some View {
        let choices = apps.compactMap { url -> (String, String)? in
            guard let identifier = Bundle(url: url)?.bundleIdentifier else { return nil }
            return (identifier, FileManager.default.displayName(atPath: url.deletingPathExtension().path))
        }
        return SettingsPicker(title, selection: selection) {
            Text(defaultTitle).tag("")
            ForEach(Array(Set(choices.map { $0.0 })).sorted(), id: \.self) { identifier in
                Text(choices.first { $0.0 == identifier }?.1 ?? identifier).tag(identifier)
            }
            if !selection.wrappedValue.isEmpty, !choices.contains(where: { $0.0 == selection.wrappedValue }) {
                Text("应用已不可用").tag(selection.wrappedValue)
            }
        }
    }
}
