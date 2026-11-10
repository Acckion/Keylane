import SwiftUI

/// Reusable secondary-screen layout. Each pane owns its scrolling and selection.
struct ResultDetailLayout<Results: View, Detail: View>: View {
    @ViewBuilder let results: () -> Results
    @ViewBuilder let detail: () -> Detail

    var resultsFraction: CGFloat = 0.44

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

/// Identifies a secondary screen without exposing the home menu.
struct SecondaryPageBadge: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                .frame(width: 25, height: 25)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 5))
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.leading, 8).padding(.trailing, 13).frame(height: 36)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
