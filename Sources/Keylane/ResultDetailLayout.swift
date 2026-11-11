import SwiftUI
import AppKit

/// Reusable secondary-screen layout. Each pane owns its scrolling and selection.
struct ResultDetailLayout<Results: View, Detail: View>: View {
    @ViewBuilder let results: () -> Results
    @ViewBuilder let detail: () -> Detail

    var resultsFraction: CGFloat = 0.40

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                results().frame(width: geometry.size.width * resultsFraction)
                Divider()
                detail().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Shared icon-and-title label used inside secondary-screen menu buttons.
struct SecondaryPageBadge: View {
    let title: String
    let symbol: String
    static func width(for title: String) -> CGFloat {
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        // Keep the icon centered on the left arc; tighten the trailing inset slightly.
        return 18 + 10.5 + 8 + textWidth + 12
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 5))
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(.leading, (VisualStyle.launcherControlDiameter - 21) / 2)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: VisualStyle.launcherControlDiameter)
        .accessibilityElement(children: .combine)
    }
}
