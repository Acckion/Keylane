import SwiftUI
import KeylaneCore

struct CommandSettingsEntry<Icon: View> {
    let title: String
    let alias: Binding<String>
    let shortcut: Shortcut?
    let isEnabled: Binding<Bool>?
    let setShortcut: (Shortcut?) -> Void
    @ViewBuilder let icon: () -> Icon
    var perform: (() -> Void)? = nil
    var available = true
    var help: String?
    var menu: [CommandSettingsAction] = []
    /// Optional value snapshot for entries with a stable icon and stable handlers for this item ID.
    var renderRevision: AnyHashable?
}

struct CommandSettingsAction: Identifiable {
    var id: String { title }
    let title: String
    let perform: () -> Void
}

private enum CommandSettingsColumns {
    static let spacing: CGFloat = 10
    static let aliasWidth: CGFloat = 78
    static let shortcutWidth: CGFloat = 112
}

private struct CommandSettingsRow<Icon: View>: View {
    let entry: CommandSettingsEntry<Icon>
    let commandIdentity: AnyHashable
    @FocusState private var aliasFocused: Bool
    @State private var aliasHovered = false

    var body: some View {
        HStack(spacing: CommandSettingsColumns.spacing) {
            entry.icon().frame(width: 24, height: 24).accessibilityHidden(true)
            Group {
                if let perform = entry.perform {
                    Button(entry.title, action: perform).buttonStyle(.plain)
                } else {
                    Text(entry.title)
                }
            }
            .font(VisualStyle.rowText)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)

            TextField(entry.available ? "别名" : "未实现", text: entry.alias)
                .font(.system(size: 12))
                .textFieldStyle(.plain)
                .focused($aliasFocused)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .frame(width: CommandSettingsColumns.aliasWidth)
                .background(.primary.opacity(aliasFocused || aliasHovered ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { aliasHovered = $0 }
                .onTapGesture { aliasFocused = true }
                .accessibilityLabel("\(entry.title) 搜索别名")
                .id(commandIdentity)
            ShortcutRecorder(shortcut: entry.shortcut, title: entry.title, icon: { AnyView(entry.icon()) }, changed: entry.setShortcut)
                .id(commandIdentity)
                .frame(width: CommandSettingsColumns.shortcutWidth, alignment: .leading)
            if let isEnabled = entry.isEnabled {
                checkbox(isEnabled)
            } else {
                checkbox(.constant(false)).hidden().accessibilityHidden(true)
            }
        }
        .frame(minHeight: SettingsRowsLayout.rowHeight)
        .disabled(!entry.available)
        .onChange(of: commandIdentity) { _, _ in
            aliasFocused = false
            aliasHovered = false
        }
    }

    private func checkbox(_ enabled: Binding<Bool>) -> some View {
        Toggle("启用 \(entry.title)", isOn: enabled)
            .labelsHidden().toggleStyle(.checkbox).controlSize(.small)
    }
}

/// All command settings use this list. Callers supply data and actions only.
struct CommandSettingsList<Item, ID: Hashable, Icon: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    var emptyMessage = "暂无命令"
    var showsColumns = false
    var showsBackground = true
    let entry: (Item) -> CommandSettingsEntry<Icon>
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        if showsBackground { rows.modifier(SettingsSurface()) }
        else { rows }
    }

    private var rows: some View {
        let lastID = items.last.map { $0[keyPath: id] }
        return LazyVStack(spacing: 0) {
            if showsColumns, !items.isEmpty {
                HStack(spacing: CommandSettingsColumns.spacing) {
                    Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("别名").frame(width: CommandSettingsColumns.aliasWidth, alignment: .leading)
                    Text("快捷键").frame(width: CommandSettingsColumns.shortcutWidth, alignment: .leading)
                    Color.clear.frame(width: 14, height: 1)
                }.font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                CommandSettingsListDivider()
            }
            if items.isEmpty {
                CommandSettingsEmptyState(message: emptyMessage)
            }
            if items.count > 64, !voiceOverEnabled {
                CommandSettingsViewport(items: items) { item in
                    row(item, lastID: lastID)
                }
            } else {
                ForEach(items, id: id) { row($0, lastID: lastID) }
            }
        }
    }

    @ViewBuilder private func row(_ item: Item, lastID: ID?) -> some View {
        let identity = item[keyPath: id]
        let row = CommandSettingsListRow(entry: entry(item), commandIdentity: AnyHashable(identity), showsDivider: identity != lastID)
        if row.entry.renderRevision != nil { row.equatable() }
        else { row }
    }
}

/// Keeps the full scroll extent while instantiating only the nearby command rows.
private struct CommandSettingsViewport<Item, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row
    @Environment(\.displayScale) private var scale
    @State private var window = 0..<32

    var body: some View {
        let line = 1 / max(1, scale)
        let stride = SettingsRowsLayout.rowHeight + line
        let range = window.clamped(to: 0..<items.count)
        let totalHeight = CGFloat(items.count) * stride - line
        // Nearby rows retain their slots across ordinary scrolling. When a slot
        // wraps, only its command-specific editor and recorder are replaced.
        let slotCount = max(64, range.count)
        let slots = range.map { (id: $0 % slotCount, index: $0) }
        VStack(spacing: 0) {
            Color.clear.frame(height: min(totalHeight, CGFloat(range.lowerBound) * stride)).accessibilityHidden(true)
            ForEach(slots, id: \.id) { slot in
                row(items[slot.index]).frame(height: slot.index == items.count - 1 ? stride - line : stride)
            }
            Color.clear.frame(height: max(0, totalHeight - CGFloat(range.upperBound) * stride))
                .accessibilityHidden(true)
        }
        .frame(height: totalHeight, alignment: .top)
        .onGeometryChange(for: Range<Int>.self) { geometry in
            guard let viewport = geometry.bounds(of: .scrollView(axis: .vertical)) else { return 0..<min(32, items.count) }
            // Retain a few rows on each side for keyboard focus and fast scrolling.
            let first = Int(floor(viewport.minY / stride))
            let last = Int(ceil(viewport.maxY / stride))
            let start = max(0, min(items.count, first - 8))
            let end = max(start, min(items.count, last + 8))
            return start..<end
        } action: { window = $0 }
    }
}

struct CommandSettingsListDivider: View {
    var body: some View {
        Divider().opacity(0.4).padding(.horizontal, 14)
    }
}

struct CommandSettingsEmptyState: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(24)
    }
}

private struct CommandSettingsListRow<Icon: View>: View, Equatable {
    let entry: CommandSettingsEntry<Icon>
    let commandIdentity: AnyHashable
    let showsDivider: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard let revision = lhs.entry.renderRevision else { return false }
        return lhs.commandIdentity == rhs.commandIdentity && revision == rhs.entry.renderRevision && lhs.showsDivider == rhs.showsDivider
    }

    var body: some View {
        VStack(spacing: 0) {
            CommandSettingsRow(entry: entry, commandIdentity: commandIdentity)
                .padding(.horizontal, 14)
                .help(entry.help ?? "")
                .contextMenu {
                    ForEach(entry.menu) { action in Button(action.title, action: action.perform) }
                }
            if showsDivider { CommandSettingsListDivider() }
        }
    }
}

extension CommandSettingsEntry {
    /// Application aliases use the path, while their shortcut IDs retain the app: namespace.
    init(title: String, model: Model, commandID: CommandID, aliasKey: String? = nil,
         isEnabled: Binding<Bool>? = nil, perform: (() -> Void)? = nil, help: String? = nil,
         menu: [CommandSettingsAction] = [], renderRevision: AnyHashable? = nil, @ViewBuilder icon: @escaping () -> Icon) {
        let key = aliasKey ?? commandID.rawValue
        self.init(title: title,
                  alias: Binding(get: { model.aliases[key] ?? "" }, set: { model.setAlias(key, value: $0) }),
                  shortcut: model.bindings[commandID.rawValue],
                  isEnabled: isEnabled,
                  setShortcut: { model.setShortcut(commandID.rawValue, value: $0) },
                  icon: icon, perform: perform, help: help, menu: menu, renderRevision: renderRevision)
    }
}
