import SwiftUI

/// Context, @ mentions and / commands share one list and keyboard selection.
struct AIChatComposerMenu: View {
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
    let activate: (Item) -> Void
    let dismiss: () -> Void
    @FocusState private var searchFocused: Bool

    static func height(items: [Item], searchable: Bool) -> CGFloat {
        let sections = items.indices.filter { $0 == 0 || items[$0 - 1].section != items[$0].section }.count
        return min(320, CGFloat(max(items.count, 1)) * 32 + CGFloat(sections) * 24 + 12) + (searchable ? 42 : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index == 0 || items[index - 1].section != item.section {
                                Text(item.section).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                            }
                            LauncherMenuRow(title: item.title, symbol: item.symbol,
                                selected: selection == item.id, compact: true,
                                activate: { activate(item) }, highlight: { selection = item.id }) {
                                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }.id(item.id)
                        }
                        if items.isEmpty { Text("没有匹配的项目").foregroundStyle(.secondary).padding(16) }
                    }.padding(6)
                }.onChange(of: scrollTarget) { _, id in if let id { proxy.scrollTo(id) } }
            }
            if searchable {
                Divider()
                TextField("搜索上下文…", text: $query).textFieldStyle(.plain).font(.system(size: 12))
                    .padding(12).focused($searchFocused)
                    .onSubmit { if let item = items.first(where: { $0.id == selection }) { activate(item) } }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onExitCommand(perform: dismiss)
            }
        }
        .frame(width: 290, height: Self.height(items: items, searchable: searchable))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12)) }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
        .onAppear { searchFocused = searchable; selection = items.first?.id }
        .onChange(of: items.map(\.id)) { _, ids in if !ids.contains(selection ?? "") { selection = ids.first } }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let index = selection.flatMap { id in items.firstIndex { $0.id == id } } ?? -1
        selection = items[min(items.count - 1, max(0, index + delta))].id
        scrollTarget = selection
    }
}
