import SwiftUI

/// Form content for launcher pages. The launcher host supplies the bottom actions.
struct LauncherCreationForm<Accessory: View, Fields: View>: View {
    let back: () -> Void
    var spacing: CGFloat = 22
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let fields: () -> Fields

    var body: some View {
        VStack(spacing: 0) {
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

            ScrollView {
                VStack(spacing: spacing, content: fields)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// A full-width form control that uses the launcher's searchable option list.
struct LauncherCreationPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let values: [Value]
    @Binding var open: Bool
    let title: (Value) -> String
    @State private var query = ""
    @FocusState private var triggerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if open { dismiss() }
                else {
                    query = ""
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
            .accessibilityValue(title(selection))

            if open {
                ResultFilterPanel(selection: values.firstIndex(of: selection).map(String.init) ?? "",
                                  options: ResultFilterPanel.matches(options, query: query),
                                  query: $query, searchPlaceholder: "搜索…", emptyTitle: "没有匹配选项",
                                  width: width, maximumVisibleRows: 4, choose: { option in
                    guard let index = Int(option.id), values.indices.contains(index) else { return }
                    selection = values[index]
                    dismiss()
                }, dismiss: dismiss)
                .modifier(LauncherMenuSurface(open: true))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @State private var width: CGFloat = 366

    private var options: [ResultFilterOption] {
        values.indices.map { index in
            ResultFilterOption(id: String(index), title: title(values[index]), symbol: "")
        }
    }

    private func dismiss() {
        open = false
        triggerFocused = true
    }
}
