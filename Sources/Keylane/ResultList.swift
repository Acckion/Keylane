import SwiftUI

/// Shared scrolling surface. Secondary screens supply only rows and their empty state.
struct ResultListScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }.scrollIndicators(.visible, axes: .vertical)
            .contentMargins(.top, 61, for: .scrollContent)
            .contentMargins(.bottom, 52, for: .scrollContent)
            .contentMargins(.top, 61, for: .scrollIndicators)
            .contentMargins(.bottom, 52, for: .scrollIndicators)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black.opacity(0.2), location: 0.08),
                .init(color: .black, location: 0.19), .init(color: .black, location: 0.80),
                .init(color: .black.opacity(0.2), location: 0.96), .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
    }
}
