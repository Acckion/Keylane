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
        VStack(spacing: 10) {
            Group {
                if symbol == "calendar" {
                    CalendarSettingsIcon()
                } else {
                    SettingsIcon(symbol: symbol, large: true)
                }
            }.padding(.bottom, 4)
            Text(title).font(.system(size: 24, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .modifier(SettingsSurface())
        .accessibilityElement(children: .combine)
    }
}

/// Keep the label flexible and the native switch aligned to the trailing edge.
struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 20) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
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
        HStack(spacing: 20) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Picker(title, selection: $selection) { options }
                .labelsHidden()
                .pickerStyle(.automatic)
                .buttonStyle(.automatic)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Ordinary rows have a 46pt minimum. Taller content gets room to fit.
/// Dividers occupy only their one-pixel line; groups add no vertical padding.
struct SettingsRowsLayout: Layout {
    static let rowHeight: CGFloat = 46
    private func height(_ view: LayoutSubview, width: CGFloat?) -> CGFloat {
        let contentHeight = view.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        if contentHeight <= 1 { return contentHeight }
        return max(Self.rowHeight, contentHeight + 16)
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
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { SettingsRows { content }.modifier(SettingsSurface()) }
}
