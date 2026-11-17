import Foundation

public enum CalculatorLanguage {
    private static let isoDateOffset = CalculationPattern(#"\d{4}-\d{2}-\d{2}\s*[+\-]\s*\d+\s*(?:days?|weeks?|months?|years?|hours?|minutes?)?"#)

    public static func evaluate(_ query: String, locale: Locale = .current, pixelsPerEm: Double = 16,
                                now: Date = .now, timeZone: TimeZone = .current) -> String? {
        guard query.utf16.count <= 512 else { return nil }
        let folded = query.folding(options: .widthInsensitive, locale: locale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = folded.hasPrefix("=") ? folded.dropFirst().trimmingCharacters(in: .whitespaces) : folded
        // An explicit ISO date with an offset is also valid arithmetic syntax.
        // Keep it on the date path, including invalid/unsupported date offsets.
        if Self.isoDateOffset.captures(raw) != nil {
            return CalculatorDates(now: now, timeZone: timeZone, locale: locale)
                .evaluate(raw.lowercased(), original: raw)
        }
        if Calculator.isExpression(folded), let value = Calculator.evaluate(folded, locale: locale) {
            return Calculator.format(value, locale: locale)
        }
        let text = raw.lowercased()
        let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        // Bare search words should take the fast path. The remaining no-number
        // queries start with one of these time, date or constant keywords.
        guard text.contains(where: \.isNumber) || wordsWithoutNumbers.contains(first) else { return nil }
        return CalculatorPlaces.evaluate(text, locale: locale)
            ?? CalculatorPhrases(locale: locale, pixelsPerEm: pixelsPerEm).evaluate(raw, lowercased: text)
            ?? CalculatorDates(now: now, timeZone: timeZone, locale: locale).evaluate(text, original: raw)
    }

    private static let wordsWithoutNumbers: Set<String> = [
        "now", "time", "today", "tomorrow", "yesterday", "今天", "明天", "昨天", "diff", "days", "workdays",
        "hours", "distance", "molar", "speed", "planck", "standard", "first", "last"
    ]
}

/// Use whole expressions so calculator phrases do not claim unrelated search terms.
struct CalculationPattern {
    let expression: NSRegularExpression

    init(_ pattern: String) {
        expression = try! NSRegularExpression(pattern: "^" + pattern + "$", options: .caseInsensitive)
    }

    func captures(_ input: String) -> [String]? {
        guard let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: input).map { String(input[$0]) } ?? ""
        }
    }
}

struct CalculatorPhrases {
    let locale: Locale
    let pixelsPerEm: Double

    private static let prefix = CalculationPattern(#"(square root of|cube root of)\s+(.+)"#)
    private static let power = CalculationPattern(#"(.+?)\s+(?:to the power of|power)\s+(.+)"#)
    private static let percent = CalculationPattern(#"(.+?)\s*%\s*(of|off|tip on|vat in|tax on|increase from|decrease from)\s+(.+?)(?:\s+split\s+(\d+))?"#)
    private static let ratio = CalculationPattern(#"(.+?)\s+as\s+%\s+of\s+(.+)"#)
    private static let asPercent = CalculationPattern(#"(.+?)\s+is\s+what\s*%"#)
    private static let split = CalculationPattern(#"(.+?)\s+split\s+(\d+)"#)
    private static let compound = CalculationPattern(#"(.+?)\s+at\s+(.+?)%\s+for\s+(.+?)\s+years?\s+compounded\s+(annually|yearly|monthly|quarterly|daily)"#)
    private static let fractions = CalculationPattern(#"(.+?)\s+(?:as|to)\s+(fraction|improper|mixed)"#)
    private static let base = CalculationPattern(#"(.+?)\s+(?:to|in)\s+(?:base\s+(\d{1,2})|(binary|octal|hex|hexadecimal|decimal))"#)
    private static let nearest = CalculationPattern(#"(.+?)\s+to\s+nearest\s+(.+)"#)
    private static let shorthand = CalculationPattern(#"([$€£¥]|[A-Z]{3})?\s*([+\-]?[0-9]+(?:[.,][0-9]+)?)\s*([kmbt])"#)
    private static let textPart = CalculationPattern(#"(first|last)\s+(\d+)\s+characters?\s+of\s+"([^"]*)""#)

    func evaluate(_ raw: String, lowercased text: String) -> String? {
        if let match = Self.textPart.captures(raw), let count = Int(match[1]) {
            return match[0].lowercased() == "first" ? String(match[2].prefix(count)) : String(match[2].suffix(count))
        }
        if let match = Self.prefix.captures(text), let number = number(match[1]) {
            return decimal(match[0] == "square root of" ? sqrt(number) : cbrt(number))
        }
        if let match = Self.power.captures(text), let x = number(match[0]), let y = number(match[1]) {
            return decimal(pow(x, y))
        }
        if let match = Self.percent.captures(text), let rate = number(match[0]), let amount = money(match[2]) {
            let share = rate / 100
            let value: Double
            switch match[1] {
            case "of": value = amount.value * share
            case "off", "decrease from": value = amount.value * (1 - share)
            case "vat in":
                guard share >= 0 else { return nil }
                value = amount.value * share / (1 + share)
            default: value = amount.value * (1 + share)
            }
            return moneyText(value, symbol: amount.symbol, split: match[3])
        }
        if let match = Self.ratio.captures(raw) {
            if let a = number(match[0]), let b = number(match[1]), b != 0 { return decimal(a / b * 100, suffix: "%") }
            if let ratio = CalculatorUnits.ratio(match[0], match[1], locale: locale) { return decimal(ratio * 100, suffix: "%") }
        }
        if let match = Self.asPercent.captures(text), let value = number(match[0]) { return decimal(value * 100, suffix: "%") }
        if let match = Self.split.captures(text), let amount = money(match[0]) {
            return moneyText(amount.value, symbol: amount.symbol, split: match[1])
        }
        if let match = Self.compound.captures(text), let amount = money(match[0]),
           let rate = number(match[1]), let years = number(match[2]), years >= 0 {
            let frequencies: [String: Double] = ["monthly": 12, "quarterly": 4, "daily": 365]
            let periods = frequencies[match[3]] ?? 1
            let factor = 1 + rate / 100 / periods
            guard factor > 0 else { return nil }
            return moneyText(amount.value * pow(factor, years * periods), symbol: amount.symbol)
        }
        if let match = Self.fractions.captures(text), let value = number(match[0]) {
            return fraction(value, mixed: match[1] != "improper")
        }
        if let match = Self.base.captures(text), let value = integer(match[0]),
           let radix = Int(match[1]) ?? ["binary": 2, "octal": 8, "hex": 16, "hexadecimal": 16, "decimal": 10][match[2]],
           (2...36).contains(radix) { return String(value, radix: radix, uppercase: true) }
        if let match = Self.nearest.captures(text), let value = number(match[0]),
           let step = ["integer": 1.0, "whole": 1, "half": 0.5, "quarter": 0.25, "tenth": 0.1,
                       "hundredth": 0.01, "thousandth": 0.001, "ten": 10, "hundred": 100, "thousand": 1000][match[1]] ?? number(match[1]),
           step > 0 { return decimal((value / step).rounded() * step) }
        if let match = Self.shorthand.captures(raw), let amount = shorthand(match) {
            return moneyText(amount.value, symbol: amount.symbol)
        }
        return CalculatorUnits(locale: locale, pixelsPerEm: pixelsPerEm).evaluate(raw, lowercased: text)
    }

    private func number(_ text: String) -> Double? { Calculator.evaluate(text, locale: locale) }

    private func integer(_ text: String) -> Int64? {
        let sign = text.hasPrefix("-") ? "-" : ""
        let digits = sign.isEmpty ? text : String(text.dropFirst())
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where digits.hasPrefix(prefix) {
            return Int64(sign + digits.dropFirst(2), radix: radix)
        }
        return Int64(text) ?? number(text).flatMap(Int64.init(exactly:))
    }

    private func money(_ text: String) -> (value: Double, symbol: String)? {
        if let match = Self.shorthand.captures(text), let amount = shorthand(match) { return amount }
        if let first = text.first, "$€£¥".contains(first), let value = number(String(text.dropFirst())) {
            return (value, String(first))
        }
        return number(text).map { ($0, "") }
    }

    private func shorthand(_ match: [String]) -> (value: Double, symbol: String)? {
        guard let value = number(match[1]), let scale = ["k": 1e3, "m": 1e6, "b": 1e9, "t": 1e12][match[2].lowercased()] else { return nil }
        let symbol = match[0].uppercased()
        if symbol.count == 3 && !Locale.Currency.isoCurrencies.contains(where: { $0.identifier == symbol }) { return nil }
        return (value * scale, symbol)
    }

    private func decimal(_ value: Double, suffix: String = "") -> String? {
        guard value.isFinite else { return nil }
        return Calculator.format(value, locale: locale) + suffix
    }

    private func moneyText(_ value: Double, symbol: String, split: String = "") -> String? {
        let divisor = split.isEmpty ? 1 : (Int(split) ?? 0)
        guard divisor > 0, value.isFinite else { return nil }
        if symbol.isEmpty { return decimal(value / Double(divisor)) }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        if symbol.count == 3 { formatter.currencyCode = symbol }
        else { formatter.currencySymbol = symbol }
        return formatter.string(from: NSNumber(value: value / Double(divisor)))
    }

    private func fraction(_ value: Double, mixed: Bool) -> String? {
        let magnitude = abs(value)
        guard magnitude < 1e9 else { return nil }
        let whole = Int(magnitude)
        let remainder = magnitude - Double(whole)
        let sign = value < 0 ? "-" : ""
        if remainder < 1e-8 { return sign + String(whole) }
        if 1 - remainder < 1e-8 { return sign + String(whole + 1) }
        for denominator in 2...10_000 {
            let numerator = Int((remainder * Double(denominator)).rounded())
            if abs(remainder - Double(numerator) / Double(denominator)) < 1e-8 {
                if mixed && whole > 0 { return "\(sign)\(whole) \(numerator)/\(denominator)" }
                return "\(sign)\(whole * denominator + numerator)/\(denominator)"
            }
        }
        return nil
    }
}
