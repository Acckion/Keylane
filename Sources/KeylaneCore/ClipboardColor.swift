import Foundation

public struct ClipboardColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public enum Format: String, CaseIterable {
        case hex = "Hex"
        case hexAlpha = "Hex（含透明度）"
        case rgba = "RGBA"
        case rgbaPercent = "RGBA（百分比）"
        case cssRGB = "RGB (CSS4)"
        case hsl = "HSL"
    }

    public var hexLabel: String { formatted(as: alpha == 1 ? .hex : .hexAlpha) }

    public init?(_ input: String) {
        guard input.utf8.count <= 256 else { return nil }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            var digits = Array(value.dropFirst().utf8)
            guard [3, 4, 6, 8].contains(digits.count),
                  digits.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            if digits.count < 6 { digits = digits.flatMap { [$0, $0] } }
            guard let hex = UInt32(String(decoding: digits, as: UTF8.self), radix: 16) else { return nil }
            let rgba = digits.count == 8 ? hex : (hex << 8) | 255
            self.init(red: Double(rgba >> 24) / 255, green: Double((rgba >> 16) & 255) / 255,
                      blue: Double((rgba >> 8) & 255) / 255, alpha: Double(rgba & 255) / 255)
            return
        }
        guard value.hasSuffix(")"), let opening = value.firstIndex(of: "(") else { return nil }
        let function = value[..<opening]
        guard ["rgb", "rgba", "hsl", "hsla"].contains(function) else { return nil }
        let body = value[value.index(after: opening)..<value.index(before: value.endIndex)]
        guard let arguments = Self.arguments(body),
              let alpha = Self.channel(arguments.alpha ?? "1", scale: 1) else { return nil }
        let components = arguments.components
        if function.hasPrefix("rgb") {
            guard let red = Self.channel(components[0], scale: 255),
                  let green = Self.channel(components[1], scale: 255),
                  let blue = Self.channel(components[2], scale: 255) else { return nil }
            self.init(red: red, green: green, blue: blue, alpha: alpha)
        } else {
            guard let hue = Self.hue(components[0]),
                  components[1].hasSuffix("%"), let saturation = Self.channel(components[1], scale: 1),
                  components[2].hasSuffix("%"), let lightness = Self.channel(components[2], scale: 1) else { return nil }
            let chroma = (1 - abs(2 * lightness - 1)) * saturation
            func component(_ offset: Double) -> Double {
                let k = (offset + hue / 30).truncatingRemainder(dividingBy: 12)
                return min(1, max(0, lightness - chroma / 2 * max(-1, min(k - 3, 9 - k, 1))))
            }
            self.init(red: component(0), green: component(8), blue: component(4), alpha: alpha)
        }
    }

    private init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public func formatted(as format: Format) -> String {
        let channels = [red, green, blue]
        let alphaText = Self.decimal(alpha, digits: 4)
        switch format {
        case .hex, .hexAlpha:
            let values = format == .hex ? channels : channels + [alpha]
            return "#" + values.map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
        case .rgba:
            let values = channels.map { Self.decimal($0 * 255) } + [alphaText]
            return "rgba(" + values.joined(separator: ", ") + ")"
        case .rgbaPercent:
            let values = channels.map { Self.decimal($0 * 100) + "%" } + [alphaText]
            return "rgba(" + values.joined(separator: ", ") + ")"
        case .cssRGB:
            let values = channels.map { Self.decimal($0 * 255) }.joined(separator: " ")
            return "rgb(" + values + (alpha == 1 ? "" : " / " + alphaText) + ")"
        case .hsl:
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            let chroma = maximum - minimum
            let lightness = (maximum + minimum) / 2
            var hue = 0.0
            var saturation = 0.0
            if chroma > 0 {
                let segment: Double
                switch maximum {
                case red: segment = (green - blue) / chroma
                case green: segment = (blue - red) / chroma + 2
                default: segment = (red - green) / chroma + 4
                }
                hue = (segment * 60 + 360).truncatingRemainder(dividingBy: 360)
                saturation = min(1, chroma / (1 - abs(2 * lightness - 1)))
            }
            let values = "\(Self.decimal(hue))deg \(Self.decimal(saturation * 100))% \(Self.decimal(lightness * 100))%"
            return "hsl(" + values + (alpha == 1 ? "" : " / " + alphaText) + ")"
        }
    }

    private static func arguments(_ body: Substring) -> (components: [String], alpha: String?)? {
        if body.contains(",") {
            let parts = body.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (3...4).contains(parts.count) else { return nil }
            return (Array(parts.prefix(3)), parts.count == 4 ? parts[3] : nil)
        }
        let parts = body.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return nil }
        let components = parts[0].split(whereSeparator: \.isWhitespace).map(String.init)
        guard components.count == 3 else { return nil }
        return (components, parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    private static func number(_ value: String) -> Double? {
        guard value.utf8.allSatisfy({ (48...57).contains($0) || [43, 45, 46, 101].contains($0) }),
              let result = Double(value), result.isFinite else { return nil }
        return result
    }

    private static func channel(_ value: String, scale: Double) -> Double? {
        let percentage = value.hasSuffix("%")
        guard let number = number(percentage ? String(value.dropLast()) : value) else { return nil }
        let maximum = percentage ? 100 : scale
        guard (0...maximum).contains(number) else { return nil }
        return number / maximum
    }

    private static func hue(_ value: String) -> Double? {
        for (suffix, period) in [("grad", 400.0), ("rad", 2 * .pi), ("turn", 1), ("deg", 360)] where value.hasSuffix(suffix) {
            guard let angle = number(String(value.dropLast(suffix.count))) else { return nil }
            return (angle.truncatingRemainder(dividingBy: period) / period + 1)
                .truncatingRemainder(dividingBy: 1) * 360
        }
        guard let angle = number(value) else { return nil }
        return (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func decimal(_ value: Double, digits: Int = 2) -> String {
        var result = String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), digits, value)
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result == "-0" ? "0" : result
    }
}
