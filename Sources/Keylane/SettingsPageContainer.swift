import SwiftUI

/// Owns the scrolling and navigation chrome for every settings destination.
/// The settings window applies toolbar styling outside the scrolling content.
struct SettingsPageContainer<Content: View>: View {
    private enum Anchor: Hashable { case top }

    let pageID: String
    let title: String
    let symbol: String
    let subtitle: String
    let target: String?
    @ViewBuilder let content: () -> Content
    @Binding var headerScrolledAway: Bool
    @Environment(\.colorScheme) private var scheme

    init(pageID: String, title: String, symbol: String, subtitle: String, target: String?, headerScrolledAway: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.pageID = pageID
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
        self.target = target
        self._headerScrolledAway = headerScrolledAway
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).accessibilityHidden(true).id(Anchor.top)
                    VStack(spacing: 16) {
                        SettingsPageHeader(title: title, symbol: symbol, subtitle: subtitle)
                            .onGeometryChange(for: Bool.self) {
                                $0.frame(in: .scrollView).maxY <= 0
                            } action: { headerScrolledAway = $0 }
                        content().id(pageID)
                    }
                    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 30)
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(scheme == .dark ? Color(white: 0.065) : Color(white: 0.965))
            .onChange(of: pageID) { _, _ in proxy.scrollTo(Anchor.top, anchor: .top) }
            .onChange(of: target) { _, value in
                if let value { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }
}
