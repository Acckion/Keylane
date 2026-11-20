import SwiftUI

/// The same typography and geometry apply to pinned, recent, project and archive rows.
enum AIChatStyle {
    static let sidebarRowHeight: CGFloat = 34
    static let sidebarInset: CGFloat = 8
    static let contentWidth: CGFloat = 980
}

struct AIChatSidebarHeading: View {
    let title: String
    let symbol: String
    var expanded: Binding<Bool>? = nil

    var body: some View {
        Group {
            if let expanded {
                Button { expanded.wrappedValue.toggle() } label: {
                    label(expanded: expanded.wrappedValue)
                }.buttonStyle(.plain)
            } else { label(expanded: nil) }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    private func label(expanded: Bool?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular)).frame(width: 16)
            Text(title).font(.system(size: 13, weight: .regular))
            Spacer(minLength: 4)
            if let expanded {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9))
            }
        }.foregroundStyle(.secondary).frame(height: 22).contentShape(Rectangle())
    }
}

struct AIChatSidebarRow: View {
    let title: String
    let selected: Bool
    var symbol: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title.isEmpty ? "新对话" : title).font(.system(size: 13, weight: .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let symbol { Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12)
            .frame(height: AIChatStyle.sidebarRowHeight)
            .background(.primary.opacity(selected ? 0.10 : hovering ? 0.045 : 0),
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
