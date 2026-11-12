import AppKit
import Combine
import KeylaneCore

final class SnippetsController: ObservableObject {
    @Published private(set) var entries: [Snippet] = []
    @Published var query = "" { didSet { selectedID = visible.first?.id } }
    @Published var selectedID: String?
    @Published var draft = Snippet()
    @Published private(set) var error = ""
    @Published var expandsKeywords: Bool {
        didSet {
            preferences.set(expandsKeywords, forKey: "snippets.expandsKeywords")
            configureExpansion()
        }
    }
    @Published private(set) var expansionActive = false

    private let storageURL: URL
    private var store: Store?
    private let preferences: UserDefaults
    private let expansion = SnippetExpansion()
    private var active = false

    init(storageURL: URL, preferences: UserDefaults = .standard) {
        self.storageURL = storageURL
        self.preferences = preferences
        expandsKeywords = preferences.bool(forKey: "snippets.expandsKeywords")
    }

    var visible: [Snippet] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return entries.filter { snippet in
            let haystack = [snippet.title, snippet.keyword, snippet.text].joined(separator: "\n")
            return terms.allSatisfy { haystack.localizedStandardContains(String($0)) }
        }
    }

    var selected: Snippet? {
        let rows = visible
        return rows.first { $0.id == selectedID } ?? rows.first
    }

    func start() {
        active = true
        do {
            let store = try Store(url: storageURL)
            self.store = store
            let records = try store.records(kind: "snippet")
            entries = records.compactMap { try? Snippet.fromRecord($0) }
            error = entries.count == records.count ? "" : "部分片段无法读取，原始记录仍保留。"
            configureExpansion()
        } catch { self.error = "无法读取片段：\(error.localizedDescription)" }
    }

    func stop() {
        active = false
        expansion.stop()
        expansionActive = false
        store = nil
        entries = []
        query = ""
        selectedID = nil
        draft = Snippet()
        error = ""
    }

    func applicationFocused() {
        expansion.resetInput()
        if expandsKeywords && !expansionActive { configureExpansion() }
    }

    func configureExpansion() {
        if active && expandsKeywords { expansionActive = expansion.configure(entries) }
        else { expansion.stop(); expansionActive = false }
    }

    func move(_ delta: Int) {
        let rows = visible
        let index = rows.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = rows.isEmpty ? nil : rows[NavigationBounds.move(index, by: delta, count: rows.count)].id
    }

    func edit(_ snippet: Snippet? = nil) {
        draft = snippet ?? Snippet()
        error = ""
    }

    func save() -> Bool {
        var snippet = draft
        snippet.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.keyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snippet.title.isEmpty, !snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "请填写标题和片段内容。"
            return false
        }
        guard Snippet.validKeyword(snippet.keyword) else {
            error = "缩写最多 40 个可见 ASCII 字符，不能包含空格。"
            return false
        }
        if !snippet.keyword.isEmpty, entries.contains(where: { $0.id != snippet.id && $0.keyword == snippet.keyword }) {
            error = "此缩写已被另一条片段使用。"
            return false
        }
        do {
            guard let store else { error = "无法打开片段资料库。"; return false }
            try store.save(snippet.record())
            entries.removeAll { $0.id == snippet.id }
            entries.insert(snippet, at: 0)
            selectedID = snippet.id
            error = ""
            configureExpansion()
            return true
        } catch {
            self.error = "无法保存片段：\(error.localizedDescription)"
            return false
        }
    }

    func delete(_ snippet: Snippet) {
        let alert = NSAlert()
        alert.messageText = "删除「\(snippet.title)」？"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            guard let store else { error = "无法打开片段资料库。"; return }
            try store.remove(id: "snippet:" + snippet.id)
            entries.removeAll { $0.id == snippet.id }
            selectedID = visible.first?.id
            error = ""
            configureExpansion()
        } catch { self.error = "无法删除片段：\(error.localizedDescription)" }
    }

    func use(_ snippet: Snippet, paste: Bool) {
        guard active else { return }
        UtilityActions.copy(snippet.render().text)
        guard let delegate = NSApp?.delegate as? Delegate else { return }
        if paste, delegate.pasteTargetName != nil { delegate.pasteIntoPreviousApplication() }
        else { delegate.hideLauncher() }
    }
}
