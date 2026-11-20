import SwiftUI

/// Shared corner-menu layout. Hosts retain their action and native keyboard routing.
struct LauncherActionMenuPanel<Rows: View, Search: View>: View {
    static var width: CGFloat { 345 }
    let title: String
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let search: () -> Search

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 16).padding(.top, 13).padding(.bottom, 8)
            rows()
            Divider().padding(.top, 9)
            search().frame(height: 22).padding(.horizontal, 16).padding(.vertical, 10)
        }.frame(width: Self.width)
    }
}

/// Keep the same surface in the hierarchy while its bottom corner expands in place.
struct LauncherExpandingMenu<Closed: View, MenuContent: View>: View {
    let open: Bool
    let closedSize: CGSize
    let menuSize: CGSize
    var alignment: Alignment = .bottomLeading
    var tint: Color? = nil
    var dismiss: (() -> Void)? = nil
    @ViewBuilder let closed: () -> Closed
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        ZStack(alignment: alignment) {
            if open {
                menu().frame(width: menuSize.width, height: menuSize.height, alignment: .bottom)
                    .transition(.opacity)
            } else {
                closed().transition(.opacity)
            }
        }
        .frame(width: open ? menuSize.width : closedSize.width,
               height: open ? menuSize.height : closedSize.height, alignment: alignment)
        .background {
            if let dismiss { MenuOutsideClickDismissal(presented: open, dismiss: dismiss) }
        }
        .modifier(LauncherMenuSurface(open: open, tint: tint, cornerRadius: closedSize.height / 2))
    }
}
