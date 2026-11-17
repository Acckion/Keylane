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

    private let defaultHandler: (URL) -> URL?
    private let applicationURL: (String) -> URL?
    private let openWithApplication: (URL, URL, @escaping (Error?) -> Void) -> Void

    init(preferences: UserDefaults = .standard,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         defaultHandler: @escaping (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
         applicationURL: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
         openWithApplication: @escaping (URL, URL, @escaping (Error?) -> Void) -> Void = { url, application, completion in
             NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { _, error in completion(error) }
         }) {
        self.preferences = preferences
        self.openURL = openURL
        self.defaultHandler = defaultHandler
        self.applicationURL = applicationURL
        self.openWithApplication = openWithApplication
    }

    static func applicationName(for identifier: String?) -> String {
        guard let identifier else { return "系统默认" }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return "应用不可用（\(identifier)）"
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    static func chooseApplication(_ completion: @escaping (String) -> Void) {
        guard var window = NSApp.keyWindow else { return }
        while let sheet = window.attachedSheet { window = sheet }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "选择应用"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url,
                  let identifier = Bundle(url: url)?.bundleIdentifier else { return }
            completion(identifier)
        }
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
        let parsed = try link.parsedTemplate(context: templateContext())
        if let url = parsed.localURL { link.template = url.absoluteString }
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

    func resolvedLayoutURL(id: String) throws -> URL {
        guard let link = links.first(where: { $0.id == id }) else { throw Message("此布局关联的快捷链接已不存在。") }
        return try link.parsedTemplate(context: templateContext()).url()
    }

    @discardableResult
    func launch(_ link: Quicklink, presentParameters: () -> Void) -> Bool {
        clearInput()
        do {
            let template = try link.parsedTemplate(context: templateContext())
            if template.parameters.isEmpty {
                try open(template.url(), applicationID: link.openingApplicationID)
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

    func acceptsFallbackQuery(_ link: Quicklink) -> Bool {
        guard let template = try? link.parsedTemplate(context: templateContext()) else { return false }
        return fallbackParameter(in: template) != nil
    }

    func openFallback(_ link: Quicklink, query: String) -> Bool {
        do {
            let template = try link.parsedTemplate(context: templateContext())
            guard let parameter = fallbackParameter(in: template) else { return false }
            try open(template.url(values: [parameter.id: query]), applicationID: link.openingApplicationID)
            return true
        } catch {
            feedback(error.localizedDescription, .failure)
            return false
        }
    }

    private func fallbackParameter(in template: QuicklinkTemplate) -> QuicklinkTemplate.Parameter? {
        guard let first = template.parameters.first, first.options.isEmpty,
              template.parameters.dropFirst().allSatisfy({ parameter in
                  guard let value = parameter.defaultValue else { return false }
                  return parameter.options.isEmpty || parameter.options.contains(value)
              }) else { return nil }
        return first
    }

    func submit() -> Bool {
        guard let pendingTemplate else { return false }
        do {
            try open(pendingTemplate.url(values: values), applicationID: argumentLink?.openingApplicationID)
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

    private func open(_ url: URL, applicationID: String?) throws {
        let target = url.isFileURL ? url.resolvingSymlinksInPath() : url
        if url.isFileURL {
            let values: URLResourceValues
            do {
                values = try target.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isApplicationKey, .isAliasFileKey, .isReadableKey])
            } catch {
                throw Message("无法访问本地目标。请检查路径是否仍存在，以及 Keylane 是否有权限访问。")
            }
            guard values.isReadable == true else {
                throw Message("无法访问本地目标。请检查 Keylane 是否有权限访问。")
            }
            guard values.isApplication != true, values.isAliasFile != true,
                  values.isDirectory == true || (values.isRegularFile == true
                      && !FileManager.default.isExecutableFile(atPath: target.path)
                      && target.pathExtension.lowercased() != "command") else {
                throw Message("请选择普通文件或文件夹。")
            }
        }
        if let applicationID {
            guard let application = applicationURL(applicationID) else {
                throw Message("指定的打开应用不可用（\(applicationID)）。请重新选择应用。")
            }
            openWithApplication(target, application) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async { self?.feedback("指定应用无法打开此链接：\(error.localizedDescription)", .failure) }
            }
        } else {
            if QuicklinkTemplate.isApplicationLink(target), defaultHandler(target) == nil {
                throw Message("没有应用可以打开 \(target.scheme ?? "") 链接。")
            }
            guard openURL(target) else {
                throw Message(url.isFileURL ? "无法打开本地文件或文件夹。" : "无法打开快捷链接。")
            }
        }
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
