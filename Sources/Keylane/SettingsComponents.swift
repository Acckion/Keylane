import SwiftUI
import KeylaneCore

/// Shared surfaces for all settings pages; colors follow the system appearance.
struct SettingsSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SettingsIcon: View {
    let symbol: String
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: 14 * size / 24, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.gray.gradient, in: RoundedRectangle(cornerRadius: size / 4))
            .accessibilityHidden(true)
    }
}

struct SettingsPageHeader: View {
    let title: String
    let symbol: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            if symbol == "calendar" {
                CalendarSettingsIcon(size: 36)
            } else {
                SettingsIcon(symbol: symbol, size: 36)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 21, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
    }
}

/// The label can wrap while the trailing control keeps its natural width.
struct SettingsRow<Label: View, Control: View>: View {
    @ViewBuilder let label: () -> Label
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            label().frame(maxWidth: .infinity, alignment: .leading)
            control().fixedSize(horizontal: true, vertical: false)
        }
        .font(VisualStyle.rowText)
    }
}

extension SettingsRow where Label == SettingsRowLabel {
    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.label = { SettingsRowLabel(title: title, detail: detail) }
        self.control = control
    }
}

/// Settings pages choose a role; the shared component owns typography.
struct SettingsTitle: View {
    enum Role { case row, section }

    let text: String
    let role: Role

    init(_ text: String, role: Role = .row) {
        self.text = text
        self.role = role
    }

    var body: some View {
        Text(text).font(role == .row ? VisualStyle.rowText : .system(size: 15, weight: .medium))
    }
}

/// Secondary copy describing a setting, shared by rows and cards.
struct SettingsDescription: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsRowLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsTitle(title)
            if let detail, !detail.isEmpty {
                SettingsDescription(detail)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, detail?.isEmpty == false ? 9 : 0)
    }
}

struct SettingsActionRow: View {
    let title: String
    var detail: String? = nil
    let actionTitle: String
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        SettingsRow(title, detail: detail) {
            Button(actionTitle, role: role, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

struct SettingsDisclosureRow: View {
    let title: String
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            SettingsRow(title) {
                Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "已展开" : "已折叠")
    }
}

/// Preview-backed choices retain an explicit selection outline in light and dark mode.
struct SettingsChoiceTile<Preview: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let preview: () -> Preview

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                preview()
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? Color.accentColor : .primary.opacity(0.12),
                                          lineWidth: selected ? 2 : 1)
                            .allowsHitTesting(false)
                    }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Keep the label flexible and the native switch aligned to the trailing edge.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SettingsRow {
            configuration.label
        } control: {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

struct SettingsPicker<Selection: Hashable, Options: View>: View {
    let title: String
    let detail: String?
    @Binding var selection: Selection
    let options: Options

    init(_ title: String, detail: String? = nil, selection: Binding<Selection>, @ViewBuilder content: () -> Options) {
        self.title = title
        self.detail = detail
        self._selection = selection
        self.options = content()
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
        }
    }
}

/// Ordinary rows have a 46pt minimum. Taller content gets room to fit.
/// Dividers occupy only their one-pixel line; groups add no vertical padding.
struct SettingsRowsLayout: Layout {
    static let rowHeight: CGFloat = 46
    var compact = false
    private func height(_ view: LayoutSubview, width: CGFloat?) -> CGFloat {
        let contentHeight = view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        if contentHeight <= 1 { return contentHeight }
        return compact ? max(32, contentHeight + 8) : max(Self.rowHeight, contentHeight + 16)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 400, height: subviews.reduce(0) { $0 + height($1, width: proposal.width) })
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for view in subviews {
            let h = height(view, width: bounds.width)
            view.place(at: CGPoint(x: bounds.minX, y: y + h / 2), anchor: .leading, proposal: ProposedViewSize(width: bounds.width, height: h))
            y += h
        }
    }
}
struct SettingsRows<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        SettingsRowsLayout { content }.padding(.horizontal, 18)
    }
}
struct SettingsGroup<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.headline).padding(.horizontal, 18)
                    .accessibilityAddTraits(.isHeader)
            }
            SettingsRows { content }.modifier(SettingsSurface())
        }
    }
}

/// Standard card surfaces using existing settings layout metrics.
struct SettingsCard<Content: View>: View {
    enum Layout {
        case flush
        case padded
    }

    var layout: Layout = .padded
    var anchor: SettingsItem?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let anchor { surface.id(anchor.id) }
        else { surface }
    }

    @ViewBuilder private var surface: some View {
        switch layout {
        case .flush:
            content().frame(maxWidth: .infinity, alignment: .leading).modifier(SettingsSurface())
        case .padded:
            VStack(alignment: .leading, spacing: 11, content: content)
                .padding(14).modifier(SettingsSurface())
        }
    }
}

struct SettingsPageSections<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18, content: content)
    }
}

struct SettingsSectionTitle: View {
    let title: String

    var body: some View {
        SettingsTitle(title, role: .section)
            .padding(.leading, 14).padding(.top, 10)
    }
}

struct SettingsCaption: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SettingsTitle(title, role: .section)
            SettingsDescription(detail)
        }
    }
}

struct SettingsAddFolderButton: View {
    var symbolFont: Font?
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "plus").font(symbolFont) }
            .buttonStyle(ContentActionButtonStyle()).buttonBorderShape(.circle).controlSize(.small)
            .help("添加搜索文件夹")
    }
}


extension View {
    func settingsAnchor(_ item: SettingsItem) -> some View { id(item.id) }
}


struct SettingsCompactList<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        let firstID = items.first.map { $0[keyPath: id] }
        SettingsRowsLayout(compact: true) {
            ForEach(items, id: id) { item in
                if item[keyPath: id] != firstID { Divider().opacity(0.4) }
                row(item)
            }
        }
    }
}

struct SettingsFolderRow<Actions: View>: View {
    let path: String
    var selectable = false
    var showsActionsOnHover = false
    @ViewBuilder let actions: () -> Actions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder").font(VisualStyle.actionSymbol).frame(width: 18)
            Group {
                if selectable { pathLabel.textSelection(.enabled) }
                else { pathLabel }
            }
            Spacer(minLength: 4)
            actions().opacity(!showsActionsOnHover || hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }.help(path)
    }

    private var pathLabel: some View {
        Text((path as NSString).abbreviatingWithTildeInPath)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .lineLimit(selectable ? 2 : 1).truncationMode(.middle)
    }
}


/// Shortcut-only settings share the same label and recorder alignment.
struct SettingsShortcutBindingRow: View {
    let title: String
    let shortcut: Shortcut?
    var symbol = "keyboard"
    let change: (Shortcut?) -> Void

    var body: some View {
        SettingsRow(title) {
            ShortcutRecorder(shortcut: shortcut, title: title, icon: AnyView(Image(systemName: symbol)), changed: change)
        }
    }
}
