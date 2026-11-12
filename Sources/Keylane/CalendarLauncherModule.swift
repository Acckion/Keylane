import Combine
import KeylaneCore
import SwiftUI

enum CalendarLauncherModule {
    private static let commandID = CommandID(rawValue: "calendar")
    private static let pageID = PageID(rawValue: "Calendar")
    private static let settingsID = "calendar"

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
            )],
            pages: [.init(
                id: pageID, placeholder: "搜索日程…", badge: ("日历", "calendar"), actionTitle: "日历操作",
                contentPlacement: .underChrome,
                content: { AnyView(CalendarPage(controller: calendar)) },
                queryChanged: { calendar.updatePresentation(query: $0) },
                leave: { calendar.endPresentation() },
                move: { calendar.move($0) },
                submit: { calendar.openSystemCalendar() },
                primaryTitle: { "打开日历" },
                actions: { [weak model] in
                    [
                        .init(id: "open-calendar", title: "打开系统日历", icon: "calendar", perform: { calendar.openSystemCalendar() }),
                        .init(id: "calendar-today", title: "今天", icon: "clock", perform: { calendar.showToday() }),
                        .init(id: "calendar-refresh", title: "刷新日程", icon: "arrow.clockwise", perform: { calendar.refresh() }),
                        .init(id: "calendar-settings", title: "日历设置…", icon: "gearshape", perform: { [weak model] in model?.openSettings(page: settingsID) })
                    ]
                },
                searchAccessory: { AnyView(CalendarDateNavigation(controller: calendar)) }
            )],
            settings: [.init(
                id: settingsID, title: "日历", symbol: "calendar", subtitle: "查看日程和会议。", order: 50,
                items: SettingsItem.all.filter { $0.page == settingsID },
                titlebar: calendar.permission.titlebar("启用日历"),
                content: { [weak model] in
                    guard let model else { return AnyView(EmptyView()) }
                    return AnyView(CalendarPreferences(model: model))
                }
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
                    calendar.start()
                },
                stop: {
                    calendar.stop()
                    calendar.reveal = nil
                    calendar.showSettings = nil
                }
            )],
            searchUpdates: [calendar.permission.updates],
            canDisable: true
        )
    }
}
