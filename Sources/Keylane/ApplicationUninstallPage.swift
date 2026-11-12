import Combine
import KeylaneCore
import SwiftUI

final class ApplicationUninstallSelection: ObservableObject {
    @Published private(set) var items: [ApplicationPreferenceItem] = []
    @Published var isLoading = false
    @Published private(set) var selectedID: String?
    private var candidates: [ApplicationPreferenceItem] = []
    private var query = ""

    var selected: ApplicationPreferenceItem? { items.first { $0.id == selectedID } }

    func load(_ candidates: [ApplicationPreferenceItem]) {
        self.candidates = candidates
        applyFilter()
    }

    func clear() {
        isLoading = false
        query = ""
        candidates = []
        items = []
        selectedID = nil
    }

    func filter(_ query: String) {
        guard query != self.query else { return }
        selectedID = nil
        self.query = query
        applyFilter()
    }

    private func applyFilter() {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        items = candidates.filter { item in
            tokens.allSatisfy { token in
                item.title.localizedCaseInsensitiveContains(token) || item.id.localizedCaseInsensitiveContains(token)
            }
        }
        if selected == nil { selectedID = items.first?.id }
    }

    func remove(_ path: String) {
        candidates.removeAll { $0.id == path }
        applyFilter()
    }

    func select(_ id: String) { selectedID = id }

    func move(_ delta: Int) {
        guard let selectedID, let index = items.firstIndex(where: { $0.id == selectedID }) else { return }
        select(items[NavigationBounds.move(index, by: delta, count: items.count)].id)
    }
}

struct ApplicationUninstallPage: View {
    @ObservedObject var selection: ApplicationUninstallSelection
    let submit: () -> Void

    var body: some View {
        SelectableResultList(selection: selection.selectedID, firstResult: selection.items.first?.id) {
            if selection.isLoading && selection.items.isEmpty {
                ProgressView("正在读取应用…").controlSize(.small)
                    .padding(20).frame(maxWidth: .infinity)
            } else if selection.items.isEmpty {
                Text("没有可卸载的应用").foregroundStyle(.secondary)
                    .padding(20).frame(maxWidth: .infinity)
            }
            ForEach(selection.items) { item in
                ResultListButton(id: item.id, action: {
                    selection.select(item.id)
                    submit()
                }) {
                    ResultListRow(selected: item.id == selection.selectedID) {
                        WorkspaceItemIcon(path: item.id)
                    } content: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(VisualStyle.rowText).lineLimit(1)
                            Text(item.id).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
        }
    }
}
