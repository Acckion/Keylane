import SwiftUI
import KeylaneCore

/// Fixed document samples share the preview's semantic theme colors.
struct ThemePreviewMarkdown: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Markdown Example").font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
            AIConversationMarkdownBody(text: "This is an example paragraph. Make your workspace your own. Choose colors that help you focus, and build a theme that feels right for you.")
            Text("Codeblock").font(.system(size: 21, weight: .bold)).padding(.top, 10).accessibilityAddTraits(.isHeader)
            Text(code).font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }.textSelection(.enabled)
    }
    private var code: AttributedString {
        // Explicit sample tokens, so changing a support color immediately updates its role.
        let tokens: [(String, ThemeColorRole?)] = [
            ("// Create a URL session\n", nil), ("let ", .orange), ("session = URLSession.shared\n\n", .text),
            ("// Create a data task with the URL\n", nil), ("let ", .orange), ("task = session.dataTask(with: url) { data, response, error ", .text), ("in\n", .orange),
            ("    // Check for errors\n", nil), ("    if let ", .orange), ("error = error {\n        print(", .text),
            ("\"Request failed\"", .red), (")\n        ", .text), ("return\n", .orange), ("    }\n\n", .text),
            ("    // Check if data was received\n", nil), ("    guard let ", .orange), ("data = data ", .text), ("else ", .orange),
            ("{\n        print(", .text), ("\"No data received\"", .red), (")\n        ", .text), ("return\n", .orange),
            ("    }\n\n", .text), ("    // Process the response\n", nil), ("    print(data.count)\n}\ntask.resume()", .text)
        ]
        return tokens.reduce(into: AttributedString()) { result, token in
            var part = AttributedString(token.0)
            part.foregroundColor = token.1.map { theme.color($0).swiftUI } ?? theme.color(.text).swiftUI.opacity(0.55)
            result.append(part)
        }
    }
    @Environment(\.keylaneTheme) private var selectedTheme
    private var theme: ThemeDefinition { selectedTheme ?? ThemeDefinition.builtins[0] }
}

struct ThemePreviewFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.16)))
    }
}
