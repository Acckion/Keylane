import SwiftUI
import KeylaneCore

/// A command editor independent of the model that persists its settings.
/// Callers provide bindings so application paths and command IDs keep their existing semantics.
struct CommandSettingsRow<Icon: View>: View {
    let title: String
    @Binding var alias: String
    let shortcut: Shortcut?
    @Binding var isEnabled: Bool
    let setShortcut: (Shortcut?) -> Void
    @ViewBuilder let icon: () -> Icon
    var perform: (() -> Void)? = nil
    var available = true
    @FocusState private var aliasFocused: Bool
    @State private var aliasHovered = false

    var body: some View {
        HStack(spacing: 10) {
            icon().frame(width: 24, height: 24).accessibilityHidden(true)
            Group {
                if let perform {
                    Button(title, action: perform).buttonStyle(.plain)
                } else {
                    Text(title)
                }
            }
            .font(VisualStyle.rowText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField(available ? "别名" : "未实现", text: $alias)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .focused($aliasFocused)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(width: 78)
                .background(.primary.opacity(aliasFocused || aliasHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { aliasHovered = $0 }
                .onTapGesture { aliasFocused = true }
                .accessibilityLabel("\(title) 搜索别名")
            ShortcutRecorder(shortcut: shortcut, compact: true, title: title, icon: AnyView(icon()), changed: setShortcut)
                .frame(width: 112, alignment: .leading)
            Toggle("启用 \(title)", isOn: $isEnabled)
                .labelsHidden().toggleStyle(.checkbox).controlSize(.small)
        }
        .frame(minHeight: 54)
        .disabled(!available)
    }
}
