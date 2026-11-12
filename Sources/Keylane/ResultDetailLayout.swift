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
    let artwork: NSImage?

    private static let iconSize: CGFloat = 21
    private static let leadingInset = (VisualStyle.launcherControlDiameter - iconSize) / 2 + 2
    private static let iconSpacing: CGFloat = 6
    private static let trailingInset: CGFloat = 12

    static func width(for title: String) -> CGFloat {
        let textWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width
        return leadingInset + iconSize + iconSpacing + textWidth + trailingInset
    }
    var body: some View {
        HStack(spacing: Self.iconSpacing) {
            Group {
                if let artwork {
                    ModuleArtworkImage(image: artwork)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(width: Self.iconSize, height: Self.iconSize)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: VisualStyle.launcherControlDiameter)
        .accessibilityElement(children: .combine)
    }
}
