import SwiftUI
import AppKit
import KeylaneCore

struct CalendarPage: View {
    @ObservedObject var controller: CalendarController
    var body: some View {
        ResultDetailLayout {
            SelectableResultList(selection: controller.selectedID, revealAfterLoading: !controller.loading) {
                if controller.access == .allowed, controller.enabled {
                    if controller.filteredEvents.isEmpty {
                        Text(controller.loading ? "正在加载日程…" : "当天没有匹配的日程")
                            .font(VisualStyle.sectionText).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
                    }
                    ForEach(controller.filteredEvents) { event in
                        ResultListButton(id: event.id, action: { controller.select(event.id) }) {
                            ResultListRow(selected: event.id == controller.selectedID, height: 48) {
                                Image(systemName: event.allDay ? "sun.max.fill" : "calendar").font(.system(size: 21)).foregroundStyle(.blue)
                            } content: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HighlightedResultText(text: event.title, query: controller.query).font(VisualStyle.rowText).lineLimit(1)
                                    Text(event.allDay ? "全天 · \(event.calendarTitle)" : "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened)) · \(event.calendarTitle)")
                                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
        } detail: {
            Group {
                if !controller.enabled {
                    ContentUnavailableView {
                        Label("日历已关闭", systemImage: "calendar")
                    } description: {
                        Text("在日历设置中重新开启后可继续查看日程。")
                    } actions: {
                        Button("日历设置…") { controller.showSettings?() }.buttonStyle(ContentActionButtonStyle())
                    }
                }
                else if controller.access != .allowed { CalendarConnectionView(controller: controller) }
                else if let event = controller.selectedEvent {
                    ResultDetailPane { _ in
                        VStack(alignment: .leading, spacing: 14) {
                            Label(event.calendarTitle, systemImage: "calendar").font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(event.title).font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
                            Text(event.start.formatted(date: .complete, time: .omitted)).font(.system(size: 13))
                            Text(event.allDay ? "全天" : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .topLeading).padding(9)
                    } information: {
                        DetailInformationSection(rows: [
                            .init(title: "日历", value: event.calendarTitle),
                            .init(title: "开始", value: event.start.formatted(date: .abbreviated, time: event.allDay ? .omitted : .shortened)),
                            .init(title: "结束", value: (event.allDay ? max(event.start, event.end.addingTimeInterval(-1)) : event.end).formatted(date: .abbreviated, time: event.allDay ? .omitted : .shortened))
                        ] + (event.location.isEmpty ? [] : [.init(title: "地点", value: event.location)]))
                        if !event.notes.isEmpty { DisclosureGroup("备注") { Text(event.notes).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) } }
                    }
                } else { ContentUnavailableView(controller.loading ? "正在加载" : "没有日程", systemImage: "calendar", description: Text("选择其他日期，或在日历设置中选择要显示的日历。")) }
            }
        }
        .overlay(alignment: .bottom) { if !controller.error.isEmpty { Text(controller.error).font(.caption).foregroundStyle(.orange).padding(10).padding(.bottom, VisualStyle.launcherBottomInset) } }
    }
}

struct CalendarConnectionView: View {
    @ObservedObject var controller: CalendarController
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(controller.access.message).font(.headline)
            Text("连接后查看本机日程，并在菜单栏展示摘要。macOS将请求日历完整访问权限；Keylane当前只读取日程。").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if controller.access == .notRequested || controller.access == .writeOnly {
                Button(controller.requesting ? "正在等待授权…" : "连接日历…") { controller.requestAccess() }.disabled(controller.requesting)
            } else { Button("打开日历隐私设置") { controller.openPrivacySettings() } }
        }.buttonStyle(ContentActionButtonStyle()).frame(maxWidth: 310).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CalendarDateNavigation: View {
    let controller: CalendarController
    @StateObject private var observation: ViewObservation

    init(controller: CalendarController) {
        self.controller = controller
        _observation = StateObject(wrappedValue: ViewObservation([
            ViewObservation.changes(controller.$selectedDate)
        ]))
    }
    var body: some View {
        HStack(spacing: 4) {
            Button { controller.shiftDay(-1) } label: { Image(systemName: "chevron.left") }.help("前一天")
            DatePicker("日期", selection: Binding(get: { controller.selectedDate }, set: { controller.selectedDate = $0 }), displayedComponents: .date).labelsHidden().datePickerStyle(.field).fixedSize()
            Button { controller.shiftDay(1) } label: { Image(systemName: "chevron.right") }.help("后一天")
            Button("今天") { controller.showToday() }
        }.buttonStyle(ContentActionButtonStyle()).controlSize(.small)
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
    @State private var showsCalendars = false

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
            ViewObservation.changes(controller.$menuDisplay),
            ViewObservation.changes(controller.$error)
        ]))
    }

    var body: some View {
        SettingsPageSections {
            SettingsGroup {
                Button {
                    showsCalendars.toggle()
                } label: {
                    HStack {
                        Text("已启用的日历")
                        Spacer()
                        Image(systemName: showsCalendars ? "chevron.down" : "chevron.forward")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!controller.enabled || controller.access != .allowed)

                if showsCalendars && controller.enabled && controller.access == .allowed {
                    Divider()
                    HStack {
                        Spacer()
                        Button("全选") { controller.selectedCalendarIDs = nil }
                        Button("清空") { controller.selectedCalendarIDs = [] }
                    }
                    .buttonStyle(ContentActionButtonStyle())
                    ForEach(controller.calendars) { calendar in
                        Divider()
                        Toggle(isOn: Binding(
                            get: { controller.selectedCalendarIDs?.contains(calendar.id) ?? true },
                            set: { controller.setCalendar(calendar.id, enabled: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(calendar.title)
                                Text(calendar.source).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if controller.calendars.isEmpty {
                        Text("系统中没有可用日历").foregroundStyle(.secondary)
                    }
                }
            }.settingsAnchor(.calendarSelection)

            SettingsGroup {
                Toggle("在菜单栏显示日历", isOn: Binding(
                    get: { registry.isEnabled("calendar.agenda") },
                    set: { registry.setEnabled("calendar.agenda", $0) }
                ))
                Divider()
                SettingsPicker("显示内容", selection: Binding(get: { controller.menuDisplay }, set: { controller.menuDisplay = $0 })) {
                    Text("下一个日程").tag("next")
                    Text("日期").tag("date")
                    Text("仅图标").tag("icon")
                }
            }
            .disabled(!controller.enabled)
            .settingsAnchor(.calendarMenuBar)

            SettingsSectionTitle(title: "日历命令")
            CommandSettingsList(items: ["calendar"], id: \.self) { id in
                CommandSettingsEntry(
                    title: "我的日程",
                    model: model, commandID: .init(rawValue: id),
                    perform: { model.runCommand(.init(rawValue: id), origin: .menu) },
                    icon: { CalendarSettingsIcon(size: 24) }
                )
            }.id("calendar-command")
            if !controller.error.isEmpty {
                Text(controller.error).font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct CalendarSettingsIcon: View {
    var size: CGFloat = 56

    var body: some View {
        let today = Date()
        VStack(spacing: 0) {
            Text(today.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: size * 0.17, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity)
                .frame(height: size * 0.32)
                .background(.white.opacity(0.13))
            Text(today.formatted(.dateTime.day()))
                .font(.system(size: size * 0.49, weight: .semibold))
                .monospacedDigit()
                .frame(maxHeight: .infinity)
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Color(white: 0.16).gradient)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}
