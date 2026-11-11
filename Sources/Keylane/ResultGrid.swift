import SwiftUI
import KeylaneCore

struct ResultGridSection<Item: Identifiable>: Identifiable {
    let id: String
    let title: String
    let items: [Item]
}

/// Includes the section so an item can appear in both Recents and a category.
struct ResultGridSelection<ItemID: Hashable>: Hashable {
    let sectionID: String
    let itemID: ItemID

    static func retaining<Item>(_ current: Self?, in sections: [ResultGridSection<Item>]) -> Self?
    where Item.ID == ItemID {
        if let current, sections.first(where: { $0.id == current.sectionID })?.items.contains(where: { $0.id == current.itemID }) == true {
            return current
        }
        guard let first = sections.first(where: { !$0.items.isEmpty }), let item = first.items.first else { return nil }
        return Self(sectionID: first.id, itemID: item.id)
    }

    func moving<Item>(_ delta: Int, vertical: Bool, columns: Int, in sections: [ResultGridSection<Item>]) -> Self
    where Item.ID == ItemID {
        guard let section = sections.firstIndex(where: { $0.id == sectionID }),
              let item = sections[section].items.firstIndex(where: { $0.id == itemID }),
              let target = NavigationBounds.moveGrid(section: section, item: item, by: delta,
                                                     vertical: vertical, columns: columns, counts: sections.map { $0.items.count })
        else { return self }
        let group = sections[target.section]
        return Self(sectionID: group.id, itemID: group.items[target.item].id)
    }

}

/// Reusable launcher grid. The caller owns filtering, selection and activation.
struct ResultGrid<Item: Identifiable, Tile: View, EmptyState: View>: View {
    let sections: [ResultGridSection<Item>]
    @Binding var selection: ResultGridSelection<Item.ID>?
    var columnCount = 8
    var showsCounts = true
    var contentInset: CGFloat = 8
    var caption: ((Item) -> String)? = nil
    let itemTitle: (Item) -> String
    let activate: (Item) -> Void
    @ViewBuilder let tile: (Item) -> Tile
    @ViewBuilder let emptyState: () -> EmptyState

    private let spacing: CGFloat = 8

    var body: some View {
        ScrollViewReader { proxy in
            ResultListScrollView {
                if sections.allSatisfy({ $0.items.isEmpty }) {
                    emptyState().frame(maxWidth: .infinity)
                }
                ForEach(sections.filter { !$0.items.isEmpty }) { section in
                    VStack(alignment: .leading, spacing: spacing) {
                        HStack(spacing: 10) {
                            Text(section.title)
                            if showsCounts {
                                Text(section.items.count.formatted())
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .font(VisualStyle.sectionText)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: spacing),
                                                  count: max(1, columnCount)), spacing: spacing) {
                            ForEach(section.items) { item in
                                let id = ResultGridSelection(sectionID: section.id, itemID: item.id)
                                VStack(alignment: .leading, spacing: 7) {
                                    ResultGridTile(selected: selection == id, inset: contentInset) {
                                        selection = id
                                        activate(item)
                                    } content: {
                                        tile(item)
                                    }
                                    .accessibilityLabel(itemTitle(item))
                                    if let caption {
                                        Text(caption(item)).font(VisualStyle.rowText).lineLimit(1)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .help(itemTitle(item))
                                .id(id)
                            }
                        }
                    }
                    .padding(.vertical, spacing)
                }
            }
            .onChange(of: selection) { _, value in
                if let value { proxy.scrollTo(value) }
            }
        }
    }
}

private struct ResultGridTile<Content: View>: View {
    let selected: Bool
    let inset: CGFloat
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11)
        Button(action: action) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { content().padding(inset) }
                .background(.primary.opacity(selected ? 0.14 : hovered ? 0.10 : 0.05), in: shape)
                .clipShape(shape)
                .overlay {
                    if selected { shape.strokeBorder(.primary.opacity(0.85), lineWidth: 2) }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
