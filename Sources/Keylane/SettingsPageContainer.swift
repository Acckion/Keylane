import SwiftUI

/// Owns the scrolling and navigation chrome for every settings destination.
/// Pages supply only their controls; none install their own toolbar background.
struct SettingsPageContainer<Content: View>: View {
    let title: String
    let symbol: String
    let subtitle: String
    let target: String?
    @ViewBuilder let content: () -> Content
    @Binding var headerScrolledAway: Bool
    @Environment(\.colorScheme) private var scheme

    init(title: String, symbol: String, subtitle: String, target: String?, headerScrolledAway: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
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
                VStack(spacing: 16) {
                    SettingsPageHeader(title: title, symbol: symbol, subtitle: subtitle)
                        .onGeometryChange(for: Bool.self) {
                            $0.frame(in: .scrollView).maxY <= 0
                        } action: { headerScrolledAway = $0 }
                    content()
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 30)
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(scheme == .dark ? Color(white: 0.065) : Color(white: 0.965))
            .toolbarBackground(.regularMaterial, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .onChange(of: target) { _, value in
                if let value { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }
}
