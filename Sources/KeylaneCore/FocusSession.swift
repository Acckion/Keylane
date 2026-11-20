import Foundation

public struct FocusSession: Codable, Equatable, Sendable {
    public var id = UUID()
    public var configuration: FocusConfiguration
    public let started: Date
    public private(set) var accumulated: TimeInterval = 0
    public private(set) var runningSince: Date?
    public private(set) var breakEnds: Date?
    public private(set) var snoozes: [String: Date] = [:]
    public var paused: Bool { runningSince == nil }

    public init(configuration: FocusConfiguration, now: Date) {
        self.configuration = configuration; started = now; runningSince = now
    }
    public func elapsed(at now: Date) -> TimeInterval {
        effectiveElapsed(at: now)
    }
    public func remaining(at now: Date) -> TimeInterval? {
        configuration.duration.map { max(0, $0 - effectiveElapsed(at: now)) }
    }
    public func effectiveElapsed(at now: Date) -> TimeInterval {
        accumulated + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }
    public mutating func pause(at now: Date, breakDuration: TimeInterval? = nil) {
        if let runningSince { accumulated += max(0, now.timeIntervalSince(runningSince)) }
        runningSince = nil
        breakEnds = breakDuration.map { now.addingTimeInterval($0) }
    }
    public mutating func resume(at now: Date) {
        guard paused else { return }
        runningSince = now; breakEnds = nil
    }
    public mutating func snooze(_ id: String, at now: Date, duration: TimeInterval) {
        snoozes[id] = now.addingTimeInterval(duration)
    }
    public func snoozed(_ id: String, at now: Date) -> Bool { (snoozes[id] ?? .distantPast) > now }
    public func snoozeKeys(at now: Date) -> [String] { snoozes.filter { $0.value > now }.map(\.key) }
    public mutating func expireSnoozes(at now: Date) { snoozes = snoozes.filter { $0.value > now } }
}

public enum FocusDuration {
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws -> TimeInterval? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["", "no limit", "无限", "不限"].contains(value) { return nil }
        var seconds: Double?
        if value.hasPrefix("until ") || value.hasPrefix("直到") {
            let clock = value.hasPrefix("until ") ? String(value.dropFirst(6)) : String(value.dropFirst(2))
            for pattern in ["H:mm", "ha", "h:mma"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = pattern
                formatter.isLenient = false
                if let parsed = formatter.date(from: clock.replacingOccurrences(of: " ", with: "")),
                   let target = calendar.nextDate(after: now, matching: calendar.dateComponents([.hour, .minute], from: parsed),
                                                 matchingPolicy: .nextTime) {
                    seconds = target.timeIntervalSince(now); break
                }
            }
        } else if value.contains(":") {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2, let hours = Double(parts[0]), let minutes = Double(parts[1]),
               hours >= 0, minutes >= 0, minutes < 60 { seconds = hours * 3600 + minutes * 60 }
        } else {
            let units: [(String, Double)] = [("小时", 3600), ("hours", 3600), ("hour", 3600), ("h", 3600),
                                            ("分钟", 60), ("minutes", 60), ("minute", 60), ("min", 60), ("m", 60)]
            if let (suffix, factor) = units.first(where: { value.hasSuffix($0.0) }) {
                seconds = Double(value.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)).map { $0 * factor }
            } else { seconds = Double(value).map { $0 * 60 } }
            if seconds == nil {
                let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*(?:h|hours?|小时)\s*([0-9]+(?:\.[0-9]+)?)\s*(?:m|min|minutes?|分钟)$"#
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(value.startIndex..., in: value)
                if let match = regex.firstMatch(in: value, range: range),
                   let hoursRange = Range(match.range(at: 1), in: value), let minutesRange = Range(match.range(at: 2), in: value),
                   let hours = Double(value[hoursRange]), let minutes = Double(value[minutesRange]), minutes < 60 {
                    seconds = hours * 3600 + minutes * 60
                }
            }
        }
        guard let seconds, seconds.isFinite, seconds >= 60, seconds <= 86400 else { throw FocusError.invalidDuration }
        return seconds
    }
}
