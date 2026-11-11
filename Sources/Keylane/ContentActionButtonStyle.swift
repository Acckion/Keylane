import SwiftUI

/// Content actions use a flat surface; glass is reserved for floating navigation chrome.
struct ContentActionButtonStyle: ButtonStyle {
    var prominent = false
    var cornerRadius: CGFloat = 7
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        ContentActionButton(configuration: configuration, prominent: prominent, cornerRadius: cornerRadius, active: active)
    }
}

private struct ContentActionButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let cornerRadius: CGFloat
    let active: Bool
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        configuration.label
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(configuration.role == .destructive ? Color.red : prominent ? Color.white : Color.primary)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
    private var background: Color {
        if prominent { return .accentColor.opacity(configuration.isPressed ? 0.7 : hovered ? 0.9 : 1) }
        return .primary.opacity(configuration.isPressed ? 0.13 : (hovered || active) && enabled ? 0.08 : 0)
    }
}
