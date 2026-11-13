import Foundation

public struct CalculatorConversion {
    public let amount: Double
    public let source: String
    public let target: String
    private let locale: Locale

    public init?(_ query: String, locale: Locale = .current) {
        guard query.utf16.count <= 512 else { return nil }
        let normalized = Calculator.decimalInput(query.folding(options: .widthInsensitive, locale: locale), locale: locale)
        let pattern = #"^\s*=?\s*([+\-−]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*([^\d\s][^\d]*?)\s*(?:\bto\b|\bin\b|换算成|换成|转换为|转为|转成|转|到|=|→)\s*([^\d]+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let number = Range(match.range(at: 1), in: normalized),
              let from = Range(match.range(at: 2), in: normalized),
              let to = Range(match.range(at: 3), in: normalized),
              let amount = Double(normalized[number].replacingOccurrences(of: "−", with: "-")), amount.isFinite else { return nil }
        self.amount = amount
        self.locale = locale
        self.source = normalized[from].trimmingCharacters(in: .whitespaces)
        self.target = normalized[to].trimmingCharacters(in: .whitespaces)
    }

    public var unitResult: String? {
        guard let from = Self.units[source.lowercased()], let to = Self.units[target.lowercased()],
              type(of: from) == type(of: to) else { return nil }
        let value = Measurement(value: amount, unit: from).converted(to: to).value
        guard value.isFinite else { return nil }
        return Calculator.format(value, locale: locale) + " " + to.symbol
    }

    public var currencies: (source: String, target: String)? {
        guard let from = Self.currencyCode(source), let to = Self.currencyCode(target) else { return nil }
        return (from, to)
    }

    private static func currencyCode(_ token: String) -> String? {
        let code = currencyAliases[token.lowercased()] ?? token.uppercased()
        return currencyCodes.contains(code) ? code : nil
    }

    private static let currencyCodes = Set(Locale.Currency.isoCurrencies.map(\.identifier))
    private static let currencyAliases = [
        "美元": "USD", "美金": "USD", "人民币": "CNY", "欧元": "EUR", "英镑": "GBP",
        "日元": "JPY", "港币": "HKD", "港元": "HKD", "澳元": "AUD", "加元": "CAD",
        "韩元": "KRW", "新加坡元": "SGD", "瑞士法郎": "CHF"
    ]
    private static let units: [String: Dimension] = {
        let entries: [(Dimension, [String])] = [
            (UnitLength.meters, ["m", "meter", "meters", "米"]),
            (UnitLength.kilometers, ["km", "kilometer", "kilometers", "公里", "千米"]),
            (UnitLength.centimeters, ["cm", "厘米"]), (UnitLength.millimeters, ["mm", "毫米"]),
            (UnitLength.inches, ["in", "inch", "inches", "英寸"]), (UnitLength.feet, ["ft", "foot", "feet", "英尺"]),
            (UnitLength.yards, ["yd", "yard", "yards", "码"]), (UnitLength.miles, ["mi", "mile", "miles", "英里"]),
            (UnitMass.kilograms, ["kg", "kilograms", "千克", "公斤"]), (UnitMass.grams, ["g", "grams", "克"]),
            (UnitMass.milligrams, ["mg", "毫克"]), (UnitMass.pounds, ["lb", "lbs", "pound", "pounds", "磅"]),
            (UnitMass.ounces, ["oz", "ounce", "ounces", "盎司"]),
            (UnitTemperature.celsius, ["c", "°c", "℃", "celsius", "摄氏度"]),
            (UnitTemperature.fahrenheit, ["f", "°f", "℉", "fahrenheit", "华氏度"]),
            (UnitTemperature.kelvin, ["k", "kelvin", "开尔文"]),
            (UnitVolume.liters, ["l", "liter", "liters", "升"]), (UnitVolume.milliliters, ["ml", "毫升"]),
            (UnitVolume.gallons, ["gal", "gallon", "gallons", "美制加仑"]),
            (UnitArea.squareMeters, ["m²", "sqm", "平方米"]), (UnitArea.squareKilometers, ["km²", "平方公里"]),
            (UnitArea.squareFeet, ["ft²", "sqft", "平方英尺"]), (UnitArea.hectares, ["ha", "公顷"]),
            (UnitDuration.seconds, ["s", "second", "seconds", "秒"]),
            (UnitDuration.minutes, ["min", "minute", "minutes", "分钟"]),
            (UnitDuration.hours, ["h", "hr", "hour", "hours", "小时"]),
            (UnitSpeed.kilometersPerHour, ["km/h", "kph", "公里/小时"]),
            (UnitSpeed.metersPerSecond, ["m/s", "米/秒"]), (UnitSpeed.milesPerHour, ["mph", "英里/小时"])
        ]
        return Dictionary(uniqueKeysWithValues: entries.flatMap { unit, names in names.map { ($0, unit) } })
    }()
}
