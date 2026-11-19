import SwiftUI

/// Read-only rendering for the neighboring page while the active module still owns focus.
struct LauncherSwipePreview: View {
    struct Row: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }

    let title: String
    let badge: (title: String, symbol: String)?
    let rows: [Row]
    let detail: String?
    let emptyTitle: String

    var body: some View {
        ZStack(alignment: .top) {
            if rows.isEmpty {
                ResultDetailEmptyState(title: emptyTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if badge != nil {
                ResultDetailLayout(hasResults: true) {
                    resultRows
                } detail: {
                    Text(detail ?? rows[0].detail)
                        .multilineTextAlignment(.leading)
                        .lineLimit(8)
                        .padding(22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } emptyState: { EmptyView() }
            } else {
                resultRows
            }

            HStack(spacing: 12) {
                Image(systemName: badge == nil ? "magnifyingglass" : "chevron.backward")
                Text(title).lineLimit(1)
                Spacer()
            }
            .font(.system(size: 19))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 19)
            .frame(height: VisualStyle.launcherTopInset)

            if let badge {
                Label(badge.title, systemImage: badge.symbol)
                    .font(VisualStyle.sectionText)
                    .padding(10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(VisualStyle.launcherEdgeInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var resultRows: some View {
        ResultListScrollView {
            ForEach(rows) { row in
                ResultListRow(selected: row.id == rows.first?.id) {
                    Image(systemName: row.symbol)
                } content: {
                    HStack {
                        Text(row.title).lineLimit(1).font(VisualStyle.rowText)
                        Spacer()
                        if badge == nil, !row.detail.isEmpty {
                            Text(row.detail).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
