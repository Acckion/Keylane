import SwiftUI

/// Shared scrolling surface. Secondary screens supply only rows and their empty state.
struct ResultListScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, VisualStyle.launcherEdgeInset)
                .padding(.bottom, VisualStyle.launcherEdgeInset)
        }
            .launcherScrollInsets()
            .mask(LinearGradient(stops: [
                .init(color: .clear, location: 0), .init(color: .black.opacity(0.2), location: 0.08),
                .init(color: .black, location: 0.19), .init(color: .black, location: 0.80),
                .init(color: .black.opacity(0.2), location: 0.96), .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
    }
}

struct SelectableResultList<ID: Hashable, Content: View>: View {
    let selection: ID?
    var query: String? = nil
    var firstResult: ID? = nil
    var revealAfterLoading = false
    var revealInitialSelection = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollViewReader { proxy in
            ResultListScrollView(content: content)
                .onAppear {
                    if revealInitialSelection, let selection, selection != firstResult { proxy.scrollTo(selection) }
                }
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: revealAfterLoading) { _, ready in
                    if ready, let selection { proxy.scrollTo(selection) }
                }
                .onChange(of: query) { _, _ in
                    if let firstResult { proxy.scrollTo(firstResult, anchor: .top) }
                }
        }
    }
}

extension View {
    func launcherScrollInsets(top: Bool = true, bottom: Bool = true) -> some View {
        let topInset = top ? VisualStyle.launcherTopInset : 0
        let bottomInset = bottom ? VisualStyle.launcherBottomInset : 0
        return scrollIndicators(.visible, axes: .vertical)
            .contentMargins(.top, topInset, for: .scrollContent)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .contentMargins(.top, topInset, for: .scrollIndicators)
            .contentMargins(.bottom, bottomInset, for: .scrollIndicators)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }
}

/// Keeps mouse activation and the scroll target on the same result identity.
struct ResultListButton<ID: Hashable, Label: View>: View {
    let id: ID
    var disabled = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
            .disabled(disabled)
            .id(id)
    }
}

enum ResultListRowLayout {
    case standard
    case root

    var horizontalInset: CGFloat {
        switch self {
        case .standard: return 10
        case .root: return 13
        }
    }
}

/// Owns result selection, icon size and row metrics for root and secondary lists.
struct ResultListRow<Icon: View, Content: View>: View {
    let selected: Bool
    var height: CGFloat = 40
    var layout: ResultListRowLayout = .standard
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: layout.horizontalInset) {
            icon().frame(width: 26, height: 26)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, layout.horizontalInset).frame(height: height)
            .background(selected ? Color.primary.opacity(contrast == .increased ? 0.22 : 0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
