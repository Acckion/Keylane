import SwiftUI

/// Shared typography and symbol metrics for navigation and action rows.
enum VisualStyle {
    static let rowText = Font.system(size: 14, weight: .regular)
    static let actionSymbol = Font.system(size: 15, weight: .regular)
    static let sectionText = Font.system(size: 12, weight: .medium)
    static let actionIconWidth: CGFloat = 18
    static let actionSpacing: CGFloat = 9
    static let selectionRadius: CGFloat = 10
}
