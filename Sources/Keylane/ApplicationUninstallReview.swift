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
        let bytes: Int64?
        var id: String { url.path }
        var title: String { url.lastPathComponent }
        var directory: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
        init(url: URL, isApplication: Bool = false) {
            self.url = url
            self.isApplication = isApplication
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            // Do not recursively scan app data to estimate a directory's size.
            bytes = values?.isDirectory == false ? values?.fileSize.map(Int64.init) : nil
        }
    }
    enum Sort: String, CaseIterable { case path = "路径", name = "名称" }
    @Published private(set) var items: [Item] = []
    @Published private(set) var selected = Set<String>()
    @Published private(set) var highlighted: String?
    @Published private(set) var query = ""
    @Published var sort = Sort.path
    @Published private(set) var isSubmitting = false
    private(set) var name = ""
    private(set) var detail = ""
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
    var canSubmit: Bool { !isSubmitting && confirm != nil && items.contains { $0.isApplication && selected.contains($0.id) } }

    func prepare(name: String, detail: String, items: [Item], confirm: @escaping (Set<String>) -> Void, cancel: @escaping () -> Void) {
        clear()
        self.name = name
        self.detail = detail
        self.confirm = confirm
        self.cancel = cancel
        self.items = items
        selected = Set(items.filter(\.isApplication).map(\.id))
        highlighted = items.first?.id
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
    func clear() {
        let cancel = self.cancel
        self.cancel = nil
        confirm = nil
        items = []
        selected = []
        highlighted = nil
        query = ""
        sort = .path
        isSubmitting = false
        name = ""
        detail = ""
        cancel?()
    }
}

struct ApplicationUninstallReviewPage: View {
    @ObservedObject var review: ApplicationUninstallReview

    var body: some View {
        SelectableResultList(selection: review.highlighted, firstResult: review.visible.first?.id) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("已选择 \(review.selected.count) / \(review.items.count) 项").font(.caption)
                    Spacer()
                    Picker("排序", selection: $review.sort) {
                        ForEach(ApplicationUninstallReview.Sort.allCases, id: \.self) { Text("按\($0.rawValue)").tag($0) }
                    }.fixedSize().labelsHidden().accessibilityLabel("文件排序")
                }
                Text(review.detail).font(.caption).foregroundStyle(.secondary)
                Text("应用及勾选的关联文件将移到废纸篓；关联文件可能包含设置和应用数据。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).padding(.vertical, 10)
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(VisualStyle.rowText).lineLimit(1)
                                Text(item.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(item.bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                                .font(.caption).foregroundStyle(.secondary)
                            WorkspaceItemIcon(path: item.id).frame(width: 22, height: 22)
                        }
                    }
                }
                .accessibilityLabel(item.title + "，" + item.directory)
                .accessibilityValue(review.selected.contains(item.id) ? "已勾选" : "未勾选")
                .help(item.id)
                .disabled(review.isSubmitting)
            }
        }
    }
}
