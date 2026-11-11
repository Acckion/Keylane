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
        .frame(minHeight: 46)
        .disabled(!available)
    }
}

/// Command rows already size themselves. Use this card to group commands
/// so settings groups do not add a second layer of row spacing.
struct CommandSettingsList<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    var emptyMessage = "暂无命令"
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            if items.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            ForEach(items, id: id) { item in
                row(item).padding(.horizontal, 14)
                if items.last.map({ $0[keyPath: id] }) != item[keyPath: id] {
                    Divider().opacity(0.4).padding(.horizontal, 14)
                }
            }
        }
        .modifier(SettingsSurface())
    }
}
