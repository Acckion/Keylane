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
    @Published private(set) var loadFailed = false
    @Published var selection: ResultGridSelection<String>?
    @Published var category = "all" { didSet { if oldValue != category { refresh(resetSelection: true) } } }
    var query = "" { didSet { if oldValue != query { refresh(resetSelection: true) } } }

    private var items: [EmojiItem] = []
    private var grouped: [String: [EmojiItem]] = [:]
    private var itemsByID: [String: EmojiItem] = [:]
    private var history = UserDefaults.standard.dictionary(forKey: recentsKey) as? [String: Int] ?? [:]

    var selected: EmojiItem? { selection.flatMap { itemsByID[$0.itemID] } }

    func start() {
        guard items.isEmpty, !isLoading else { return }
        isLoading = true
        loadFailed = false
        Task { @MainActor in
            let loaded = await Task.detached(priority: .userInitiated) { try? EmojiCatalog.load() }.value
            isLoading = false
            guard let loaded else { loadFailed = true; return }
            items = loaded
            grouped = Dictionary(grouping: loaded, by: \.category)
            itemsByID = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            refresh(resetSelection: true)
        }
    }

    func recordUse(_ item: EmojiItem) {
        history[item.id, default: 0] += 1
        UserDefaults.standard.set(history, forKey: Self.recentsKey)
        refresh(resetSelection: false)
    }

    func move(_ delta: Int, vertical: Bool) {
        guard let selection,
              let sectionIndex = sections.firstIndex(where: { $0.id == selection.sectionID }),
              let index = sections[sectionIndex].items.firstIndex(where: { $0.id == selection.itemID }) else { return }
        let section = sections[sectionIndex]
        let columns = Self.columnCount
        let destination = index + (vertical ? columns : 1) * delta
        if section.items.indices.contains(destination) {
            select(section, index: destination)
        } else if vertical && delta > 0 && (index / columns + 1) * columns < section.items.count {
            select(section, index: section.items.count - 1)
        } else if sections.indices.contains(sectionIndex + delta) {
            let next = sections[sectionIndex + delta]
            let start = delta < 0 ? next.items.count - 1 : 0
            let target = vertical ? (start / columns) * columns + index % columns : start
            select(next, index: min(target, next.items.count - 1))
        }
    }

    private func select(_ section: ResultGridSection<EmojiItem>, index: Int) {
        selection = .init(sectionID: section.id, itemID: section.items[index].id)
    }

    private func refresh(resetSelection: Bool) {
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
            let ranked = items.enumerated().compactMap { index, item -> (Int, Int, EmojiItem)? in
                guard enabled.contains(item.category) else { return nil }
                let score: Int
                if item.glyph == phrase || item.english.lowercased() == phrase || item.chinese == phrase { score = 0 }
                else if item.english.lowercased().hasPrefix(phrase) || item.chinese.hasPrefix(phrase) { score = 1 }
                else if terms.allSatisfy({ item.searchTerms.contains($0) || item.glyph.contains($0) }) { score = 2 }
                else { return nil }
                return (score, index, item)
            }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map { $0.2 }
            if !ranked.isEmpty { updated.append(.init(id: "results", title: EmojiCatalog.label("搜索结果", "Results"), items: ranked)) }
        }
        sections = updated
        if !resetSelection, let selection,
           updated.first(where: { $0.id == selection.sectionID })?.items.contains(where: { $0.id == selection.itemID }) == true {
            return
        }
        if let first = updated.first { select(first, index: 0) }
        else { selection = nil }
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
                if controller.isLoading { ProgressView() }
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
