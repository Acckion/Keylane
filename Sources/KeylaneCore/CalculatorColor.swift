import CoreGraphics
import Foundation
import simd

public struct CalculatorColor {
    private typealias Vector = SIMD3<Double>
    private let rgb: Vector
    public let alpha: Double
    public var color: ClipboardColor {
        ClipboardColor(red: Self.clamp(rgb.x), green: Self.clamp(rgb.y), blue: Self.clamp(rgb.z), alpha: alpha)
    }
    public var hexLabel: String { color.hexLabel }

    public init?(_ input: String) {
        guard input.utf8.count <= 256 else { return nil }
        if let color = ClipboardColor(input) {
            rgb = Vector(color.red, color.green, color.blue)
            alpha = color.alpha
            return
        }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard text.hasSuffix(")"), let open = text.firstIndex(of: "("),
              let arguments = ClipboardColor.arguments(text[text.index(after: open)..<text.index(before: text.endIndex)]),
              let alpha = ClipboardColor.channel(arguments.alpha ?? "1", scale: 1) else { return nil }
        let components = arguments.components
        let kind = text[..<open]
        self.alpha = alpha
        if kind == "hwb" {
            guard let hue = ClipboardColor.hue(components[0]), components[1].hasSuffix("%"), components[2].hasSuffix("%"),
                  let white = ClipboardColor.channel(components[1], scale: 1),
                  let black = ClipboardColor.channel(components[2], scale: 1),
                  let pure = ClipboardColor("hsl(\(hue) 100% 50%)") else { return nil }
            if white + black >= 1 { rgb = Vector(repeating: white / (white + black)) }
            else { rgb = Vector(pure.red, pure.green, pure.blue) * (1 - white - black) + Vector(repeating: white) }
            return
        }
        guard ["lab", "lch", "oklab", "oklch"].contains(kind) else { return nil }
        let isOK = kind.hasPrefix("ok")
        let isPolar = kind.hasSuffix("lch")
        guard let lightness = Self.component(components[0], percentScale: isOK ? 1 : 100),
              let a = Self.component(components[1], percentScale: isOK ? 0.4 : (isPolar ? 150 : 125)),
              let b = isPolar ? ClipboardColor.hue(components[2]) : Self.component(components[2], percentScale: isOK ? 0.4 : 125),
              abs(a) <= 1_000, abs(b) <= 1_000 else { return nil }
        let radians = b * .pi / 180
        let sample = Vector(min(isOK ? 1 : 100, max(0, lightness)),
                            isPolar ? max(0, a) * cos(radians) : a,
                            isPolar ? max(0, a) * sin(radians) : b)
        if isOK {
            rgb = Self.fromOKLab(sample)
        } else {
            guard let converted = Self.convert(sample, from: CGColorSpace.genericLab, to: CGColorSpace.extendedSRGB) else { return nil }
            rgb = converted
        }
        guard rgb.x.isFinite, rgb.y.isFinite, rgb.z.isFinite else { return nil }
    }

    public var formats: [(title: String, text: String)] {
        let alphaText = ClipboardColor.decimal(alpha, digits: 5)
        let suffix = alpha == 1 ? "" : " / " + alphaText
        let rgbColor = color
        var items = ClipboardColor.Format.allCases.filter { $0 != .hsl }.map { ($0.rawValue, rgbColor.formatted(as: $0)) }
        let channels = Vector(rgbColor.red, rgbColor.green, rgbColor.blue)
        let cssHSL = rgbColor.formatted(as: .hsl)
        let hsl = cssHSL.dropFirst(4).dropLast().split(separator: " ").prefix(3)
        let hue = hsl.first ?? "0"
        items.append(("HSL", "hsl(" + hsl.joined(separator: ", ") + ")"))
        items.append(("HSL（含透明度）", "hsla(" + hsl.joined(separator: ", ") + ", " + alphaText + ")"))
        items.append(("HSL (CSS4)", cssHSL))
        items.append(("HWB", "hwb(\(hue) \(Self.display(min(channels.x, channels.y, channels.z) * 100))% \(Self.display((1 - max(channels.x, channels.y, channels.z)) * 100))%\(suffix))"))
        if let lab = Self.convert(rgb, from: CGColorSpace.extendedSRGB, to: CGColorSpace.genericLab) {
            items.append(("Lab", Self.css("lab", lab, suffix)))
            items.append(("LCH", Self.css("lch", Self.polar(lab), suffix)))
        }
        let ok = Self.toOKLab(rgb)
        items.append(("Oklab", Self.css("oklab", ok, suffix)))
        items.append(("Oklch", Self.css("oklch", Self.polar(ok), suffix)))
        items.append(("NSColor", "NSColor(srgbRed: \(Self.display(channels.x)), green: \(Self.display(channels.y)), blue: \(Self.display(channels.z)), alpha: \(alphaText))"))
        return items
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }

    private static func component(_ token: String, percentScale: Double) -> Double? {
        let percentage = token.hasSuffix("%")
        guard let value = Double(percentage ? String(token.dropLast()) : token), value.isFinite else { return nil }
        return percentage ? value / 100 * percentScale : value
    }

    private static func convert(_ value: Vector, from sourceName: CFString, to targetName: CFString) -> Vector? {
        guard let source = CGColorSpace(name: sourceName), let target = CGColorSpace(name: targetName),
              let color = CGColor(colorSpace: source, components: [value.x, value.y, value.z, 1]),
              let converted = color.converted(to: target, intent: .relativeColorimetric, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        return Vector(components[0], components[1], components[2])
    }

    private static func display(_ value: Double) -> String { ClipboardColor.decimal(value, digits: 5) }
    private static func css(_ name: String, _ value: Vector, _ alpha: String) -> String {
        "\(name)(\(display(value.x)) \(display(value.y)) \(display(value.z))\(alpha))"
    }
    private static func polar(_ value: Vector) -> Vector {
        let hue = (atan2(value.z, value.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return Vector(value.x, hypot(value.y, value.z), hue)
    }

    // CSS Color 4, Oklab and linear sRGB transforms.
    private static func fromOKLab(_ value: Vector) -> Vector {
        let l = value.x + 0.3963377774 * value.y + 0.2158037573 * value.z
        let m = value.x - 0.1055613458 * value.y - 0.0638541728 * value.z
        let s = value.x - 0.0894841775 * value.y - 1.2914855480 * value.z
        let cubes = Vector(l * l * l, m * m * m, s * s * s)
        func gamma(_ x: Double) -> Double { abs(x) <= 0.0031308 ? 12.92 * x : copysign(1.055 * pow(abs(x), 1 / 2.4) - 0.055, x) }
        return Vector(
            gamma(simd_dot(cubes, Vector(4.0767416621, -3.3077115913, 0.2309699292))),
            gamma(simd_dot(cubes, Vector(-1.2684380046, 2.6097574011, -0.3413193965))),
            gamma(simd_dot(cubes, Vector(-0.0041960863, -0.7034186147, 1.7076147010)))
        )
    }

    private static func toOKLab(_ value: Vector) -> Vector {
        func linear(_ x: Double) -> Double { abs(x) <= 0.04045 ? x / 12.92 : copysign(pow((abs(x) + 0.055) / 1.055, 2.4), x) }
        let rgb = Vector(linear(value.x), linear(value.y), linear(value.z))
        let sample = Vector(
            cbrt(simd_dot(rgb, Vector(0.4122214708, 0.5363325363, 0.0514459929))),
            cbrt(simd_dot(rgb, Vector(0.2119034982, 0.6806995451, 0.1073969566))),
            cbrt(simd_dot(rgb, Vector(0.0883024619, 0.2817188376, 0.6299787005)))
        )
        return Vector(
            simd_dot(sample, Vector(0.2104542553, 0.7936177850, -0.0040720468)),
            simd_dot(sample, Vector(1.9779984951, -2.4285922050, 0.4505937099)),
            simd_dot(sample, Vector(0.0259040371, 0.7827717662, -0.8086757660))
        )
    }
}
