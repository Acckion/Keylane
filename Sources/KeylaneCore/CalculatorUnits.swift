import Foundation

struct CalculatorUnits {
    let locale: Locale
    let pixelsPerEm: Double

    struct Unit {
        var scale: Double
        var powers: [String: Int]

        init(_ scale: Double, _ powers: [String: Int]) {
            self.scale = scale
            self.powers = powers
        }

        init(_ powers: [String: Int]) { self.init(1, powers) }

        func multiplied(by other: Unit, exponent: Int = 1) -> Unit {
            var combined = powers
            for (key, value) in other.powers { combined[key, default: 0] += value * exponent }
            return Unit(scale * pow(other.scale, Double(exponent)), combined.filter { $0.value != 0 })
        }

        var label: String {
            let order = ["kg", "m", "s", "A", "bit"]
            func term(_ key: String, _ exponent: Int) -> String {
                exponent == 1 ? key : key + "^" + String(exponent)
            }
            let terms = order.compactMap { key in powers[key].flatMap { $0 > 0 ? term(key, $0) : nil } }
            let inverse = order.compactMap { key in powers[key].flatMap { $0 < 0 ? term(key, -$0) : nil } }
            if inverse.isEmpty { return terms.joined(separator: "·") }
            return (terms.isEmpty ? "1" : terms.joined(separator: "·")) + "/" + inverse.joined(separator: "·")
        }
    }

    private static let conversion = CalculationPattern(#"(.+?)\s+(?:in|to)\s+(.+?)(?:\s+at\s+([\d.,]+)\s*(?:ppi|dpi))?"#)
    private static let transfer = CalculationPattern(#"transfer\s+(.+?)\s+at\s+(.+)"#)
    private static let compound = CalculationPattern(#"(.+?)\s+([*/×÷])\s+(.+)"#)
    private static let quantity = CalculationPattern(#"([+\-−]?(?:\d+(?:[.,]\d+)?|[.,]\d+)(?:[eE][+\-]?\d+)?)\s*(\S.*?)"#)
    private static let timePair = CalculationPattern(#"([+\-−]?\d+(?:[.,]\d+)?)\s*(?:h|hr|hours?)\s*(\d+(?:[.,]\d+)?)\s*(?:m|min|minutes?)"#)
    private static let pace = CalculationPattern(#"(\d+):(\d{2})\s*(?:min|minutes?)\s*/\s*(km|mi|mile)"#)
    private static let note = CalculationPattern(#"([a-g])([#♯b♭]?)(-?\d)\s+(?:to|in)\s+hz"#)
    private static let height = CalculationPattern(#"([+\-−]?\d+)\s*['′’]\s*(\d+(?:[.,]\d+)?)\s*["″”]"#)
    private static let workHours = CalculationPattern(#"workhours\s+in\s+(\d{4})"#)
    private static let unitFunction = CalculationPattern(#"(min|max|sum|avg|mean)\s*\((.+)\)"#)

    private static let values: [String: Unit] = {
        let entries: [(Double, [String: Int], [String])] = [
            (1, ["m": 1], ["m", "meter", "meters"]),
            (1e3, ["m": 1], ["km", "kilometer", "kilometers"]),
            (0.01, ["m": 1], ["cm"]), (0.001, ["m": 1], ["mm"]), (1e-6, ["m": 1], ["µm", "μm", "um"]), (1e-9, ["m": 1], ["nm"]),
            (0.0254, ["m": 1], ["in", "inch", "inches"]), (0.3048, ["m": 1], ["ft", "foot", "feet"]),
            (0.9144, ["m": 1], ["yd", "yard", "yards"]), (1609.344, ["m": 1], ["mi", "mile", "miles"]),
            (20.1168, ["m": 1], ["chain", "chains"]), (1852, ["m": 1], ["nmi", "nautical mile", "nautical miles"]),
            (149_597_870_700, ["m": 1], ["au", "astronomical unit", "astronomical units"]),
            (1, ["kg": 1], ["kg"]), (0.001, ["kg": 1], ["g"]), (1e-6, ["kg": 1], ["mg"]),
            (0.45359237, ["kg": 1], ["lb", "lbs", "pound", "pounds"]),
            (0.028349523125, ["kg": 1], ["oz", "ounce", "ounces"]),
            (1_000, ["kg": 1], ["tonne", "tonnes"]),
            (1, ["s": 1], ["s", "sec", "second", "seconds"]), (0.001, ["s": 1], ["ms"]),
            (60, ["s": 1], ["min", "mins", "minute", "minutes"]), (3600, ["s": 1], ["h", "hr", "hrs", "hour", "hours"]),
            (86400, ["s": 1], ["day", "days", "d"]), (604800, ["s": 1], ["week", "weeks"]),
            (1_209_600, ["s": 1], ["fortnight", "fortnights"]), (28800, ["s": 1], ["workday", "workdays"]),
            (0.001, ["m": 3], ["l", "liter", "liters", "litre", "litres"]),
            (0.000001, ["m": 3], ["ml", "milliliter", "milliliters", "millilitres"]),
            (0.003785411784, ["m": 3], ["gal", "us gallon", "gallon", "gallons"]),
            (0.00024, ["m": 3], ["us legal cup", "us legal cups"]),
            (0.0002365882365, ["m": 3], ["us cup", "cup", "cups"]),
            (0.0000295735295625, ["m": 3], ["fl oz", "fluid ounce", "fluid ounces"]),
            (0.003785411784 / 60, ["m": 3, "s": -1], ["gpm"]),
            (10_000, ["m": 2], ["ha", "hectare", "hectares"]), (4046.8564224, ["m": 2], ["acre", "acres"]),
            (1, ["kg": 1, "m": 1, "s": -2], ["n", "newton", "newtons"]),
            (1, ["kg": 1, "m": -1, "s": -2], ["pa", "pascal", "pascals"]),
            (1000, ["kg": 1, "m": -1, "s": -2], ["kpa"]), (101325, ["kg": 1, "m": -1, "s": -2], ["atm"]),
            (1, ["kg": 1, "m": 2, "s": -2], ["j", "joule", "joules"]),
            (1000, ["kg": 1, "m": 2, "s": -2], ["kj"]), (4.184, ["kg": 1, "m": 2, "s": -2], ["cal"]),
            (1, ["kg": 1, "m": 2, "s": -3], ["w", "watt", "watts"]), (1e3, ["kg": 1, "m": 2, "s": -3], ["kw"]),
            (1, ["s": -1], ["hz"]), (1e3, ["s": -1], ["khz"]), (1e6, ["s": -1], ["mhz"]), (1e9, ["s": -1], ["ghz"]),
            (1, ["bit": 1], ["bit", "bits"]), (4, ["bit": 1], ["nibble", "nibbles"]), (8, ["bit": 1], ["byte", "bytes", "B"]),
            (1609.344 / 3600, ["m": 1, "s": -1], ["mph"]), (1000.0 / 3600, ["m": 1, "s": -1], ["kph"]),
            (1852.0 / 3600, ["m": 1, "s": -1], ["kn", "knot", "knots"]),
            (299_792_458, ["m": 1, "s": -1], ["speed of light"]),
            (6.62607015e-34, ["kg": 1, "m": 2, "s": -1], ["planck constant"]),
            (9.80665, ["m": 1, "s": -2], ["standard gravity"])
        ]
        var map = Dictionary(uniqueKeysWithValues: entries.flatMap { scale, powers, names in
            names.map { ($0, Unit(scale, powers)) }
        })
        for (index, prefix) in ["K", "M", "G", "T"].enumerated() {
            let magnitude = Double(index + 1)
            for (suffix, factor) in [("B", 8.0), ("b", 1)] {
                map[prefix + suffix] = Unit(factor * pow(1000, magnitude), ["bit": 1])
                map[prefix + "i" + suffix] = Unit(factor * pow(1024, magnitude), ["bit": 1])
                map[prefix + suffix + "ps"] = Unit(factor * pow(1000, magnitude), ["bit": 1, "s": -1])
            }
        }
        return map
    }()

    func evaluate(_ raw: String, lowercased text: String) -> String? {
        if let mass = CalculatorChemistry.evaluate(raw, locale: locale) { return mass }
        if let match = Self.note.captures(text), let octave = Int(match[2]),
           let index = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11][match[0]] {
            let accidental = match[1].isEmpty ? 0 : (#"#♯"#.contains(match[1]) ? 1 : -1)
            return answer(440 * pow(2, Double(octave * 12 + index + accidental - 57) / 12), "Hz")
        }
        if let match = Self.workHours.captures(text), let year = Int(match[0]), let count = CalculatorDates.weekdays(in: year) {
            return answer(Double(count * 8), "h")
        }
        if let match = Self.transfer.captures(raw), let amount = quantity(match[0]), let speed = quantity(match[1]),
           amount.unit.powers == ["bit": 1], speed.unit.powers == ["bit": 1, "s": -1],
           amount.base >= 0, speed.base > 0 { return duration(amount.base / speed.base) }
        if let match = Self.unitFunction.captures(raw), let value = unitFunction(match[0].lowercased(), arguments: match[1]) { return value }
        if let match = Self.conversion.captures(raw), let result = convert(match[0], to: match[1], ppi: match[2]) { return result }
        if let match = Self.compound.captures(raw), let result = multiply(match[0], match[1], match[2]) {
            return answer(result.base, result.unit.label)
        }
        return nil
    }

    static func exactAmount(_ value: Double, from: String, to: String) -> Double? {
        let engine = Self(locale: Locale(identifier: "en_US_POSIX"), pixelsPerEm: 16)
        guard let source = engine.unit(from), let target = engine.unit(to), source.powers == target.powers else { return nil }
        return value * (source.scale / target.scale)
    }

    static func ratio(_ lhs: String, _ rhs: String, locale: Locale) -> Double? {
        let engine = Self(locale: locale, pixelsPerEm: 16)
        guard let a = engine.quantity(lhs), let b = engine.quantity(rhs), a.unit.powers == b.unit.powers, b.base != 0 else { return nil }
        return a.base / b.base
    }

    private func convert(_ input: String, to target: String, ppi: String) -> String? {
        let lower = target.lowercased()
        if lower == "years and months", let match = Self.quantity.captures(input),
           ["month", "months"].contains(match[1].lowercased()), let value = number(match[0]),
           let months = Int(exactly: value), months.magnitude < 1_000_000_000 {
            return "\(months / 12) y \(months % 12) mo"
        }
        if lower == "px" || lower == "rem" || lower == "em" {
            guard let from = Self.quantity.captures(input), let value = number(from[0]) else { return nil }
            let source = from[1].lowercased()
            if ["px", "em", "rem"].contains(source), ppi.isEmpty, pixelsPerEm > 0 {
                return answer(value * (source == "px" ? 1 : pixelsPerEm) / (lower == "px" ? 1 : pixelsPerEm), lower)
            }
            if lower == "px", let resolution = number(ppi), resolution > 0,
               let size = quantity(input), size.unit.powers == ["m": 1] { return answer(size.base / 0.0254 * resolution, lower) }
        }
        if !ppi.isEmpty { return nil }
        if let conversion = CalculatorMinorCurrency.convert(input, to: target, locale: locale) { return conversion }
        if lower == "watts" || lower == "w", let parts = Self.quantity.captures(input),
           parts[1].lowercased() == "dbm", let level = number(parts[0]) { return answer(pow(10, level / 10) / 1000, "W") }
        if let parts = Self.quantity.captures(input), ["rankine", "°r"].contains(parts[1].lowercased()),
           let degrees = number(parts[0]), degrees >= 0 {
            let kelvin = degrees * 5 / 9
            switch lower {
            case "c", "°c", "celsius": return answer(kelvin - 273.15, "°C")
            case "f", "°f", "fahrenheit": return answer(degrees - 459.67, "°F")
            case "k", "kelvin": return answer(kelvin, "K")
            default: break
            }
        }
        guard let source = quantity(input) ?? Self.compound.captures(input).flatMap({ multiply($0[0], $0[1], $0[2]) }) else { return nil }
        if ["mixed", "timespan"].contains(lower), source.unit.powers == ["s": 1] { return duration(source.base) }
        guard let destination = unit(target), source.unit.powers == destination.powers else { return nil }
        return answer(source.base / destination.scale, target)
    }

    private func unitFunction(_ name: String, arguments: String) -> String? {
        let separator = locale.decimalSeparator == "," && arguments.contains(";") ? ";" : ","
        let parts = arguments.split(separator: Character(separator), omittingEmptySubsequences: false)
        let quantities = parts.compactMap { quantity($0.trimmingCharacters(in: .whitespaces)) }
        guard let first = quantities.first, quantities.count == parts.count,
              quantities.allSatisfy({ $0.unit.powers == first.unit.powers }) else { return nil }
        let values = quantities.map(\.base)
        let total: Double
        switch name {
        case "min": total = values.min()!
        case "max": total = values.max()!
        case "avg", "mean": total = values.reduce(0, +) / Double(values.count)
        default: total = values.reduce(0, +)
        }
        return first.unit.powers == ["s": 1] ? duration(total) : answer(total, first.unit.label)
    }

    private func multiply(_ left: String, _ operation: String, _ right: String) -> (base: Double, unit: Unit)? {
        guard let a = quantity(left), let b = quantity(right) else { return nil }
        let division = operation == "/" || operation == "÷"
        guard !division || b.base != 0 else { return nil }
        return (division ? a.base / b.base : a.base * b.base, a.unit.multiplied(by: b.unit, exponent: division ? -1 : 1))
    }

    private func quantity(_ text: String) -> (base: Double, unit: Unit)? {
        let lower = text.lowercased()
        if let unit = Self.values[lower], lower.count > 5 { return (unit.scale, unit) }
        if let match = Self.timePair.captures(text), let hours = number(match[0]), let minutes = number(match[1]) {
            return ((abs(hours) * 3600 + minutes * 60) * (match[0].hasPrefix("-") || match[0].hasPrefix("−") ? -1 : 1), Unit(["s": 1]))
        }
        if let match = Self.pace.captures(text), let min = Double(match[0]), let sec = Double(match[1]), sec < 60,
           min > 0 || sec > 0 {
            return ((match[2].lowercased() == "km" ? 1000 : 1609.344) / (min * 60 + sec), Unit(["m": 1, "s": -1]))
        }
        if let match = Self.height.captures(text), let feet = number(match[0]), let inches = number(match[1]) {
            let sign: Double = match[0].hasPrefix("-") || match[0].hasPrefix("−") ? -1 : 1
            return ((abs(feet) * 0.3048 + inches * 0.0254) * sign, Unit(["m": 1]))
        }
        guard let match = Self.quantity.captures(text), let value = number(match[0]), let unit = unit(match[1]) else { return nil }
        return (value * unit.scale, unit)
    }

    private func unit(_ token: String) -> Unit? {
        if let direct = Self.values[token] ?? Self.values[token.lowercased()] { return direct }
        let normalized = token.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "·", with: "*")
            .replacingOccurrences(of: "²", with: "^2").replacingOccurrences(of: "³", with: "^3")
        let divisions = normalized.split(separator: "/", omittingEmptySubsequences: false)
        var unit = Unit([:])
        for (index, division) in divisions.enumerated() {
            for part in division.split(separator: "*", omittingEmptySubsequences: false) {
                let terms = part.split(separator: "^", omittingEmptySubsequences: false)
                guard (1...2).contains(terms.count), let name = terms.first.map(String.init),
                      let value = Self.values[name] ?? Self.values[name.lowercased()],
                      let exponent = terms.count == 2 ? Int(terms[1]) : 1, (-12...12).contains(exponent) else { return nil }
                unit = unit.multiplied(by: value, exponent: index == 0 ? exponent : -exponent)
            }
        }
        return normalized.isEmpty ? nil : unit
    }

    private func number(_ text: String) -> Double? { Calculator.evaluate(text, locale: locale) }

    private func answer(_ value: Double, _ unit: String) -> String? {
        guard value.isFinite else { return nil }
        return Calculator.format(value, locale: locale) + (unit.isEmpty ? "" : " " + unit)
    }

    private func duration(_ seconds: Double) -> String? { Self.duration(seconds, locale: locale) }

    static func duration(_ seconds: Double, locale: Locale) -> String? {
        guard seconds.isFinite, abs(seconds) < 1e13 else { return nil }
        var remainder = abs(seconds)
        var parts: [String] = []
        for (label, step) in [("d", 86400.0), ("h", 3600), ("min", 60)] {
            let count = Int(remainder / step)
            if count > 0 { parts.append("\(count) \(label)"); remainder -= Double(count) * step }
        }
        if remainder > 1e-9 || parts.isEmpty { parts.append(Calculator.format(remainder, locale: locale) + " s") }
        return (seconds < 0 ? "-" : "") + parts.joined(separator: " ")
    }
}

enum CalculatorMinorCurrency {
    private static let amount = CalculationPattern(#"(.+?)\s*(usd|eur|gbp|cad|aud|dollars?|euros?|pounds?|cents?|euro cents?|pence)"#)

    static func convert(_ input: String, to target: String, locale: Locale) -> String? {
        guard let match = amount.captures(input), let value = Calculator.evaluate(match[0], locale: locale) else { return nil }
        let target = target.lowercased()
        let source = match[1].lowercased()
        let localDollar = ["CAD", "AUD", "NZD", "SGD", "HKD"].contains(locale.currency?.identifier ?? "") ? locale.currency!.identifier.lowercased() : "usd"
        // Explicit supported ISO codes are unambiguous in every locale.
        // The local currency only supplies the default for generic dollar names.
        let defaults: [(Set<String>, Set<String>)] = [
            (["usd", "cad", "aud", localDollar, "dollar", "dollars"], ["cent", "cents"]),
            (["eur", "euro", "euros"], ["euro cent", "euro cents", "cent", "cents"]),
            (["gbp", "pound", "pounds"], ["pence"])
        ]
        for (major, minor) in defaults {
            if major.contains(source), minor.contains(target) { return Calculator.format(value * 100, locale: locale) + " " + target }
            if minor.contains(source), major.contains(target) { return Calculator.format(value / 100, locale: locale) + " " + target }
        }
        return nil
    }
}
