import Foundation

public struct AgendaParticipant: Equatable, Sendable {
    public let name: String
    public let status: String

    public init(name: String, status: String) {
        self.name = name
        self.status = status
    }
}

public enum AgendaMeetingLink {
    private static let exactHosts: Set<String> = [
        "meet.google.com", "teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft",
        "meet.jit.si", "facetime.apple.com", "join.skype.com", "meet.goto.com",
        "meeting.tencent.com", "voovmeeting.com", "vc.feishu.cn", "vc.larkoffice.com",
        "vc.dingtalk.com", "telemost.yandex.ru"
    ]
    private static let providerDomains = [
        "zoom.us", "zoomgov.com", "webex.com", "bluejeans.com", "chime.aws", "whereby.com",
        "around.co", "chorus.ai", "riverside.fm", "streamyard.com", "gotomeeting.com"
    ]

    public static func matches(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil else { return false }
        switch url.scheme?.lowercased() {
        case "facetime", "facetime-audio", "skype":
            return !url.absoluteString.split(separator: ":", maxSplits: 1).dropFirst().joined().isEmpty
        case "https":
            guard let host = url.host?.lowercased() else { return false }
            let path = url.path.lowercased()
            if host == "slack.com" || host.hasSuffix(".slack.com") {
                return path.hasPrefix("/huddle/") || path.hasPrefix("/huddles/")
            }
            if host == "app.chime.aws" || host == "chime.aws" {
                return path != "" && path != "/"
            }
            return exactHosts.contains(host) || providerDomains.contains { host == $0 || host.hasSuffix("." + $0) }
        default:
            return false
        }
    }
}

public struct AgendaEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let calendarID: String
    public let calendarTitle: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let location: String
    public let notes: String
    public let calendarColor: UInt32?
    public let accepted: Bool
    public let meetingURL: URL?
    public let editable: Bool
    public let recurring: Bool
    public let busy: Bool
    public let nativeID: String
    public let externalID: String?
    public let participants: [AgendaParticipant]
    public let canInvite: Bool
    public let hasInvitation: Bool
    public let reminderMinutes: Set<Int>
    public let hasOtherReminders: Bool
    public init(id: String, calendarID: String, calendarTitle: String, title: String, start: Date, end: Date, allDay: Bool = false, location: String = "", notes: String = "", calendarColor: UInt32? = nil, accepted: Bool = false, meetingURL: URL? = nil, editable: Bool = false, recurring: Bool = false, busy: Bool = true,
                nativeID: String = "", externalID: String? = nil, participants: [AgendaParticipant] = [],
                canInvite: Bool = false, hasInvitation: Bool = false, reminderMinutes: Set<Int> = [],
                hasOtherReminders: Bool = false) {
        self.id = id; self.calendarID = calendarID; self.calendarTitle = calendarTitle; self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.notes = notes
        self.calendarColor = calendarColor; self.accepted = accepted
        self.meetingURL = meetingURL; self.editable = editable; self.recurring = recurring; self.busy = busy
        self.nativeID = nativeID
        self.externalID = externalID
        self.participants = participants
        self.canInvite = canInvite
        self.hasInvitation = hasInvitation
        self.reminderMinutes = reminderMinutes
        self.hasOtherReminders = hasOtherReminders
    }
}
public enum AgendaMenuTiming: Int, CaseIterable, Sendable {
    case always = -2, upcoming = -1
    case oneHour = 60, thirtyMinutes = 30, fifteenMinutes = 15, tenMinutes = 10
    case fiveMinutes = 5, twoMinutes = 2, atStart = 0, never = -3
}

public enum AgendaPolicy {
    public static func ordered(_ events: [AgendaEvent]) -> [AgendaEvent] {
        events.sorted { lhs, rhs in
            if lhs.allDay != rhs.allDay { return lhs.allDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.id < rhs.id
        }
    }
    public static func day(_ events: [AgendaEvent], date: Date, calendar: Calendar = .current) -> [AgendaEvent] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return ordered(events.filter { $0.start < end && ($0.end > start || ($0.start == $0.end && $0.start >= start)) })
    }
    public static func matching(_ events: [AgendaEvent], query: String) -> [AgendaEvent] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return events.filter { event in words.allSatisfy { (event.title + " " + event.location + " " + event.calendarTitle).localizedCaseInsensitiveContains($0) } }
    }
    public static func upcoming(_ events: [AgendaEvent], now: Date) -> [AgendaEvent] {
        ordered(events.filter { $0.end > now }).sorted { lhs, rhs in
            if lhs.allDay != rhs.allDay { return !lhs.allDay }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id < rhs.id
        }
    }
    public static func freeIntervals(in interval: DateInterval, events: [AgendaEvent]) -> [DateInterval] {
        var cursor = interval.start
        var free: [DateInterval] = []
        for event in events.filter(\.busy).sorted(by: { $0.start < $1.start }) {
            guard event.end > cursor, event.start < interval.end, event.end > event.start else { continue }
            if event.start > cursor { free.append(DateInterval(start: cursor, end: event.start)) }
            cursor = min(interval.end, event.end)
        }
        if cursor < interval.end { free.append(DateInterval(start: cursor, end: interval.end)) }
        return free
    }

    public static func nearStart(_ events: [AgendaEvent], now: Date, minutes: Int) -> [AgendaEvent] {
        guard minutes > 0 else { return [] }
        let threshold = TimeInterval(minutes) * 60
        return ordered(events.filter { !$0.allDay && abs($0.start.timeIntervalSince(now)) <= threshold })
    }

    public static func menuEvent(_ events: [AgendaEvent], now: Date, timing: AgendaMenuTiming, hideAfterMinutes: Int,
                                 meetingsOnly: Bool) -> AgendaEvent? {
        guard timing != .never else { return nil }
        return nextTimed(events.filter { event in
            (timing.rawValue < 0 || event.start <= now.addingTimeInterval(TimeInterval(timing.rawValue) * 60))
                && (hideAfterMinutes == 0 || now < event.start.addingTimeInterval(TimeInterval(hideAfterMinutes) * 60))
                && (!meetingsOnly || event.meetingURL != nil)
        }, now: now)
    }

    public static func nextTimed(_ events: [AgendaEvent], now: Date) -> AgendaEvent? { upcoming(events, now: now).first { !$0.allDay } }
}
