import SwiftUI

/// Host-specific geometry, shared by the shell, native editor and action alignment.
enum ConversationComposerStyle {
    case launcher, chat
    var editorMinimumHeight: CGFloat { self == .launcher ? 24 : 36 }
    var fieldMinimumHeight: CGFloat { editorMinimumHeight + 12 }
    var actionControlSide: CGFloat { self == .launcher ? 28 : 32 }
    var controlDiameter: CGFloat { fieldMinimumHeight }
    var reservedControlWidth: CGFloat { controlDiameter + 8 }
}

/// One shell keeps control centers aligned to the final text line as the editor grows upward.
struct ConversationComposer<Editor: View, Actions: View, AddButton: View>: View {
    let style: ConversationComposerStyle
    @ViewBuilder let editor: () -> Editor
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let addButton: () -> AddButton

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if style == .launcher {
                Color.clear.frame(width: VisualStyle.launcherControlDiameter, height: VisualStyle.launcherControlDiameter)
                    .allowsHitTesting(false).accessibilityHidden(true)
            } else {
                addButton().zIndex(1)
            }
            field
            if style == .launcher {
                Color.clear.frame(width: VisualStyle.launcherControlDiameter, height: VisualStyle.launcherControlDiameter)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var field: some View {
        let contents = HStack(alignment: .bottom, spacing: 8) {
            editor().frame(maxWidth: .infinity)
            actions().frame(height: style.editorMinimumHeight)
        }
        .padding(.horizontal, style == .launcher ? 14 : 16)
        .padding(.vertical, 6)
        if style == .launcher {
            contents.modifier(LauncherMenuSurface(open: false))
        } else {
            // 48pt single-line shell has 24pt semicircular ends; multiline retains the radius.
            contents.glassEffect(.regular, in: RoundedRectangle(cornerRadius: style.fieldMinimumHeight / 2))
        }
    }
}

/// Launcher owns the expanding menu surface; Chat supplies the same closed surface around this button.
struct ConversationFooterButton: View {
    let title: String
    let symbol: String
    var diameter: CGFloat = VisualStyle.launcherControlDiameter
    let action: () -> Void
    var body: some View {
        NativeHoverButton(title: title, action: action) {
            Image(systemName: symbol).font(.system(size: 18))
                .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
        .help(title)
    }
}
