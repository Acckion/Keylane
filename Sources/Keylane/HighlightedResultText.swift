import SwiftUI

/// Literal search matches share the same emphasis in all result lists.
struct HighlightedResultText: View {
    let text: String
    let query: String

    var body: some View { Text(highlighted) }

    private var highlighted: AttributedString {
        var value = AttributedString(text)
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return value }
        value.foregroundColor = .secondary
        for term in terms {
            var remaining = text.startIndex..<text.endIndex
            while let match = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining) {
                if let start = AttributedString.Index(match.lowerBound, within: value),
                   let end = AttributedString.Index(match.upperBound, within: value) {
                    value[start..<end].foregroundColor = .primary
                    value[start..<end].font = .system(size: 14, weight: .semibold)
                }
                remaining = match.upperBound..<text.endIndex
            }
        }
        return value
    }
}
