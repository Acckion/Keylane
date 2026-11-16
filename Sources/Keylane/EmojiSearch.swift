import AppKit
import SwiftUI

struct EmojiItem: Identifiable, Sendable {
    let glyph: String
    let category: String
    let english: String
    let chinese: String
    let searchTerms: String

    var id: String { glyph }
    var title: String { EmojiCatalog.usesChinese && !chinese.isEmpty ? chinese : english }
}

enum EmojiCatalog {
    static let usesChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

    static let categories: [ResultFilterOption] = [
        option("all", "全部分类", "All Categories", "square.grid.3x3"),
        option("people", "笑脸与人物", "Smileys & People", "face.smiling"),
        option("nature", "动物与自然", "Animals & Nature", "leaf"),
        option("food", "食物与饮料", "Food & Drink", "fork.knife"),
        option("travel", "旅行与地点", "Travel & Places", "airplane"),
        option("activity", "活动", "Activities", "figure.run"),
        option("objects", "物品", "Objects", "lightbulb"),
        option("emoji-symbols", "表情符号", "Emoji Symbols", "heart"),
        option("flags", "旗帜", "Flags", "flag"),
        option("greek", "希腊字母", "Greek Letters", "character"),
        option("math", "数学符号", "Math Symbols", "function"),
        option("arrows", "箭头", "Arrows", "arrow.right"),
        option("currency", "货币", "Currency", "dollarsign"),
        option("punctuation", "标点", "Punctuation", "textformat"),
        option("keyboard", "键盘符号", "Keyboard Symbols", "keyboard")
    ]

    static func label(_ chinese: String, _ english: String) -> String { usesChinese ? chinese : english }

    private static func option(_ id: String, _ chinese: String, _ english: String, _ symbol: String) -> ResultFilterOption {
        ResultFilterOption(id: id, title: label(chinese, english), symbol: symbol)
    }

    static func load() throws -> [EmojiItem] {
        var url = Bundle.main.url(forResource: "EmojiCatalog", withExtension: "tsv")
        #if DEBUG
        if url == nil {
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/EmojiCatalog.tsv")
        }
        #endif
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let data = try String(contentsOf: url, encoding: .utf8)
        let items = data.split(separator: "\n").compactMap { line -> EmojiItem? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard (3...5).contains(fields.count) else { return nil }
            return EmojiItem(glyph: String(fields[1]), category: String(fields[0]),
                            english: String(fields[2]), chinese: fields.count >= 4 ? String(fields[3]) : "",
                            searchTerms: fields.dropFirst(2).joined(separator: " ").lowercased())
        }
        guard !items.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return items
    }
}

final class EmojiSearchController: ObservableObject {
    static let columnCount = 8
    private static let recentsKey = "emojiRecentUsage"

    @Published private(set) var sections: [ResultGridSection<EmojiItem>] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published private(set) var loadFailed = false
    @Published var selection: ResultGridSelection<String>?
    @Published var category = "all" { didSet { if oldValue != category { refresh() } } }
    var query = "" { didSet { if oldValue != query { refresh() } } }

    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchRevision = 0
    private var active = false
    private var items: [EmojiItem] = []
    private var grouped: [String: [EmojiItem]] = [:]
    private var itemsByID: [String: EmojiItem] = [:]
    private let defaults: UserDefaults
    private var history: [String: Int]
    private var pendingSelection: ResultGridSelection<String>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        history = defaults.dictionary(forKey: Self.recentsKey) as? [String: Int] ?? [:]
    }

    var selected: EmojiItem? {
        guard active, let selection else { return nil }
        return sections.first { $0.id == selection.sectionID }?.items.first { $0.id == selection.itemID }
    }

    func start() {
        active = true
        if !items.isEmpty { refresh(); return }
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let loaded = try? EmojiCatalog.load()
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.loadTask = nil
                self.isLoading = false
                guard let loaded else { self.loadFailed = true; return }
                self.items = loaded
                self.grouped = Dictionary(grouping: loaded, by: \.category)
                self.itemsByID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.refresh()
            }
        }
    }

    func copy(_ item: EmojiItem, to pasteboard: NSPasteboard = .general) -> Int? {
        guard active, selected?.id == item.id else { return nil }
        pasteboard.clearContents()
        guard pasteboard.setString(item.glyph, forType: .string) else { return nil }
        recordUse(item)
        return pasteboard.changeCount
    }

    private func recordUse(_ item: EmojiItem) {
        history[item.id, default: 0] += 1
        defaults.set(history, forKey: Self.recentsKey)
        if query.split(whereSeparator: \.isWhitespace).isEmpty { refresh() }
    }

    func move(_ delta: Int, vertical: Bool) {
        let next = selection?.moving(delta, vertical: vertical, columns: Self.columnCount, in: sections)
        if next != selection { selection = next }
    }

    func stop() {
        active = false
        cancelSearch()
    }

    func releaseCatalog() {
        stop()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        loadFailed = false
        sections = []
        selection = nil
        items = []
        grouped = [:]
        itemsByID = [:]
        pendingSelection = nil
        query = ""
    }

    private func cancelSearch() {
        searchRevision &+= 1
        searchTask?.cancel()
        searchTask = nil
        if isSearching { isSearching = false }
    }

    private func refresh() {
        guard active else { return }
        let priorSelection = selection ?? pendingSelection
        cancelSearch()
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let groups = EmojiCatalog.categories.dropFirst().filter { category == "all" || category == $0.id }
        var updated: [ResultGridSection<EmojiItem>] = []
        if terms.isEmpty && category == "all" {
            let used = history.keys.sorted {
                let left = history[$0, default: 0], right = history[$1, default: 0]
                return left == right ? $0 < $1 : left > right
            }.compactMap { itemsByID[$0] }
            let suggestions = ["β", "λ", "😄", "😁", "😂", "😊", "😍", "😘", "☺️", "😜", "🤔", "😒", "😔", "😳", "😭", "❤️"]
                .compactMap { itemsByID[$0] }
            let first = used.isEmpty ? suggestions : Array(used.prefix(16))
            if !first.isEmpty {
                updated.append(.init(id: "frequent", title: used.isEmpty ? EmojiCatalog.label("推荐", "Suggested")
                                     : EmojiCatalog.label("常用", "Frequently Used"), items: first))
            }
        }
        if terms.isEmpty {
            for group in groups {
                if let matches = grouped[group.id], !matches.isEmpty {
                    updated.append(.init(id: group.id, title: group.title, items: matches))
                }
            }
        } else {
            let enabled = Set(groups.map(\.id))
            let phrase = terms.joined(separator: " ")
            let candidates = items
            let terms = terms.map(String.init)
            let revision = searchRevision
            pendingSelection = priorSelection
            // Drop the old selection immediately so Return cannot activate a stale result.
            publish([], retaining: nil)
            guard !candidates.isEmpty else { return }
            isSearching = true
            searchTask = Task.detached(priority: .userInitiated) { [weak self] in
                let ranked = Self.rank(candidates, categories: enabled, phrase: phrase, terms: terms)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.active, self.searchRevision == revision else { return }
                    let updated: [ResultGridSection<EmojiItem>] = ranked.isEmpty ? [] : [
                        .init(id: "results", title: EmojiCatalog.label("搜索结果", "Results"), items: ranked)
                    ]
                    self.pendingSelection = nil
                    self.publish(updated, retaining: priorSelection)
                    self.isSearching = false
                    self.searchTask = nil
                }
            }
            return
        }
        pendingSelection = nil
        publish(updated, retaining: priorSelection)
    }

    private func publish(_ updated: [ResultGridSection<EmojiItem>], retaining priorSelection: ResultGridSelection<String>?) {
        if !sections.isEmpty || !updated.isEmpty { sections = updated }
        let preferred = priorSelection.flatMap { previous -> ResultGridSelection<String>? in
            let section = updated.first { $0.id == previous.sectionID && $0.items.contains { $0.id == previous.itemID } }
                ?? updated.first { $0.items.contains { $0.id == previous.itemID } }
            return section.map { .init(sectionID: $0.id, itemID: previous.itemID) }
        }
        let next = ResultGridSelection.retaining(preferred, in: updated)
        if next != selection { selection = next }
    }

    private static func rank(_ items: [EmojiItem], categories: Set<String>, phrase: String, terms: [String]) -> [EmojiItem] {
        // Three stable buckets preserve the original score and catalogue ordering without sorting.
        var matches = Array(repeating: [EmojiItem](), count: 3)
        for item in items {
            if Task.isCancelled { return [] }
            guard categories.contains(item.category) else { continue }
            let english = item.english.lowercased()
            if item.glyph == phrase || english == phrase || item.chinese == phrase { matches[0].append(item) }
            else if english.hasPrefix(phrase) || item.chinese.hasPrefix(phrase) { matches[1].append(item) }
            else if terms.allSatisfy({ item.searchTerms.contains($0) || item.glyph.contains($0) }) { matches[2].append(item) }
        }
        return matches.flatMap { $0 }
    }
}

struct EmojiSearchPage: View {
    @ObservedObject var controller: EmojiSearchController
    let activate: (EmojiItem) -> Void

    var body: some View {
        ResultGrid(sections: controller.sections, selection: $controller.selection,
                   columnCount: EmojiSearchController.columnCount, itemTitle: { $0.title }, activate: activate) { item in
            Text(item.glyph)
                .font(.system(size: 42))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        } emptyState: {
            Group {
                if controller.isLoading || controller.isSearching { Text(EmojiCatalog.label("正在加载…", "Loading…")) }
                else if controller.loadFailed {
                    Button(EmojiCatalog.label("重新加载符号目录", "Reload Symbol Catalog")) { controller.start() }
                        .buttonStyle(ContentActionButtonStyle())
                } else {
                    ContentUnavailableView(EmojiCatalog.label("没有匹配的 Emoji 或符号", "No Matching Emoji or Symbols"),
                                           systemImage: "face.smiling")
                }
            }.padding(.top, 50)
        }
    }
}
