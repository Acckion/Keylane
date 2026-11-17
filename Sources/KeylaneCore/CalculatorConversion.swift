import Foundation

public struct CalculatorConversion {
    private static let currencyShorthand = CalculationPattern(#"([a-z]{3})\s*([+\-]?\d+(?:[.,]\d+)?)\s*([kmbt])?\s+(?:to|in)\s+(.+)"#)
    private static let conversion = CalculationPattern(#"\s*=?\s*([+\-−]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)\s*([^\d\s][^\d]*?)\s*(?:\bto\b|\bin\b|换算成|换成|转换为|转为|转成|转|到|=|→)\s*([^\d]+?)\s*"#)
    public let amount: Double
    public let source: String
    public let target: String
    private let locale: Locale

    public init?(_ query: String, locale: Locale = .current) {
        guard query.utf16.count <= 512 else { return nil }
        let folded = query.folding(options: .widthInsensitive, locale: locale).trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = Self.currencyShorthand.captures(folded),
           Self.currencyCode(match[0]) != nil, Self.currencyCode(match[3]) != nil,
           let value = Calculator.evaluate(match[1], locale: locale) {
            let scales: [String: Double] = ["k": 1e3, "m": 1e6, "b": 1e9, "t": 1e12]
            amount = value * (scales[match[2].lowercased()] ?? 1)
            guard amount.isFinite else { return nil }
            source = match[0]
            target = match[3]
            self.locale = locale
            return
        }
        let normalized = Calculator.decimalInput(Calculator.groupingInput(folded, locale: locale), locale: locale)
        guard let match = Self.conversion.captures(normalized),
              let amount = Double(match[0].replacingOccurrences(of: "−", with: "-")), amount.isFinite else { return nil }
        self.amount = amount
        self.locale = locale
        self.source = match[1].trimmingCharacters(in: .whitespaces)
        self.target = match[2].trimmingCharacters(in: .whitespaces)
    }

    public var unitResult: String? {
        guard let from = Self.units[source.lowercased()], let to = Self.units[target.lowercased()],
              type(of: from) == type(of: to) else { return nil }
        let value = CalculatorUnits.exactAmount(amount, from: source, to: target)
            ?? Measurement(value: amount, unit: from).converted(to: to).value
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
        "韩元": "KRW", "新加坡元": "SGD", "瑞士法郎": "CHF",
        "won": "KRW", "korean won": "KRW", "south korean won": "KRW", "rupiah": "IDR", "indonesian rupiah": "IDR",
        "zl": "PLN", "zł": "PLN", "zloty": "PLN", "złoty": "PLN", "polish zloty": "PLN",
        "euro": "EUR", "euros": "EUR", "us dollar": "USD", "us dollars": "USD", "american dollars": "USD",
        "pound sterling": "GBP", "british pounds": "GBP", "japanese yen": "JPY", "yen": "JPY",
        "chinese yuan": "CNY", "yuan": "CNY", "canadian dollars": "CAD", "australian dollars": "AUD"
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
