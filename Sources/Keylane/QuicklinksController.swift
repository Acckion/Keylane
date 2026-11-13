import AppKit
import Combine
import KeylaneCore
import UniformTypeIdentifiers

final class QuicklinksController: ObservableObject {
    static let editorPage = PageID(rawValue: "EditQuicklink")
    private(set) var editorReturnPage = PageID.root

    @Published private(set) var links: [Quicklink] = []
    @Published private(set) var storageError: String?
    @Published var query = "" { didSet { if oldValue != query { selectedID = nil } } }
    @Published var tag = "" { didSet { if oldValue != tag { selectedID = nil } } }
    @Published var selectedID: String?
    @Published private(set) var argumentLink: Quicklink?
    @Published private(set) var parameters: [QuicklinkTemplate.Parameter] = []
    @Published var values: [String: String] = [:]
    @Published private(set) var inputError: String?
    @Published var draft: Quicklink?
    @Published var draftTags = ""
    @Published private(set) var draftError: String?
    @Published var settingsDraft: Quicklink?

    var templateContext: () -> DynamicTemplate.Context = { .init() }
    var feedback: (String, ToastStyle) -> Void = { _, _ in }
    private let preferences: UserDefaults
    private let openURL: (URL) -> Bool
    private var pendingTemplate: QuicklinkTemplate?

    init(preferences: UserDefaults = .standard, openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.preferences = preferences
        self.openURL = openURL
    }

    var library: QuicklinkLibrary { .init(links: links) }
    var legacyTemplate: String? { QuicklinkLibrary.legacyTemplate(from: preferences) }

    func load() {
        do {
            links = try QuicklinkLibrary.load(from: preferences).links
            storageError = nil
        } catch {
            storageError = "无法读取快捷链接资料。"
        }
    }

    func edit(_ link: Quicklink? = nil, returningTo page: PageID = .root) {
        editorReturnPage = page
        let draft = link?.preparedForEditing() ?? Quicklink(title: "", template: "")
        draftTags = draft.tags.joined(separator: ", ")
        self.draft = draft
        draftError = nil
    }

    func saveDraft() -> String? {
        guard var draft else { return nil }
        draft.applyTagField(draftTags)
        do {
            try save(draft)
            return draft.id
        } catch {
            draftError = error.localizedDescription
            return nil
        }
    }

    /// Hiding the launcher also ends this draft. Only restore the origin if
    /// navigation is still on the editor so it cannot resume without a draft.
    func leaveEditor(currentPage: PageID) -> PageID? {
        clearDraft()
        return currentPage == Self.editorPage ? editorReturnPage : nil
    }

    private func clearDraft() {
        draft = nil
        draftTags = ""
        draftError = nil
    }

    func save(_ link: Quicklink) throws {
        var link = link
        link.title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
        link.template = link.template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.title.isEmpty else { throw Message("请输入名称。") }
        _ = try link.parsedTemplate(context: templateContext())
        var updated = links
        if let index = updated.firstIndex(where: { $0.id == link.id }) { updated[index] = link }
        else { updated.append(link) }
        try persist(updated)
    }

    func updateOrganization(id: String, _ update: (inout Quicklink) -> Void) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        var updated = links
        update(&updated[index])
        do { try persist(updated) }
        catch { feedback(error.localizedDescription, .failure) }
    }

    func remove(_ link: Quicklink) throws { try persist(links.filter { $0.id != link.id }) }

    private func persist(_ updated: [Quicklink]) throws {
        guard storageError == nil else { throw CocoaError(.fileWriteUnknown) }
        try QuicklinkLibrary(links: updated).save(to: preferences)
        links = updated
        if !tag.isEmpty, !library.tags.contains(where: { Quicklink.tagKey($0) == tag }) { tag = "" }
    }

    func rows(aliases: [String: String]) -> [Quicklink] {
        library.search(query, tag: tag, aliases: aliases)
    }

    func selected(in rows: [Quicklink]) -> Quicklink? {
        rows.first { $0.id == selectedID } ?? rows.first
    }

    func move(_ delta: Int, aliases: [String: String]) {
        let rows = rows(aliases: aliases)
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selectedID } ?? 0
        selectedID = rows[NavigationBounds.move(index, by: delta, count: rows.count)].id
    }

    @discardableResult
    func launch(_ link: Quicklink, presentParameters: () -> Void) -> Bool {
        clearInput()
        do {
            let template = try link.parsedTemplate(context: templateContext())
            if template.parameters.isEmpty {
                try open(template.url())
                return true
            }
            pendingTemplate = template
            argumentLink = link
            parameters = template.parameters
            presentParameters()
        } catch {
            feedback(error.localizedDescription, .failure)
        }
        return false
    }

    func submit() -> Bool {
        guard let pendingTemplate else { return false }
        do {
            try open(pendingTemplate.url(values: values))
            clearInput()
            return true
        } catch {
            inputError = error.localizedDescription
            return false
        }
    }

    func clearInput() {
        pendingTemplate = nil
        argumentLink = nil
        parameters = []
        values = [:]
        inputError = nil
    }

    func stop() {
        clearInput()
        clearDraft()
        settingsDraft = nil
        links = []
        storageError = nil
        query = ""
        tag = ""
        selectedID = nil
    }

    private func open(_ url: URL) throws {
        guard openURL(url) else { throw Message("无法打开快捷链接。") }
    }

    func importLinks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "选择 Keylane 或 Raycast 导出的快捷链接。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let maximumBytes = 8 * 1024 * 1024
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw Message("快捷链接 JSON 文件不能超过 8 MB。") }
            let result = try importData(data)
            feedback("已导入 \(result.links.count) 条，跳过 \(result.duplicates) 条重复链接。", .success)
        } catch { feedback("无法导入快捷链接：\(error.localizedDescription)", .failure) }
    }

    func importData(_ data: Data) throws -> QuicklinkLibrary.Import {
        guard storageError == nil else { throw CocoaError(.fileWriteUnknown) }
        let result = try library.importJSON(data, context: templateContext())
        if !result.links.isEmpty { try persist(links + result.links) }
        return result
    }

    func exportLinks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Quicklinks.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard storageError == nil else { throw CocoaError(.fileReadCorruptFile) }
            try library.exportJSON().write(to: url, options: .atomic)
            feedback("已导出 \(links.count) 条快捷链接。", .success)
        } catch { feedback("无法导出快捷链接：\(error.localizedDescription)", .failure) }
    }

    private struct Message: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}

extension Quicklink {
    mutating func applyTagField(_ text: String) {
        guard text != tags.joined(separator: ", ") else { return }
        tags = text.components(separatedBy: CharacterSet(charactersIn: ",，、"))
    }
}
