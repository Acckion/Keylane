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
