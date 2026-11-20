import SwiftUI

/// Context, @ mentions and / commands share one list and keyboard selection.
struct AIConversationComposerMenu: View {
    struct Item: Identifiable {
        let id: String
        let section: String
        let title: String
        let symbol: String
        var detail = ""
        let action: () -> Void
    }
    let items: [Item]
    @Binding var query: String
    @Binding var selection: String?
    @Binding var scrollTarget: String?
    var searchable = false
    var menuTitle = "AI Chat"
    let activate: (Item) -> Void
    let dismiss: () -> Void

    static func height(items: [Item], searchable: Bool) -> CGFloat {
        if searchable { return min(320, CGFloat(max(items.count, 1)) * 39) + 87 }
        let sections = items.indices.filter { $0 == 0 || items[$0 - 1].section != items[$0].section }.count
        return min(320, CGFloat(max(items.count, 1)) * 32 + CGFloat(sections) * 24 + 12) + (searchable ? 42 : 0)
    }

    var body: some View {
        Group {
            if searchable {
                LauncherActionMenuPanel(title: menuTitle) {
                    menuRows(compact: false)
                        .frame(height: min(320, CGFloat(max(items.count, 1)) * 39))
                } search: {
                    SearchField(text: $query, placeholder: "搜索操作…", focusToken: 0, compact: true,
                        submit: { if let item = items.first(where: { $0.id == selection }) { activate(item) } },
                        move: move, escape: dismiss)
                }
                .modifier(LauncherMenuSurface(open: true))
            } else {
                menuRows(compact: true)
                    .frame(width: 290, height: Self.height(items: items, searchable: false))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)) }
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .onAppear { selection = items.first?.id }
        .onChange(of: items.map(\.id)) { _, ids in if !ids.contains(selection ?? "") { selection = ids.first } }
    }

    private func menuRows(compact: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 2 : 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if compact && (index == 0 || items[index - 1].section != item.section) {
                            Text(item.section).font(.system(size: 11)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                        }
                        LauncherMenuRow(title: item.title, symbol: item.symbol,
                            selected: selection == item.id, compact: compact,
                            activate: { activate(item) }, highlight: { selection = item.id }) {
                                Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }.id(item.id)
                    }
                    if items.isEmpty { Text("没有匹配的操作").foregroundStyle(.secondary).padding(16) }
                }
                .padding(.horizontal, compact ? 6 : 8)
                .padding(.vertical, compact ? 6 : 0)
            }.onChange(of: scrollTarget) { _, id in if let id { proxy.scrollTo(id) } }
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = selection.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        selection = items[min(items.count - 1, max(0, index + delta))].id
        scrollTarget = selection
    }
}
