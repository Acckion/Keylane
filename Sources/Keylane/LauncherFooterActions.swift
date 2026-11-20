import SwiftUI
import AppKit

/// One sizing policy for every Launcher primary action, including single-button forms.
struct LauncherFooterActionBar: View {
    let title: String
    let keys: [String]
    let enabled: Bool
    let showsActions: Bool
    var actionsTitle = "操作"
    let perform: () -> Void
    let showActions: () -> Void

    static let maximumWidth: CGFloat = 360
    private static let inset: CGFloat = 4
    private var primary: LauncherFooterButtonLabel { .init(title: title, keys: keys) }
    private var actions: LauncherFooterButtonLabel { .init(title: actionsTitle, keys: ["⌘", "K"]) }
    private var actionsWidth: CGFloat { showsActions ? actions.width : 0 }
    var width: CGFloat { min(Self.maximumWidth, primary.width + actionsWidth + Self.inset * 2) }
    var primaryWidth: CGFloat { width - actionsWidth - Self.inset * 2 }

    var body: some View {
        HStack(spacing: 0) {
            NativeHoverButton(title: title, action: perform) { primary }
                .frame(width: primaryWidth, height: 28)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .help(title)
            if showsActions {
                NativeHoverButton(title: actions.title, action: showActions) { actions }
                    .frame(width: actionsWidth, height: 28)
            }
        }
        .padding(Self.inset)
        .frame(width: width, height: VisualStyle.launcherControlDiameter)
    }
}

struct LauncherFooterButtonLabel: View {
    let title: String
    let keys: [String]
    private let fontSize: CGFloat = 13
    private let titleSpacing: CGFloat = 7
    private let keySpacing: CGFloat = 3
    private let horizontalPadding: CGFloat = 10

    var width: CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let titleWidth = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        let keyWidth = CGFloat(keys.count) * Keycap.side + CGFloat(max(0, keys.count - 1)) * keySpacing
        return titleWidth + (keys.isEmpty ? 0 : titleSpacing) + keyWidth + 2 * horizontalPadding
    }

    var body: some View {
        HStack(spacing: titleSpacing) {
            Text(title).lineLimit(1).truncationMode(.tail)
            HStack(spacing: keySpacing) {
                ForEach(keys, id: \.self) { Keycap(text: $0) }
            }.fixedSize()
        }
        .font(.system(size: fontSize, weight: .medium))
        .padding(.horizontal, horizontalPadding)
    }
}

