import AppKit
import Combine
import KeylaneCore
import UniformTypeIdentifiers

final class SnippetsController: ObservableObject {
    struct Input {
        let snippet: Snippet
        let plan: DynamicTemplate.Plan
        let paste: Bool
        let trigger: SnippetExpansion.Trigger?
    }

    @Published private(set) var entries: [Snippet] = [] {
        didSet {
            searchCatalog = nil
            searchResults = nil
        }
    }
    @Published var query = "" { didSet { selectedID = visible.first?.id } }
    @Published var tag = "" { didSet { selectedID = visible.first?.id } }
    @Published var selectedID: String?
    @Published var draft = Snippet()
    @Published private(set) var error = ""
    @Published var expandsKeywords = false { didSet { if expandsKeywords != oldValue { configureExpansion() } } }
    @Published private(set) var expansionActive = false
    @Published var options: SnippetExpansionOptions {
        didSet {
            if let data = try? JSONEncoder().encode(options) { preferences.set(data, forKey: SnippetExpansionOptions.defaultsKey) }
            if options != oldValue { configureExpansion() }
        }
    }
    @Published private(set) var input: Input?
    @Published var values: [String: String] = [:]
    @Published private(set) var inputError: String?

    private struct SearchCatalog {
        let ordered: [Snippet]
        let searchable: [String]
        let tags: [String]
    }

    private var searchCatalog: SearchCatalog?
    private var searchResults: (query: String, tag: String, rows: [Snippet])?
    private let storageURL: URL
    private var store: Store?
    private let preferences: UserDefaults
    private let expansion = SnippetExpansion()
    private var active = false
    private var presenter: (() -> Void)?
    weak var clipboard: ClipboardController?

    init(storageURL: URL, preferences: UserDefaults = .standard) {
        self.storageURL = storageURL
        self.preferences = preferences
        options = .load(preferences)
        expansion.plan = { [weak self] snippet in
            try DynamicTemplate(snippet.text).plan(context: self?.templateContext(interactive: false) ?? .init())
        }
        expansion.requestArguments = { [weak self] snippet, plan, trigger in
            self?.requestInput(snippet, plan: plan, paste: true, trigger: trigger)
        }
        expansion.failure = { [weak self] message in self?.feedback(message, style: .failure) }
    }

    private func catalog() -> SearchCatalog {
        if let searchCatalog { return searchCatalog }
        let ordered = entries.filter(\.pinned) + entries.filter { !$0.pinned }
        let catalog = SearchCatalog(
            ordered: ordered,
            searchable: ordered.map { ([$0.title, $0.keyword, $0.text] + $0.tags).joined(separator: "\n") },
            tags: Snippet.normalizedTags(entries.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
        searchCatalog = catalog
        return catalog
    }

    var tags: [String] { entries.isEmpty ? [] : catalog().tags }

    var visible: [Snippet] {
        guard !entries.isEmpty else { return [] }
        if let searchResults, searchResults.query == query, searchResults.tag == tag {
            return searchResults.rows
        }
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let catalog = catalog()
        let rows: [Snippet]
        if terms.isEmpty && tag.isEmpty {
            rows = catalog.ordered
        } else {
            rows = zip(catalog.ordered, catalog.searchable).compactMap { snippet, text in
                guard tag.isEmpty || snippet.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }),
                      terms.allSatisfy({ text.localizedStandardContains($0) }) else { return nil }
                return snippet
            }
        }
        searchResults = (query, tag, rows)
        return rows
    }

    var selected: Snippet? {
        let rows = visible
        return rows.first { $0.id == selectedID } ?? rows.first
    }

    func start(presentArguments: @escaping () -> Void) {
        presenter = presentArguments
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
        presenter = nil
        store = nil
        entries = []
        query = ""
        tag = ""
        selectedID = nil
        draft = Snippet()
        clearInput()
        error = ""
    }

    func applicationFocused() {
        expansion.resetInput()
        if expandsKeywords && !expansionActive { configureExpansion() }
    }

    private func configureExpansion() {
        if active && expandsKeywords { expansionActive = expansion.configure(entries, options: options) }
        else {
            expansion.stop()
            expansionActive = false
        }
    }

    func move(_ delta: Int) {
        let rows = visible
        let index = rows.firstIndex { $0.id == selectedID } ?? 0
        selectedID = rows.isEmpty ? nil : rows[NavigationBounds.move(index, by: delta, count: rows.count)].id
    }

    func edit(_ snippet: Snippet? = nil) {
        draft = snippet ?? Snippet()
        error = ""
    }

    func duplicate(_ snippet: Snippet) {
        edit(Snippet(title: snippet.title + "（副本）", text: snippet.text, tags: snippet.tags,
                     icon: snippet.icon, richText: snippet.richText))
    }

    func save() -> Bool {
        do {
            let snippet = try validated(draft)
            if !snippet.keyword.isEmpty, entries.contains(where: { $0.id != snippet.id && $0.keyword == snippet.keyword }) {
                error = "此关键词已被另一条片段使用。"
                return false
            }
            try persist(snippet)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func validated(_ source: Snippet) throws -> Snippet {
        var snippet = source
        snippet.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.keyword = snippet.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.tags = Snippet.normalizedTags(snippet.tags)
        guard !snippet.title.isEmpty, !snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Message("请填写名称和片段内容。")
        }
        guard snippet.text.count <= Snippet.maximumTextLength else { throw Message("片段内容最多 65,536 个字符。") }
        guard Snippet.validKeyword(snippet.keyword) else {
            throw Message("关键词最多 40 个字符，不能包含空格、引号或反引号。")
        }
        return snippet
    }

    private struct Message: LocalizedError {
        let value: String
        init(_ value: String) { self.value = value }
        var errorDescription: String? { value }
    }

    private func persist(_ snippet: Snippet) throws {
        guard let store else { throw Message("无法打开片段资料库。") }
        try store.save(snippet.record())
        entries.removeAll { $0.id == snippet.id }
        entries.insert(snippet, at: 0)
        selectedID = snippet.id
        error = ""
        configureExpansion()
    }

    func togglePin(_ snippet: Snippet) {
        var updated = snippet
        updated.pinned.toggle()
        do { try persist(updated) }
        catch { self.error = "无法更新片段：\(error.localizedDescription)" }
    }

    func delete(_ snippet: Snippet) {
        if options.warnOnDelete {
            let alert = NSAlert()
            alert.messageText = "删除「\(snippet.title)」？"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "删除")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "以后不再询问"
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            if alert.suppressionButton?.state == .on { options.warnOnDelete = false }
        }
        do {
            guard let store else { throw Message("无法打开片段资料库。") }
            try store.remove(id: "snippet:" + snippet.id)
            entries.removeAll { $0.id == snippet.id }
            selectedID = visible.first?.id
            error = ""
            configureExpansion()
        } catch { self.error = "无法删除片段：\(error.localizedDescription)" }
    }

    func templateContext(interactive: Bool = true) -> DynamicTemplate.Context {
        var context = DynamicTemplate.Context()
        var hasReadClipboard = false
        var currentClipboardText: String?
        context.clipboard = { [weak clipboard] offset in
            if !hasReadClipboard {
                let board = NSPasteboard.general
                if board.accessBehavior == .alwaysAllow || (interactive && board.accessBehavior != .alwaysDeny) {
                    currentClipboardText = board.string(forType: .string)
                }
                hasReadClipboard = true
            }
            if offset == 0 { return currentClipboardText }
            return clipboard?.placeholderHistory(offset: offset, current: currentClipboardText)
        }
        context.snippet = { [entries] name in entries.first { $0.title == name }?.text }
        let target = (NSApp.delegate as? Delegate)?.previousApplication
        context.selection = {
            guard let target, let field = SnippetTextTarget.focused(in: target) else { return nil }
            return SnippetTextTarget.attribute(kAXSelectedTextAttribute, of: field) as? String
        }
        return context
    }

    func use(_ snippet: Snippet, paste: Bool) {
        guard active else { return }
        do {
            let plan = try DynamicTemplate(snippet.text).plan(context: templateContext())
            if plan.arguments.isEmpty { use(try plan.resolve(), snippet: snippet, paste: paste) }
            else { requestInput(snippet, plan: plan, paste: paste) }
        } catch { feedback(error.localizedDescription, style: .failure) }
    }

    private func requestInput(_ snippet: Snippet, plan: DynamicTemplate.Plan, paste: Bool,
                              trigger: SnippetExpansion.Trigger? = nil) {
        input = Input(snippet: snippet, plan: plan, paste: paste, trigger: trigger)
        values = [:]
        inputError = nil
        presenter?()
    }

    func clearInput() {
        input = nil
        values = [:]
        inputError = nil
    }

    func submitInput() -> Bool {
        guard let input else { return false }
        do {
            let rendered = try input.plan.resolve(values)
            if let trigger = input.trigger {
                let application = trigger.application
                (NSApp.delegate as? Delegate)?.hideLauncher()
                application.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
                    guard let self, self.active, self.expandsKeywords else { return }
                    if !self.expansion.replace(rendered, trigger: trigger, richText: input.snippet.richText) {
                        self.feedback("目标文本已改变，片段未展开。", style: .failure)
                    }
                }
            } else { use(rendered, snippet: input.snippet, paste: input.paste) }
            return true
        } catch {
            inputError = error.localizedDescription
            return false
        }
    }

    private func use(_ rendered: DynamicTemplate.Rendered, snippet: Snippet, paste: Bool) {
        guard SnippetPasteboard.copy(rendered, richText: snippet.richText) else {
            feedback("无法将片段写入剪贴板。", style: .failure)
            return
        }
        guard let delegate = NSApp.delegate as? Delegate else { return }
        if paste, delegate.pasteTargetName != nil {
            delegate.pasteIntoPreviousApplication(placeCursor: rendered.cursorOffset.map { (rendered.text, $0) })
        } else { delegate.hideLauncher() }
    }

    func importSnippets() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "选择 Raycast 或 Keylane 导出的片段 JSON 文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let store else { throw Message("无法打开片段资料库。") }
            let records = try JSONDecoder().decode([SnippetExchange].self, from: Data(contentsOf: url))
            var newEntries: [Snippet] = []
            var known = Set(entries.map(SnippetExchange.init))
            var usedKeywords = Set(entries.map(\.keyword).filter { !$0.isEmpty })
            var conflicts = 0
            for record in records {
                var snippet = try validated(record.snippet())
                guard known.insert(SnippetExchange(snippet)).inserted else { continue }
                if !snippet.keyword.isEmpty && !usedKeywords.insert(snippet.keyword).inserted {
                    snippet.keyword = ""
                    conflicts += 1
                    guard known.insert(SnippetExchange(snippet)).inserted else { continue }
                }
                newEntries.append(snippet)
            }
            guard !newEntries.isEmpty else { feedback("没有可新增的片段。", style: .success); return }
            let alert = NSAlert()
            alert.messageText = "导入 \(newEntries.count) 条文字片段？"
            alert.informativeText = "已跳过 \(records.count - newEntries.count) 条重复记录。"
            if conflicts > 0 { alert.informativeText += "\(conflicts) 条记录的关键词与已有片段冲突，导入时会清空关键词。" }
            alert.addButton(withTitle: "导入")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try store.save(newEntries.map { try $0.record() })
            entries.insert(contentsOf: newEntries, at: 0)
            configureExpansion()
            feedback("已导入 \(newEntries.count) 条文字片段。", style: .success)
        } catch { feedback("无法导入片段：\(error.localizedDescription)", style: .failure) }
    }

    func exportSnippets() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Snippets.json"
        panel.message = "导出名称、正文、关键词和标签。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SnippetExchange.encode(entries).write(to: url, options: .atomic)
            feedback("已导出 \(entries.count) 条文字片段。", style: .success)
        } catch { feedback("无法导出片段：\(error.localizedDescription)", style: .failure) }
    }

    private func feedback(_ message: String, style: ToastStyle) {
        (NSApp.delegate as? Delegate)?.showLauncherFeedback(message, style: style)
    }
}
