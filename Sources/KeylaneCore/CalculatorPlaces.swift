import CoreLocation
import Foundation

enum CalculatorPlaces {
    private static let distance = CalculationPattern(#"distance\s+(?:from\s+(.+?)\s+to\s+(.+?)|between\s+(.+?)\s+and\s+(.+?))(?:\s+in\s+(km|mi|miles|meters|metres))?"#)

    static func evaluate(_ text: String, locale: Locale) -> String? {
        guard text.hasPrefix("distance "), let fields = distance.captures(text),
              let first = locations[fold(fields[0].isEmpty ? fields[2] : fields[0])],
              let second = locations[fold(fields[1].isEmpty ? fields[3] : fields[1])] else { return nil }
        let unit = fields[4]
        let meters = first.distance(from: second)
        let value: Double
        let label: String
        switch unit {
        case "mi", "miles": value = meters / 1609.344; label = "mi"
        case "meters", "metres": value = meters; label = "m"
        default: value = meters / 1000; label = "km"
        }
        return Calculator.format((value * 100).rounded() / 100, locale: locale) + " " + label
    }

    // Representative cities from macOS's IANA zone table. Aliases only refer to
    // the same location, not other cities or airports that happen to share a zone.
    private static let locations: [String: CLLocation] = {
        var table: [String: CLLocation] = [:]
        if let data = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) {
            for line in data.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
                let fields = line.split(separator: "\t")
                guard fields.count >= 3, let point = coordinate(fields[1]),
                      let city = fields[2].split(separator: "/").last else { continue }
                table[fold(String(city))] = point
                table[fold(String(fields[2]))] = point
            }
        }
        table["ldn"] = table["london"]
        table["nyc"] = table["new york"]
        // Bibliothèque nationale de France, ark:/12148/cb15274315g.
        let chamonix = CLLocation(latitude: 45 + 55.0 / 60 + 17.0 / 3600,
                                  longitude: 6 + 51.0 / 60 + 47.0 / 3600)
        table["chamonix"] = chamonix
        table["chamonix-mont-blanc"] = chamonix
        return table
    }()

    private static func coordinate(_ token: Substring) -> CLLocation? {
        guard let boundary = token.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }),
              let lat = angle(token[..<boundary], degrees: 2),
              let lon = angle(token[boundary...], degrees: 3),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return CLLocation(latitude: lat, longitude: lon)
    }

    private static func angle(_ token: Substring, degrees: Int) -> Double? {
        let digits = token.dropFirst()
        guard digits.count == degrees + 2 || digits.count == degrees + 4,
              let whole = Double(digits.prefix(degrees)),
              let minutes = Double(digits.dropFirst(degrees).prefix(2)), minutes < 60 else { return nil }
        let seconds = digits.count == degrees + 4 ? (Double(digits.suffix(2)) ?? 0) : 0
        return (token.hasPrefix("-") ? -1 : 1) * (whole + minutes / 60 + seconds / 3600)
    }

    private static func fold(_ input: String) -> String {
        input.replacingOccurrences(of: "_", with: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
