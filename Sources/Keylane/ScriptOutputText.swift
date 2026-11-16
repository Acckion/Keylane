import SwiftUI

/// Converts terminal SGR styles without interpreting cursor movement or other terminal commands.
enum ScriptOutputText {
    private static let controls = try! NSRegularExpression(
        pattern: #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-_])"#
    )
    private static let normal = [0x000000, 0xb12424, 0x006b4f, 0xa76800, 0x086bb8, 0x9a1b6e, 0x087e84, 0xc0c0c0]
    private static let bright = [0x808080, 0xff6363, 0x59d499, 0xffc531, 0x56c2ff, 0xcf2f98, 0x52eee5, 0xffffff]

    static func plain(_ source: String) -> String {
        controls.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: "")
    }

    static func styled(_ source: String, dark: Bool) -> AttributedString {
        var output = AttributedString()
        var attributes = AttributeContainer()
        var start = source.startIndex
        for control in controls.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(control.range, in: source) else { continue }
            output += AttributedString(String(source[start..<range.lowerBound]), attributes: attributes)
            start = range.upperBound
            let sequence = source[range]
            if sequence.hasPrefix("\u{1B}["), sequence.hasSuffix("m") {
                let values = sequence.dropFirst(2).dropLast().split(separator: ";", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? 0 : (Int($0) ?? -1) }
                apply(values.isEmpty ? [0] : values, to: &attributes, dark: dark)
            }
        }
        output += AttributedString(String(source[start...]), attributes: attributes)
        return output
    }

    private static func apply(_ values: [Int], to attributes: inout AttributeContainer, dark: Bool) {
        var index = 0
        while index < values.count {
            let code = values[index]
            index += 1
            switch code {
            case 0: attributes = AttributeContainer()
            case 4: attributes.underlineStyle = .single
            case 9: attributes.strikethroughStyle = .single
            case 24: attributes.underlineStyle = nil
            case 29: attributes.strikethroughStyle = nil
            case 30...37: attributes.foregroundColor = color((dark ? bright : normal)[code - 30])
            case 40...47: attributes.backgroundColor = color((dark ? bright : normal)[code - 40])
            case 90...97: attributes.foregroundColor = color(bright[code - 90])
            case 100...107: attributes.backgroundColor = color(bright[code - 100])
            case 39: attributes.foregroundColor = nil
            case 49: attributes.backgroundColor = nil
            case 38, 48:
                guard index < values.count else { return }
                let kind = values[index]
                index += 1
                let rgb: Int?
                if kind == 5, index < values.count {
                    rgb = indexed(values[index])
                    index += 1
                } else if kind == 2, index + 2 < values.count {
                    let components = values[index...index + 2]
                    rgb = components.allSatisfy { (0...255).contains($0) }
                        ? components.reduce(0) { ($0 << 8) | $1 } : nil
                    index += 3
                } else { return }
                if let rgb {
                    if code == 38 { attributes.foregroundColor = color(rgb) }
                    else { attributes.backgroundColor = color(rgb) }
                }
            default: break
            }
        }
    }

    private static func indexed(_ value: Int) -> Int? {
        switch value {
        case 0..<8: return normal[value]
        case 8..<16: return bright[value - 8]
        case 16..<232:
            let index = value - 16
            let levels = [0, 95, 135, 175, 215, 255]
            return (levels[index / 36] << 16) | (levels[index / 6 % 6] << 8) | levels[index % 6]
        case 232..<256: return (8 + (value - 232) * 10) * 0x010101
        default: return nil
        }
    }

    private static func color(_ rgb: Int) -> Color {
        Color(red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct ScriptTerminalText: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(ScriptOutputText.styled(source, dark: colorScheme == .dark))
    }
}
