import SwiftUI

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
    var large = false

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: large ? 28 : 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: large ? 56 : 24, height: large ? 56 : 24)
            .background(.gray.gradient, in: RoundedRectangle(cornerRadius: large ? 13 : 6))
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
                SettingsIcon(symbol: symbol).scaleEffect(1.4).frame(width: 36, height: 36)
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

struct SettingsRowLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
    @Binding var selection: Selection
    let options: Options

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Options) {
        self.title = title
        self._selection = selection
        self.options = content()
    }

    var body: some View {
        SettingsRow(title) {
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.menu)
        }
    }
}

struct SettingsOwnRowHeight: LayoutValueKey {
    static let defaultValue = false
}

struct SettingsCompactList<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        SettingsRowsLayout(compact: true) {
            ForEach(items, id: id) { item in
                if item[keyPath: id] != items.first?[keyPath: id] {
                    Divider().opacity(0.4)
                }
                row(item)
            }
        }
        .layoutValue(key: SettingsOwnRowHeight.self, value: true)
    }
}

/// Ordinary rows have a 46pt minimum. Taller content gets room to fit.
/// Dividers occupy only their one-pixel line; groups add no vertical padding.
struct SettingsRowsLayout: Layout {
    static let rowHeight: CGFloat = 46
    var compact = false
    private func height(_ view: LayoutSubview, width: CGFloat?) -> CGFloat {
        let contentHeight = view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        if view[SettingsOwnRowHeight.self] || contentHeight <= 1 { return contentHeight }
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
    let compact: Bool
    init(compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.content = content()
    }
    var body: some View {
        SettingsRowsLayout(compact: compact) { content }.padding(.horizontal, 18)
    }
}
struct SettingsGroup<Content: View>: View {
    let title: String?
    let footer: String?
    let content: Content

    let compact: Bool

    init(_ title: String? = nil, footer: String? = nil, compact: Bool = false, @ViewBuilder content: () -> Content) {
        self.compact = compact
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.headline).padding(.horizontal, 18)
                    .accessibilityAddTraits(.isHeader)
            }
            SettingsRows(compact: compact) { content }.modifier(SettingsSurface())
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }
        }
    }
}
