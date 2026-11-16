import SwiftUI

/// Reveal the native accessory bezel on hover while keeping the control accessible.
struct NativeHoverButton<Label: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .background {
            Button(action: {}) {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.accessoryBarAction)
            .buttonBorderShape(.capsule)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
    }
}
