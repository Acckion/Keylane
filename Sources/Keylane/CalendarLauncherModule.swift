import Combine
import KeylaneCore
import SwiftUI

enum CalendarLauncherModule {
    private static let commandID = CommandID(rawValue: "calendar")
    private static let pageID = PageID(rawValue: "Calendar")
    private static let formID = PageID(rawValue: "CalendarEventForm")
    private static let createID = CommandID(rawValue: "create-calendar-event")
    private static let eventPrefix = "calendar-event:"
    private static let settingsID = "calendar"
    static let enabledCalendarsSettingsID = "calendar-enabled"

    static func make(model: Model) -> LauncherModule {
        let calendar = model.calendar
        return .init(
            id: .init(rawValue: "keylane.calendar"),
            commands: [.init(
                declaration: .init(id: commandID, title: "我的日程", detail: "查看系统日历与日程",
                                   symbol: "calendar", keywords: ["Calendar", "My Schedule", "日历", "日程", "会议"],
                                   destination: .page(pageID), settingsPage: settingsID),
                permission: calendar.permission,
                execute: { [weak model] _ in
                    if model?.pageID == pageID { model?.query = "" }
                    calendar.showToday()
                }
            ), .init(
                declaration: .init(id: createID, title: "创建日程", detail: "在系统日历中添加日程",
                                   symbol: "calendar.badge.plus", keywords: ["Create Event", "新建日程", "添加日历事件"],
                                   destination: .page(formID), settingsPage: settingsID),
                permission: calendar.permission,
                execute: { _ in
                    calendar.showToday()
                    calendar.prepareDraft()
                }
            )],
            providers: [eventProvider(calendar)],
            pages: [.init(
                id: pageID, placeholder: "搜索日程…", badge: ("我的日程", "calendar"), actionTitle: "日历操作",
                contentPlacement: .underChrome,
                content: { AnyView(CalendarPage(controller: calendar)) },
                queryChanged: { calendar.updatePresentation(query: $0) },
                leave: { calendar.endPresentation() },
                move: { calendar.move($0) },
                submit: { primary(calendar) },
                actionContextTitle: { calendar.selectedEvent?.title },
                primaryTitle: { calendar.selectedEvent.map(primaryTitle) ?? "打开日历" },
                actions: { [weak model] in
                    guard let model else { return [] }
                    return actions(model)
                },
                updates: Publishers.MergeMany([
                    ViewObservation.changes(calendar.$selectedID),
                    ViewObservation.changes(calendar.$events),
                    ViewObservation.changes(calendar.$loading)
                ]).eraseToAnyPublisher(),
                moveHorizontal: { calendar.shiftDay($0) },
                typeFilterWidth: 158,
                typeFilter: { [weak model] open in
                    AnyView(CalendarAgendaFilter(controller: calendar, open: open, navigation: model?.navigation ?? "arrows"))
                },
                actionShortcutsEnabled: true,
                loading: calendar.$loading.eraseToAnyPublisher()
            ), .init(
                id: formID, placeholder: "", badge: ("日历日程", "calendar.badge.plus"),
                contentPlacement: .form,
                content: { [weak model] in
                    AnyView(CalendarEventForm(controller: calendar) { model?.pageID = pageID })
                },
                submit: { [weak model] in calendar.saveDraft { if model?.pageID == formID { model?.pageID = pageID } } },
                shortcutSubmit: { [weak model] in calendar.saveDraft { if model?.pageID == formID { model?.pageID = pageID } } },
                primaryTitle: { calendar.formTitle },
                primaryEnabled: { calendar.canSave },
                updates: Publishers.Merge(
                    ViewObservation.changes(calendar.$draft.map { [$0.title, $0.invitees] }),
                    ViewObservation.changes(calendar.$saving)
                ).eraseToAnyPublisher()
            )],
            settings: [.init(
                id: settingsID, title: "日历", symbol: "calendar", subtitle: "查看日程和会议。", order: 50,
                items: SettingsItem.all.filter { $0.page == settingsID },
                titlebar: calendar.permission.titlebar("启用日历"),
                loading: calendar.$loading.eraseToAnyPublisher(),
                content: { [weak model] in
                    guard let model else { return AnyView(EmptyView()) }
                    return AnyView(CalendarPreferences(model: model))
                }
            ), .init(
                id: enabledCalendarsSettingsID, title: "已启用的日历", symbol: "calendar", subtitle: "", order: 51,
                items: [.calendarSelection], parentID: settingsID,
                loading: calendar.$loading.eraseToAnyPublisher(),
                content: { AnyView(EnabledCalendarsPreferences(controller: calendar)) }
            )],
            services: [.init(
                start: { [weak model] in
                    calendar.reveal = { [weak model] event in
                        guard let model, model.calendar.enabled else { return }
                        if event == nil {
                            model.runCommand(commandID, origin: .menu)
                        } else {
                            if model.pageID == pageID { model.query = "" }
                            model.openPage(pageID, origin: .menu)
                        }
                    }
                    calendar.showSettings = { [weak model] in model?.openSettings(page: settingsID) }
                    calendar.previewCamera = { [weak model] in
                        model?.launcherModules?.resolve(CommandID(rawValue: "show-camera"), origin: .menu, navigate: { _ in })?()
                    }
                    calendar.reportFailure = { message in
                        (NSApp?.delegate as? Delegate)?.toast.show(message, style: .failure)
                    }
                    calendar.start()
                },
                stop: {
                    calendar.stop()
                    calendar.reveal = nil
                    calendar.showSettings = nil
                    calendar.previewCamera = nil
                    calendar.reportFailure = nil
                }
            )],
            searchUpdates: [calendar.permission.updates, ViewObservation.changes(calendar.$searchEvents)]
        )
    }
    private static func eventProvider(_ calendar: CalendarController) -> LauncherModule.Provider {
        .init(namespace: .prefix(eventPrefix), entries: { input in
            guard input.page == .root, calendar.enabled else { return [] }
            return calendar.searchEvents.prefix(8).map { event in
                let id = eventPrefix + event.id
                return Entry(id: id, commandID: .init(rawValue: id), name: event.title, detail: "日程",
                             symbol: event.meetingURL == nil ? "calendar" : "video",
                             aliases: [event.calendarTitle, event.location] + (event.meetingURL == nil ? [] : ["加入会议", "Join Meeting"]),
                             subtitle: CalendarController.timeRange(event.start, event.end))
            }
        }, resolve: { id, _ in
            guard calendar.enabled, let event = calendar.searchEvents.first(where: { eventPrefix + $0.id == id.rawValue }) else { return nil }
            return { performPrimary(for: event, calendar: calendar) }
        }, primaryTitle: { entry in
            calendar.searchEvents.first { eventPrefix + $0.id == entry.id }.map(primaryTitle)
        }, actions: { entry in
            guard let event = calendar.searchEvents.first(where: { eventPrefix + $0.id == entry.id }) else { return nil }
            return eventActions(event, calendar: calendar)
        }, displayDetail: { _ in "日程" }, permission: { _ in calendar.permission })
    }

    private static func primaryTitle(for event: AgendaEvent) -> String {
        event.meetingURL == nil ? "在 Apple 日历中打开" : "加入会议"
    }

    private static func performPrimary(for event: AgendaEvent, calendar: CalendarController) {
        if event.meetingURL != nil { calendar.joinMeeting(event) }
        else { calendar.openEvent(event) }
    }

    private static func primary(_ calendar: CalendarController) {
        if let event = calendar.selectedEvent { performPrimary(for: event, calendar: calendar) }
        else { calendar.openSystemCalendar() }
    }

    private static func eventActions(_ event: AgendaEvent, calendar: CalendarController) -> [LauncherAction] {
        var actions: [LauncherAction] = []
        if event.meetingURL != nil {
            actions.append(.init(id: "join-meeting", title: "加入会议", icon: "video", perform: { calendar.joinMeeting(event) }))
        }
        actions.append(.init(id: "open-calendar", title: "在 Apple 日历中打开", icon: "calendar",
                             perform: { calendar.openEvent(event) }))
        if event.hasInvitation {
            actions.append(.init(id: "respond-invitation", title: "在日历中回复邀请", icon: "envelope",
                                 perform: { calendar.openEvent(event) }))
        }
        return actions
    }

    private static func actions(_ model: Model) -> [LauncherAction] {
        let calendar = model.calendar
        let event = calendar.selectedEvent
        let canCreate = calendar.enabled && !calendar.saving && !model.disabledCommands.contains(createID.rawValue)
        func form(_ event: AgendaEvent? = nil, blocking: Bool = false) {
            calendar.prepareDraft(event: event, blocking: blocking)
            model.openPage(formID, origin: .search)
        }
        var actions = event.map { eventActions($0, calendar: calendar) }
            ?? [.init(id: "open-calendar", title: "打开日历", icon: "calendar", perform: calendar.openSystemCalendar)]
        actions.append(.init(id: "new-event", title: "创建日程", icon: "plus", keys: ["⌘", "N"], group: 1,
                             enabled: canCreate, perform: { form() }))
        if let event {
            if event.editable {
                actions.append(.init(id: "edit-event", title: "编辑日程", icon: "pencil", keys: ["⌘", "E"], group: 1,
                                     enabled: !calendar.saving, perform: { form(event) }))
            }
            if !event.participants.isEmpty {
                actions.append(.init(id: "copy-attendees", title: "复制参与者及回复状态", icon: "person.2", group: 2, perform: {
                    let participants = event.participants.map { [$0.name, $0.status].filter { !$0.isEmpty }.joined(separator: " · ") }
                    _ = UtilityActions.copy(participants.joined(separator: "\n"))
                }))
            }
            actions += [
                .init(id: "copy-event", title: "复制日程详情", icon: "doc.on.clipboard", keys: ["⇧", "⌘", "C"], group: 2, perform: {
                    let time = event.allDay ? "全天" : CalendarController.timeRange(event.start, event.end)
                    let lines = [event.title, event.start.formatted(date: .complete, time: .omitted) + " · " + time,
                                 event.calendarTitle, event.location, event.eventURL?.absoluteString ?? "",
                                 event.meetingURL == event.eventURL ? "" : event.meetingURL?.absoluteString ?? "", event.notes]
                    _ = UtilityActions.copy(lines.filter { !$0.isEmpty }.joined(separator: "\n"))
                }),
                .init(id: "copy-event-title", title: "复制日程标题", icon: "doc.on.clipboard", keys: ["⌥", "⌘", "C"], group: 2,
                      perform: { _ = UtilityActions.copy(event.title) })
            ]
        }
        actions += [
            .init(id: "copy-availability", title: "复制空闲时间（七天，09:00–18:00）", icon: "doc.on.clipboard", keys: ["⌃", "⌘", "A"], group: 3,
                  enabled: calendar.enabled && !calendar.loading,
                  perform: { _ = UtilityActions.copy(calendar.availabilityText()) }),
            .init(id: "block-time", title: "预留时间", icon: "clock", keys: ["⇧", "⌘", "B"], group: 3,
                  enabled: canCreate, perform: { form(blocking: true) }),
            .init(id: "calendar-today", title: "回到今天", icon: "calendar", group: 4, perform: calendar.showToday),
            .init(id: "calendar-settings", title: "日历设置…", icon: "gearshape", group: 4,
                  perform: { [weak model] in model?.openSettings(page: settingsID) })
        ]
        if let event, event.editable {
            actions.append(.init(id: "delete-event", title: "删除日程", icon: "trash", keys: ["⇧", "⌘", "X"], group: 5,
                                 enabled: !calendar.saving, destructive: true, perform: { calendar.confirmDeletion(event) }))
        }
        return actions
    }

}
