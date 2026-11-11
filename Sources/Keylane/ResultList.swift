import SwiftUI

/// Shared scrolling surface. Secondary screens supply only rows and their empty state.
struct ResultListScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, VisualStyle.launcherEdgeInset)
                .padding(.bottom, VisualStyle.launcherEdgeInset)
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

/// One row style for file search and clipboard: icon, content, shared selection and sizing.
struct ResultListRow<Icon: View, Content: View>: View {
    let selected: Bool
    var height: CGFloat = 40
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: 10) {
            icon().frame(width: 26, height: 26)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 10).frame(height: height)
            .background(selected ? Color.primary.opacity(contrast == .increased ? 0.22 : 0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
    }
}
