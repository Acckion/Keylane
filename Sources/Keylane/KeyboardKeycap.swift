import SwiftUI
import KeylaneCore

struct Keycap: View {
    static let side: CGFloat = 18
    let text: String
    @Environment(\.colorSchemeContrast) private var contrast
    private var symbol: String? {
        switch text.lowercased() {
        case "⌃", "control": return "control"
        case "⌥", "option": return "option"
        case "⌘", "command": return "command"
        case "⇧", "shift": return "shift"
        case "space", "空格": return "space"
        case "↩", "return": return "return"
        case "esc", "escape": return "escape"
        case "⌫", "delete": return "delete.left"
        case "⇥", "tab": return "arrow.right.to.line"
        case "caps lock": return "capslock"
        case "hyper key": return "sparkle"
        case "←": return "arrow.left"
        case "→", "›": return "arrow.right"
        case "↑": return "arrow.up"
        case "↓": return "arrow.down"
        default: return nil
        }
    }
    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).symbolRenderingMode(.monochrome).font(.system(size: 9.5, weight: .medium)) }
            else { Text(text).fontDesign(.monospaced) }
        }.font(.system(size: 10, weight: .medium)).foregroundStyle(Color.primary.opacity(contrast == .increased ? 1 : 0.78))
            .frame(width: Self.side, height: Self.side)
            .overlay(RoundedRectangle(cornerRadius: 4.5).strokeBorder(.primary.opacity(contrast == .increased ? 0.65 : 0.34), lineWidth: 1))
            .accessibilityLabel(text)
    }
}
struct Keycaps: View {
    let keys: [String]
    @AppStorage("hyperkey") private var hyperEnabled = false
    @AppStorage("hyperIncludesShift") private var includesShift = true
    @AppStorage("replaceHyperKeycaps") private var replacesHyperKeycaps = false

    private var visibleKeys: [String] {
        guard hyperEnabled, replacesHyperKeycaps else { return keys }
        let modifiers: Set<String> = ["⌃", "⌥", "⇧", "⌘"]
        let leading = keys.prefix(while: modifiers.contains)
        let combination: Set<String> = includesShift ? modifiers : ["⌃", "⌥", "⌘"]
        guard leading.count == combination.count, Set(leading) == combination else { return keys }
        return ["Hyper Key"] + keys.dropFirst(leading.count)
    }

    var body: some View {
        let visible = visibleKeys
        return HStack(spacing: 3) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, key in Keycap(text: key) }
        }
        .fixedSize().accessibilityElement(children: .ignore).accessibilityLabel(visible.joined(separator: " + "))
    }
}
