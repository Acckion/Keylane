import Foundation

struct CalculatorDates {
    let now: Date
    let timeZone: TimeZone
    let locale: Locale

    private static let week = CalculationPattern(#"week\s+(\d{1,2})\s+(\d{4})"#)
    private static let remaining = CalculationPattern(#"(days|workdays|hours)\s+left\s+in\s+(?:this\s+)?(today|day|week|month|quarter|year)"#)
    private static let relativeDays = CalculationPattern(#"days\s+(until|since)\s+(.+)"#)
    private static let explicitYear = CalculationPattern(#".*\b\d{4}\b.*"#)
    private static let weekday = CalculationPattern(#"(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\s+in\s+(\d+)\s+weeks?"#)
    private static let clockShift = CalculationPattern(#"time(?:\s+in\s+(.+?))?\s*([+\-])\s*(\d+(?:[.,]\d+)?)\s*(hours?|h|minutes?|min|seconds?|s)?"#)
    private static let futureClock = CalculationPattern(#"time\s+in\s+(\d+(?:[.,]\d+)?)\s*(hours?|h|minutes?|min|seconds?|s)(?:\s+in\s+(.+))?"#)
    private static let otherClock = CalculationPattern(#"time\s+in\s+(.+)"#)
    private static let zoneDifference = CalculationPattern(#"(?:time\s+)?diff\s+(.+)"#)
    private static let clockConversion = CalculationPattern(#"(\d{1,2}(?::\d{2})?(?:\s*[ap]m)?)\s+(.+?)\s+in\s+(.+)"#)
    private static let clockRange = CalculationPattern(#"(\d{1,2}(?::\d{2})\s*(?:[ap]m)?|\d{1,2}\s*[ap]m)\s+to\s+(\d{1,2}(?::\d{2})\s*(?:[ap]m)?|\d{1,2}\s*[ap]m)"#)
    private static let dateShift = CalculationPattern(#"(.+?)\s*([+\-])\s*(\d+)\s*(days?|weeks?|months?|years?|hours?|minutes?)?"#)
    private static let unix = CalculationPattern(#"from\s+(-?\d{9,12})\s+to\s+(-?\d{9,12})"#)
    private static let clock = CalculationPattern(#"(\d{1,2})(?::(\d{2}))?\s*([ap]m)?"#)
    private static let isoTimestamp = CalculationPattern(#"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+\-]\d{2}:\d{2})"#)

    private static let zoneNames: [String: String] = {
        var names: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers.sorted() {
            names[identifier.lowercased()] = identifier
            if let city = identifier.split(separator: "/").last {
                names[Self.fold(String(city).replacingOccurrences(of: "_", with: " "))] = identifier
            }
        }
        return names.merging([
            "utc": "Etc/UTC", "gmt": "Etc/UTC", "z": "Etc/UTC",
            "ldn": "Europe/London", "lhr": "Europe/London", "paris": "Europe/Paris",
            "chamonix": "Europe/Paris", "cdg": "Europe/Paris",
            "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "sfo": "America/Los_Angeles",
            "nyc": "America/New_York", "jfk": "America/New_York", "ewr": "America/New_York",
            "pt": "America/Los_Angeles", "et": "America/New_York", "ct": "America/Chicago", "mt": "America/Denver",
            "beijing": "Asia/Shanghai", "北京": "Asia/Shanghai", "上海": "Asia/Shanghai", "东京": "Asia/Tokyo",
            "pvg": "Asia/Shanghai", "pek": "Asia/Shanghai", "hnd": "Asia/Tokyo", "nrt": "Asia/Tokyo",
            "singapore": "Asia/Singapore", "sin": "Asia/Singapore", "hkg": "Asia/Hong_Kong",
            "syd": "Australia/Sydney", "bne": "Australia/Brisbane", "dxb": "Asia/Dubai"
        ], uniquingKeysWith: { _, alias in alias })
    }()

    func evaluate(_ text: String, original: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        switch text {
        case "now", "time": return timestamp(now, zone: timeZone)
        case "today", "今天": return date(today)
        case "tomorrow", "明天": return calendar.date(byAdding: .day, value: 1, to: today).map(date)
        case "yesterday", "昨天": return calendar.date(byAdding: .day, value: -1, to: today).map(date)
        default: break
        }
        if Self.isoTimestamp.captures(text) != nil {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = original.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
            let iso = original.replacingOccurrences(of: "t", with: "T").replacingOccurrences(of: "z", with: "Z")
            return formatter.date(from: iso).map { timestamp($0, zone: timeZone) }
        }
        if let fields = Self.week.captures(text), let week = Int(fields[0]), let year = Int(fields[1]), (1...53).contains(week) {
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = timeZone
            guard let monday = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)),
                  iso.component(.weekOfYear, from: monday) == week,
                  iso.component(.yearForWeekOfYear, from: monday) == year,
                  let sunday = iso.date(byAdding: .day, value: 6, to: monday) else { return nil }
            return date(monday) + " – " + date(sunday)
        }
        if let fields = Self.weekday.captures(text), let weeks = Int(fields[1]), weeks < 5200,
           let weekday = Self.weekdays.firstIndex(of: fields[0]) {
            var iso = Calendar(identifier: .iso8601)
            iso.timeZone = timeZone
            if let beginning = iso.dateInterval(of: .weekOfYear, for: today)?.start {
                let day = (weekday + 6) % 7
                return iso.date(byAdding: .day, value: weeks * 7 + day, to: beginning).map(date)
            }
        }
        if let fields = Self.remaining.captures(text), let end = periodEnd(fields[1], calendar: calendar) {
            switch fields[0] {
            case "hours": return Calculator.format(end.timeIntervalSince(now) / 3600, locale: locale) + " h"
            case "workdays": return "\(Self.countWeekdays(from: today, to: end, calendar: calendar)) 工作日"
            default: return "\(calendar.dateComponents([.day], from: today, to: end).day ?? 0) 天"
            }
        }
        if let fields = Self.relativeDays.captures(text), var target = parseDate(fields[1], calendar: calendar) {
            let until = fields[0] == "until"
            if Self.explicitYear.captures(fields[1]) == nil, !["today", "tomorrow", "yesterday"].contains(fields[1]) {
                if until && target < today { target = calendar.date(byAdding: .year, value: 1, to: target) ?? target }
                if !until && target > today { target = calendar.date(byAdding: .year, value: -1, to: target) ?? target }
            }
            let days = calendar.dateComponents([.day], from: until ? today : target, to: until ? target : today).day ?? 0
            return "\(days) 天"
        }
        if let fields = Self.futureClock.captures(text),
           let value = Calculator.evaluate(fields[0], locale: locale), let destination = zone(fields[2]) {
            return shifted(now, by: value, unit: fields[1], zone: destination)
        }
        if let fields = Self.clockShift.captures(text),
           let value = Calculator.evaluate(fields[2], locale: locale), let destination = zone(fields[0]) {
            return shifted(now, by: fields[1] == "-" ? -value : value, unit: fields[3], zone: destination)
        }
        if let fields = Self.otherClock.captures(text), let destination = zone(fields[0]) {
            return timestamp(now, zone: destination)
        }
        if let fields = Self.zoneDifference.captures(text), let destination = zone(fields[0]) {
            let hours = Double(destination.secondsFromGMT(for: now) - timeZone.secondsFromGMT(for: now)) / 3600
            return (hours > 0 ? "+" : "") + Calculator.format(hours, locale: locale) + " h"
        }
        if let fields = Self.clockRange.captures(text), let start = clockSeconds(fields[0]), let end = clockSeconds(fields[1]) {
            return CalculatorUnits.duration(Double((end - start + 86400) % 86400), locale: locale)
        }
        if let fields = Self.unix.captures(text), let start = Double(fields[0]), let end = Double(fields[1]) {
            return CalculatorUnits.duration(end - start, locale: locale)
        }
        if let fields = Self.clockConversion.captures(text), let seconds = clockSeconds(fields[0]),
           let source = zone(fields[1]), let destination = zone(fields[2]) {
            calendar.timeZone = source
            guard let moment = calendar.date(bySettingHour: seconds / 3600, minute: (seconds % 3600) / 60, second: 0, of: now) else { return nil }
            return timestamp(moment, zone: destination)
        }
        if let fields = Self.dateShift.captures(text), let count = Int(fields[2]), count < 10_000 {
            let offset = fields[1] == "-" ? -count : count
            if let seconds = clockSeconds(fields[0]), fields[0].contains(where: { $0 == ":" || $0.isLetter }),
               let clock = calendar.date(bySettingHour: seconds / 3600, minute: (seconds % 3600) / 60, second: 0, of: now),
               fields[3].isEmpty || fields[3].hasPrefix("hour") || fields[3].hasPrefix("minute") {
                return shifted(clock, by: Double(offset), unit: fields[3], zone: timeZone)
            }
            if let base = parseDate(fields[0], calendar: calendar) {
                let unit = fields[3].trimmingCharacters(in: CharacterSet(charactersIn: "s"))
                let component = ["week": Calendar.Component.weekOfYear, "day": .day, "": .day,
                                 "month": .month, "year": .year, "hour": .hour, "minute": .minute][unit]
                return component.flatMap { calendar.date(byAdding: $0, value: offset, to: base) }.map {
                    unit == "hour" || unit == "minute" ? timestamp($0, zone: timeZone) : date($0)
                }
            }
        }
        return nil
    }

    static func weekdays(in year: Int) -> Int? {
        guard (1...9999).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(byAdding: .year, value: 1, to: start) else { return nil }
        return countWeekdays(from: start, to: end, calendar: calendar)
    }

    private static func countWeekdays(from start: Date, to end: Date, calendar: Calendar) -> Int {
        let total = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        guard total > 0 else { return 0 }
        let startIndex = calendar.component(.weekday, from: start) - 1
        return total / 7 * 5 + (0..<(total % 7)).filter { (1...5).contains((startIndex + $0) % 7) }.count
    }

    private func periodEnd(_ period: String, calendar: Calendar) -> Date? {
        if period == "quarter" {
            guard let month = calendar.dateInterval(of: .month, for: now)?.start else { return nil }
            return calendar.date(byAdding: .month, value: 3 - (calendar.component(.month, from: now) - 1) % 3, to: month)
        }
        let component = ["today": Calendar.Component.day, "day": .day, "week": .weekOfYear, "month": .month, "year": .year][period]
        return component.flatMap { calendar.dateInterval(of: $0, for: now)?.end }
    }

    private func clockSeconds(_ input: String) -> Int? {
        guard let fields = Self.clock.captures(input), var hour = Int(fields[0]) else { return nil }
        let minute = Int(fields[1]) ?? 0
        guard minute < 60 else { return nil }
        if !fields[2].isEmpty {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (fields[2] == "pm" ? 12 : 0)
        }
        guard (0..<24).contains(hour) else { return nil }
        return hour * 3600 + minute * 60
    }

    private func parseDate(_ input: String, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        if input == "today" { return today }
        if input == "tomorrow" || input == "yesterday" {
            return calendar.date(byAdding: .day, value: input == "tomorrow" ? 1 : -1, to: today)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.defaultDate = calendar.date(from: DateComponents(year: calendar.component(.year, from: now), month: 1, day: 1))
        for format in ["yyyy-MM-dd", "MMMM d yyyy", "MMMM d, yyyy", "d MMMM yyyy", "MMMM d", "d MMMM", "MMMM"] {
            formatter.dateFormat = format
            if let value = formatter.date(from: input) { return value }
        }
        return nil
    }

    private func zone(_ input: String) -> TimeZone? {
        if input.isEmpty || input == "here" { return timeZone }
        if let zone = Self.zoneNames[Self.fold(input)].flatMap(TimeZone.init(identifier:)) { return zone }
        let offsets = ["pst": -8, "pdt": -7, "est": -5, "edt": -4, "jst": 9, "cet": 1, "cest": 2]
        return offsets[input].flatMap { TimeZone(secondsFromGMT: $0 * 3600) }
    }

    private func shifted(_ base: Date, by amount: Double, unit: String, zone: TimeZone) -> String? {
        let seconds = amount * (unit.hasPrefix("min") ? 60 : unit.hasPrefix("s") ? 1 : 3600)
        guard seconds.isFinite, abs(seconds) < 3.2e10 else { return nil }
        return timestamp(base.addingTimeInterval(seconds), zone: zone)
    }

    private func date(_ value: Date) -> String { format(value, zone: timeZone, includesTime: false) }
    private func timestamp(_ value: Date, zone: TimeZone) -> String {
        format(value, zone: zone, includesTime: true) + " " + (zone.abbreviation(for: value) ?? zone.identifier)
    }
    private func format(_ value: Date, zone: TimeZone, includesTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateStyle = .medium
        formatter.timeStyle = includesTime ? .short : .none
        return formatter.string(from: value)
    }
    private static func fold(_ input: String) -> String {
        input.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
}
