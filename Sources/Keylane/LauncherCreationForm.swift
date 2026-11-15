import SwiftUI

/// Form content for launcher pages. The launcher host supplies the bottom actions.
struct LauncherCreationForm<Accessory: View, Fields: View>: View {
    let back: () -> Void
    var spacing: CGFloat = 22
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(spacing: spacing, content: fields)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .launcherScrollInsets()
            .launcherScrollEdgeFade()

            ChromeBlur()
                .frame(height: VisualStyle.launcherTopInset)
                .mask(LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.7), .clear],
                                     startPoint: .top, endPoint: .bottom))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("返回")
                .help("返回")

                Spacer()
                accessory()
            }
            .padding(VisualStyle.launcherEdgeInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlayPreferenceValue(CreationPickerMenuPreference.self) { menu in
            if let menu {
                GeometryReader { geometry in
                    let trigger = geometry[menu.anchor]
                    let below = geometry.size.height - VisualStyle.launcherBottomInset - trigger.maxY - 12
                    let above = trigger.minY - VisualStyle.launcherTopInset - 12
                    let opensAbove = below < 230 && above > below
                    let availableHeight = opensAbove ? above : below
                    let rows = min(8, max(1, Int((availableHeight - 66) / 43)))
                    menu.content(trigger.width, rows)
                        .id(menu.id)
                        .fixedSize()
                        .frame(width: trigger.width, height: max(0, availableHeight),
                               alignment: opensAbove ? .bottom : .top)
                        .offset(x: trigger.minX, y: opensAbove ? VisualStyle.launcherTopInset + 6 : trigger.maxY + 6)
                }
            }
        }
    }
}

private struct CreationPickerMenu {
    let id: String
    let anchor: Anchor<CGRect>
    let content: (CGFloat, Int) -> AnyView
}

private struct CreationPickerMenuPreference: PreferenceKey {
    static var defaultValue: CreationPickerMenu? { nil }

    static func reduce(value: inout CreationPickerMenu?, nextValue: () -> CreationPickerMenu?) {
        if let next = nextValue() { value = next }
    }
}

/// The control column stays centered, with a right-aligned label and optional help below.
struct LauncherCreationField<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: 130, alignment: .trailing)
                .frame(minHeight: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                if title.isEmpty { control() }
                else { control().accessibilityLabel(title) }
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 366, alignment: .leading)

            Color.clear.frame(width: 130, height: 0)
        }
    }
}

/// Shared outline for a text field or a composite control with a trailing accessory.
struct LauncherCreationControl<Content: View>: View {
    var focused = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        content()
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(.primary.opacity(0.05), in: shape)
            .overlay {
                shape.strokeBorder(.primary.opacity(focused ? 0.42 : 0.20), lineWidth: focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
    }
}

/// A full-width field whose searchable menu is hosted above the scroll content.
struct LauncherCreationPicker<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let values: [Value]
    @Binding var open: Bool
    let title: (Value) -> String
    @FocusState private var triggerFocused: Bool

    var body: some View {
        Button {
            if open { dismiss() }
            else {
                triggerFocused = false
                open = true
            }
        } label: {
            LauncherCreationControl(focused: open || triggerFocused) {
                HStack {
                    Text(title(selection))
                    Spacer()
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($triggerFocused)
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
        .anchorPreference(key: CreationPickerMenuPreference.self, value: .bounds) { anchor in
            guard open else { return nil }
            return CreationPickerMenu(id: label, anchor: anchor) { width, rows in
                AnyView(CreationPickerOptions(selection: $selection, values: values, title: title,
                                              width: width, rows: rows, dismiss: dismiss))
            }
        }
    }

    private func dismiss() {
        open = false
        triggerFocused = true
    }
}

private struct CreationPickerOptions<Value: Hashable>: View {
    @Binding var selection: Value
    let values: [Value]
    let title: (Value) -> String
    let width: CGFloat
    let rows: Int
    let dismiss: () -> Void
    @State private var query = ""

    var body: some View {
        let options = values.indices.map { index in
            ResultFilterOption(id: String(index), title: title(values[index]), symbol: "")
        }
        ResultFilterPanel(selection: values.firstIndex(of: selection).map(String.init) ?? "",
                          options: ResultFilterPanel.matches(options, query: query),
                          query: $query, searchPlaceholder: "搜索…", emptyTitle: "没有匹配选项",
                          width: width, maximumVisibleRows: rows, choose: { option in
            guard let index = Int(option.id), values.indices.contains(index) else { return }
            selection = values[index]
            dismiss()
        }, dismiss: dismiss)
        .onKeyPress(.escape) {
            guard !SearchField.isComposing else { return .ignored }
            dismiss()
            return .handled
        }
        .modifier(LauncherMenuSurface(open: true))
    }
}
