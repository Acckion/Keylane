import SwiftUI

/// Reveal the native accessory bezel only while the pointer is inside the control.
struct NativeHoverButton<Label: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Button(action: action) {
                label()
                    .hidden()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.accessoryBarAction)
            .buttonBorderShape(.capsule)
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel(title)

            label()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
    }
}
