import AppKit
import Combine
import KeylaneCore
import SwiftUI

/// A review is a snapshot. Filtering never changes the explicit selection or the targets
/// passed to the existing identity-checked trash operation.
final class ApplicationUninstallReview: ObservableObject {
    static let pageID = PageID(rawValue: "ApplicationUninstallReview")
    struct Item: Identifiable {
        let url: URL
        let isApplication: Bool
        var id: String { url.path }
        var title: String { url.lastPathComponent }
        var directory: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
        init(url: URL, isApplication: Bool = false) {
            self.url = url
            self.isApplication = isApplication
        }
    }
    enum Sort: String, CaseIterable { case path, name
        var title: String { self == .path ? "按路径排序" : "按名称排序" } }
    @Published private(set) var sizes: [String: UninstallItemSize] = [:]
    @Published private(set) var items: [Item] = []
    @Published private(set) var selected = Set<String>()
    @Published private(set) var highlighted: String?
    @Published private(set) var query = ""
    @Published var sort = Sort.path
    @Published private(set) var isSubmitting = false
    private(set) var name = ""
    private let sizeQueue = DispatchQueue(label: "org.keylane.uninstall.preview-size", qos: .utility)
    private var sizing: DispatchWorkItem?
    private var confirm: ((Set<String>) -> Void)?
    private var cancel: (() -> Void)?

    var visible: [Item] {
        let tokens = query.split(whereSeparator: \.isWhitespace)
        return items.filter { item in tokens.allSatisfy { item.id.localizedCaseInsensitiveContains($0) } }
            .sorted {
                if $0.isApplication != $1.isApplication { return $0.isApplication }
                let lhs = sort == .path ? $0.id : $0.title
                let rhs = sort == .path ? $1.id : $1.title
                let comparison = lhs.localizedStandardCompare(rhs)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }
    var selectedSizeSummary: String {
        let chosen = items.filter { !$0.isApplication && selected.contains($0.id) }
        let measured = chosen.compactMap { sizes[$0.id] }
        guard measured.count == chosen.count else { return "计算中…" }
        return Self.sizeLabel(bytes: measured.reduce(0) { $0 + $1.bytes },
                              complete: measured.allSatisfy(\.complete))
    }

    func sizeLabel(for item: Item) -> String {
        guard let size = sizes[item.id] else { return "计算中…" }
        return Self.sizeLabel(bytes: size.bytes, complete: size.complete)
    }

    private static func sizeLabel(bytes: Int64, complete: Bool) -> String {
        let formatted = bytes == 0 ? "0 字节" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        if complete { return formatted }
        return bytes > 0 ? "≥ " + formatted : "无法统计"
    }

    var canSubmit: Bool { !isSubmitting && confirm != nil && items.contains { $0.isApplication && selected.contains($0.id) } }

    func prepare(name: String, items: [Item], confirm: @escaping (Set<String>) -> Void, cancel: @escaping () -> Void) {
        clear()
        self.name = name
        self.confirm = confirm
        self.cancel = cancel
        self.items = items
        selected = Set(items.filter(\.isApplication).map(\.id))
        highlighted = items.first?.id
        measureSizes(items)
    }

    private func measureSizes(_ items: [Item]) {
        let request = DispatchWorkItem {}
        sizing = request
        sizeQueue.async { [weak self] in
            // Leftovers appear first in the selection total. Defer the app bundle itself.
            for item in items.filter({ !$0.isApplication }) + items.filter(\.isApplication) {
                guard let size = UninstallItemSize.measure(item.url, cancelled: { request.isCancelled }) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sizing === request else { return }
                    self.sizes[item.id] = size
                }
            }
        }
    }
    func filter(_ text: String) {
        query = text
        if !visible.contains(where: { $0.id == highlighted }) { highlighted = visible.first?.id }
    }
    func move(_ delta: Int) {
        let rows = visible
        guard !rows.isEmpty else { highlighted = nil; return }
        let index = rows.firstIndex { $0.id == highlighted } ?? 0
        highlighted = rows[NavigationBounds.move(index, by: delta, count: rows.count)].id
    }
    func toggle(_ id: String) {
        guard !isSubmitting, items.contains(where: { $0.id == id }) else { return }
        highlighted = id
        if !selected.insert(id).inserted { selected.remove(id) }
    }
    func toggleHighlighted() { if let highlighted { toggle(highlighted) } }
    func submit() {
        guard canSubmit, let confirm else { return }
        isSubmitting = true
        self.confirm = nil
        cancel = nil
        confirm(selected)
    }
    /// Hiding the launcher cancels the snapshot but preserves its page ID.
    /// Resume must leave an invalidated review, never recreate deletion consent.
    func resume(returnToSelection: () -> Void) {
        guard items.isEmpty else { return }
        returnToSelection()
    }
    func clear() {
        let cancel = self.cancel
        self.cancel = nil
        confirm = nil
        sizing?.cancel()
        sizing = nil
        sizes = [:]
        items = []
        selected = []
        highlighted = nil
        query = ""
        sort = .path
        isSubmitting = false
        name = ""
        cancel?()
    }
}

struct ApplicationUninstallReviewPage: View {
    @ObservedObject var review: ApplicationUninstallReview

    var body: some View {
        SelectableResultList(selection: review.highlighted, firstResult: review.visible.first?.id) {
            HStack(spacing: 10) {
                Text("已选择 \(review.selected.count) / \(review.items.count) 项")
                Text("已选残留 \(review.selectedSizeSummary)").foregroundStyle(.secondary)
                Spacer()
            }.font(.caption).padding(.horizontal, 18).padding(.vertical, 10)
            if review.visible.isEmpty {
                Text("没有匹配的文件").foregroundStyle(.secondary).padding(20)
            }
            ForEach(review.visible) { item in
                ResultListButton(id: item.id, action: { review.toggle(item.id) }) {
                    ResultListRow(selected: item.id == review.highlighted) {
                        Image(systemName: review.selected.contains(item.id) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(review.selected.contains(item.id) ? Color.accentColor : Color.secondary)
                    } content: {
                        HStack(spacing: 10) {
                            Text(item.title).font(VisualStyle.rowText).lineLimit(1).layoutPriority(1)
                            Text(item.directory).font(VisualStyle.rowText).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(review.sizeLabel(for: item))
                                .font(.caption).foregroundStyle(.secondary)
                            WorkspaceItemIcon(path: item.id).frame(width: 22, height: 22)
                        }
                    }
                }
                .accessibilityLabel(item.title + "，" + item.directory)
                .accessibilityValue((review.selected.contains(item.id) ? "已勾选" : "未勾选") + "，" + review.sizeLabel(for: item))
                .help(item.id)
                .disabled(review.isSubmitting)
            }
        }
    }
}

struct ApplicationUninstallSortPicker: View {
    @ObservedObject var review: ApplicationUninstallReview
    @Binding var open: Bool
    let navigation: String

    var body: some View {
        ResultTypeFilter(selection: Binding(
            get: { review.sort.rawValue },
            set: { if let sort = ApplicationUninstallReview.Sort(rawValue: $0) { review.sort = sort } }
        ), options: ApplicationUninstallReview.Sort.allCases.map {
            .init(id: $0.rawValue, title: $0.title, symbol: "arrow.up.arrow.down")
        }, open: $open, navigation: navigation, width: 152,
           searchPlaceholder: "查找排序方式…", emptyTitle: "没有匹配的排序方式")
        .disabled(review.isSubmitting)
    }
}
