import SwiftUI
import AppKit

/// Reusable secondary-screen layout. Each pane owns its scrolling and selection.
struct ResultDetailLayout<Results: View, Detail: View, EmptyState: View>: View {
    let hasResults: Bool
    @ViewBuilder let results: () -> Results
    @ViewBuilder let detail: () -> Detail
    @ViewBuilder let emptyState: () -> EmptyState

    var resultsFraction: CGFloat = 0.40

    var body: some View {
        if hasResults {
            splitContent
        } else {
            emptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, VisualStyle.launcherTopInset)
                .padding(.bottom, VisualStyle.launcherBottomInset)
        }
    }

    private var splitContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                results().frame(width: geometry.size.width * resultsFraction)
                Divider()
                    .mask {
                        VStack(spacing: 0) {
                            let headerOpacity = Color.black.opacity(0.4)
                            headerOpacity.frame(height: VisualStyle.launcherTopInset - 10)
                            LinearGradient(colors: [headerOpacity, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 10)
                            Color.black
                        }
                    }
                detail().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Centered presentation for a search that returned no results.
struct ResultDetailEmptyState: View {
    var title = "没有匹配结果"
    var message: String?

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .topLeading) {
                Image(systemName: "macwindow")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.quaternary)
                    .padding(.leading, 8)
                    .padding(.top, 6)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
            Text(title).font(VisualStyle.rowText.weight(.medium)).foregroundStyle(.secondary)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }
}

/// Shared icon-and-title label used inside secondary-screen menu buttons.
struct SecondaryPageBadge: View {
    let title: String
    let symbol: String

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
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 5))
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, Self.trailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: VisualStyle.launcherControlDiameter)
        .accessibilityElement(children: .combine)
    }
}
