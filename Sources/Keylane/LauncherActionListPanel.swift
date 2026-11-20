import SwiftUI

/// Shared presentation for live Launcher actions and the isolated theme preview.
/// Hosts own command validation, selection and execution; this view owns no services.
struct LauncherActionListPanel: View {
    static let width: CGFloat = 345
    let title: String
    let items: [LauncherAction]
    let selectedID: String?
    @Binding var query: String
    let focusToken: Int
    let wantsFocus: Bool
    var navigation = "arrows"
    let activate: (String) -> Void
    let highlight: (String) -> Void
    let submit: () -> Void
    let move: (Int) -> Void
    let escape: () -> Void
    let forward: () -> Void
    let reconcile: ([String]) -> Void

    static func rowsHeight(_ items: [LauncherAction]) -> CGFloat {
        guard !items.isEmpty else { return 48 }
        let breaks = zip(items, items.dropFirst()).filter { $0.group != $1.group }.count
        return min(320, CGFloat(items.count * 39 + breaks * 9))
    }
    var body: some View {
        LauncherActionMenuPanel(title: title) {
            if items.isEmpty {
                Text("没有匹配的操作").font(.caption).foregroundStyle(.secondary).padding(16)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index > 0, items[index - 1].group != item.group { Divider().padding(.horizontal, 16).frame(height: 9) }
                                LauncherMenuRow(title: item.title, symbol: item.icon, selected: item.id == selectedID,
                                                enabled: item.enabled, destructive: item.destructive, artwork: item.artwork,
                                                activate: { activate(item.id) }, highlight: { highlight(item.id) }) {
                                    if let value = item.value { Text(value).font(VisualStyle.rowText).foregroundStyle(.secondary).lineLimit(1).help(value) }
                                    if !item.displayedKeys.isEmpty { Keycaps(keys: item.displayedKeys) }
                                    if item.submenu != nil { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary) }
                                }.padding(.horizontal, 8).id(item.id)
                            }
                        }
                    }.scrollIndicators(.automatic).frame(height: Self.rowsHeight(items))
                        .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                        .onChange(of: query) { _, _ in if let first = items.first { proxy.scrollTo(first.id, anchor: .top) } }
                }
            }
        } search: {
            SearchField(text: $query, placeholder: "搜索操作…", focusToken: focusToken, wantsFocus: wantsFocus, compact: true,
                        navigation: navigation, submit: submit, move: move, escape: escape, back: escape, forward: forward)
                .onChange(of: items.filter(\.enabled).map(\.id), initial: true) { _, ids in reconcile(ids) }
        }
    }
}
