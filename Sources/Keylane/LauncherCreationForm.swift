import SwiftUI

/// Form content for launcher pages. The launcher host supplies the bottom actions.
struct LauncherCreationForm<Accessory: View, Fields: View>: View {
    let back: () -> Void
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
                VStack(spacing: 22, content: fields)
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
                control()
                    .accessibilityLabel(title)
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
