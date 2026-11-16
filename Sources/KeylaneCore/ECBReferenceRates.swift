import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct ECBReferenceRates: Codable {
    public let date: String
    public let rates: [String: Double]

    public init?(xml: Data) {
        let delegate = RateXML()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse(), let date = delegate.date, Self.publicationDay(date) != nil,
              !delegate.rates.isEmpty else { return nil }
        self.date = date
        self.rates = delegate.rates.merging(["EUR": 1]) { _, base in base }
    }

    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard amount.isFinite, let source = rates[from], let target = rates[to],
              source.isFinite, target.isFinite, source > 0, target > 0 else { return nil }
        if from == to || amount == 0 { return amount }
        let base = amount / source
        let result = base * target
        if base != 0, result.isFinite { return result }
        let ratio = target / source
        let converted = amount * ratio
        return ratio > 0 && converted.isFinite ? converted : nil
    }

    /// Calendar days in the publisher's timezone. Allow a normal weekend between releases.
    public func isStale(at now: Date = Date()) -> Bool {
        guard let day = Self.publicationDay(date) else { return true }
        return (Self.calendar.dateComponents([.day], from: day, to: Self.calendar.startOfDay(for: now)).day ?? 0) > 3
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        return calendar
    }

    private static func publicationDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }
}

private final class RateXML: NSObject, XMLParserDelegate {
    var date: String?
    var rates: [String: Double] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        guard elementName == "Cube" else { return }
        if let time = attributes["time"] { date = time }
        if let code = attributes["currency"], let raw = attributes["rate"], let value = Double(raw),
           value.isFinite, value > 0 {
            rates[code] = value
        }
    }
}
