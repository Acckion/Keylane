import Foundation

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
    public init(id: String, calendarID: String, calendarTitle: String, title: String, start: Date, end: Date, allDay: Bool = false, location: String = "", notes: String = "", calendarColor: UInt32? = nil, accepted: Bool = false) {
        self.id = id; self.calendarID = calendarID; self.calendarTitle = calendarTitle; self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.location = location; self.notes = notes
        self.calendarColor = calendarColor; self.accepted = accepted
    }
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
    public static func nextTimed(_ events: [AgendaEvent], now: Date) -> AgendaEvent? { upcoming(events, now: now).first { !$0.allDay } }
}
