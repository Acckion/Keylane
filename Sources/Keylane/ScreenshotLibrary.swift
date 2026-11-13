import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Vision
import KeylaneCore

enum ScreenshotCommand: String, CaseIterable {
    case search = "search-screenshots"
    case latest = "paste-latest-screenshot"

    var title: String { self == .search ? "搜索截图" : "粘贴最新截图" }
    var symbol: String { self == .search ? "viewfinder" : "doc.on.clipboard" }
    var aliases: [String] {
        self == .search ? ["Search Screenshots", "截图管理", "截图历史", "截屏"] : ["Paste Latest Screenshot", "clipscreen"]
    }
}

enum ScreenshotFilter: String, CaseIterable, Identifiable {
    case all, images, movies
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "全部"
        case .images: return "图片"
        case .movies: return "录屏"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "list.bullet"
        case .images: return "photo"
        case .movies: return "film"
        }
    }
    func includes(_ item: ScreenshotMedia) -> Bool {
        self == .all || (self == .images ? item.kind == .image : item.kind == .movie)
    }
}

struct ScreenshotScope: Codable, Identifiable, Equatable {
    let path: String
    let bookmark: Data?
    var id: String { path }
    var accessibleURL: URL? {
        let original = URL(fileURLWithPath: path, isDirectory: true)
        let url: URL
        if let bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark,
                                          options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                          relativeTo: nil, bookmarkDataIsStale: &stale),
                  !stale, resolved.standardizedFileURL.path == original.standardizedFileURL.path else { return nil }
            url = resolved
        } else {
            url = original
        }

        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        guard let directory = opendir(url.path) else { return nil }
        closedir(directory)
        return url
    }
}

final class ScreenshotLibrary: ObservableObject {
    static let columnCounts = 3...6
    private static let defaultColumnCount = 3
    private static let section = "captures"
    private static let pinnedSection = "pinned-captures"
    private let defaults: UserDefaults
    @Published var enabled: Bool {
        didSet {
            if !enabled {
                stop()
                latestTask?.cancel()
                latestTask = nil
                for work in copyWork.values { work.cancel() }
                copyWork.removeAll()
                ocrCache = ScreenshotTextCache()
                items = []
                query = ""
                skippedOCR = 0
                inaccessibleFolders = 0
                publish([])
            }
        }
    }
    @Published var disabledCommands: Set<String> { didSet { defaults.set(Array(disabledCommands), forKey: "disabledScreenshotCommands") } }
    @Published var columns: Int { didSet { defaults.set(columns, forKey: "screenshotColumns") } }
    @Published private(set) var pinnedIDs: Set<String> {
        didSet { defaults.set(pinnedIDs.sorted(), forKey: "pinnedScreenshotPaths") }
    }
    @Published var includeAll: Bool {
        didSet {
            defaults.set(includeAll, forKey: "screenshotIncludeAll")
            if pageActive, oldValue != includeAll { refresh() }
        }
    }
    @Published var recognizesText: Bool { didSet { defaults.set(recognizesText, forKey: "screenshotOCR") } }
    @Published var accurate: Bool { didSet { defaults.set(accurate, forKey: "screenshotOCRAccurate") } }
    @Published var allowCloudOCR: Bool { didSet { defaults.set(allowCloudOCR, forKey: "screenshotCloudOCR") } }
    @Published private(set) var scopes: [ScreenshotScope] = []
    @Published var filter = ScreenshotFilter.all { didSet { if oldValue != filter { search(query) } } }
    @Published var selection: ResultGridSelection<String>?
    @Published private(set) var results: [ScreenshotMedia] = []
    @Published private(set) var scanning = false
    @Published private(set) var searchingText = false
    @Published private(set) var inaccessibleFolders = 0
    @Published private(set) var unavailableScopePaths: [String] = []
    @Published private(set) var skippedOCR = 0

    private let watcher = FolderChangeWatcher()
    private var pageActive = false
    private var needsRefresh = false
    private var scopeAccess: [URL] = []
    private var items: [ScreenshotMedia] = []
    private var query = ""
    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var latestTask: Task<Void, Never>?
    private var ocrCache = ScreenshotTextCache()
    private var searchOCR: ImageTextRecognitionWork?
    private var copyWork: [UUID: ImageTextRecognitionWork] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = false
        disabledCommands = Set(defaults.stringArray(forKey: "disabledScreenshotCommands") ?? [])
        let savedColumns = defaults.object(forKey: "screenshotColumns") as? Int ?? Self.defaultColumnCount
        columns = min(Self.columnCounts.upperBound, max(Self.columnCounts.lowerBound, savedColumns))
        pinnedIDs = Set(defaults.stringArray(forKey: "pinnedScreenshotPaths") ?? [])
        includeAll = defaults.bool(forKey: "screenshotIncludeAll")
        recognizesText = defaults.bool(forKey: "screenshotOCR")
        accurate = defaults.object(forKey: "screenshotOCRAccurate") as? Bool ?? true
        allowCloudOCR = defaults.bool(forKey: "screenshotCloudOCR")
        if let data = defaults.data(forKey: "screenshotScopes") {
            scopes = (try? JSONDecoder().decode([ScreenshotScope].self, from: data)) ?? []
        }
    }

    var suggestedFolder: URL? { systemScreenshotFolder ?? desktopFolder }

    private var desktopFolder: URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private var systemScreenshotFolder: URL? {
        let systemPath = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let systemPath, !systemPath.isEmpty {
            let path = (systemPath as NSString).expandingTildeInPath
            if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return nil
    }

    var hasAuthorizedScope: Bool { scopes.contains { $0.accessibleURL != nil } }

    func checkFolders() {
        let unavailable = scopes.filter { $0.accessibleURL == nil }.map(\.path)
        if unavailableScopePaths != unavailable { unavailableScopePaths = unavailable }
    }

    var selected: ScreenshotMedia? {
        guard let selection else { return nil }
        return results.first { $0.id == selection.itemID }
    }

    func commandEnabledBinding(_ command: ScreenshotCommand) -> Binding<Bool> {
        Binding(get: { !self.disabledCommands.contains(command.rawValue) }, set: { enabled in
            if enabled { self.disabledCommands.remove(command.rawValue) }
            else { self.disabledCommands.insert(command.rawValue) }
        })
    }

    func isEnabled(_ command: ScreenshotCommand) -> Bool {
        enabled && !disabledCommands.contains(command.rawValue)
    }

    func chooseFolders() { chooseFolders(in: nil) }

    func chooseFolders(in window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = scopes.compactMap(\.accessibleURL).first ?? suggestedFolder ?? desktopFolder
        panel.message = "选择要搜索的文件夹，例如 macOS 截图保存位置、桌面或 CleanShot X 的保存位置。"
        panel.prompt = "添加搜索文件夹"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self, !self.addFolders(panel.urls).isEmpty else { return }
            let alert = NSAlert()
            alert.messageText = "无法添加部分搜索文件夹"
            alert.informativeText = "请确认文件夹仍存在并允许 Keylane 访问，然后重新选择。"
            if let window, window.isVisible { alert.beginSheetModal(for: window) }
            else { alert.runModal() }
        }
        if let window, window.isVisible {
            guard window.attachedSheet == nil else { return }
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    @discardableResult
    func addFolders(_ urls: [URL]) -> [URL] {
        var updated = scopes
        var rejected: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            if updated.contains(where: { $0.path == url.path && $0.accessibleURL != nil }) { continue }
            let bookmark = try? url.bookmarkData(options: .withSecurityScope)
            let scope = ScreenshotScope(path: url.path, bookmark: bookmark)
            guard scope.accessibleURL != nil else { rejected.append(url); continue }
            updated.removeAll { $0.path == scope.path }
            updated.append(scope)
        }
        if updated != scopes { saveScopes(updated) }
        return rejected
    }

    func removeFolder(at path: String) {
        saveScopes(scopes.filter { $0.path != path })
    }

    private func saveScopes(_ updated: [ScreenshotScope]) {
        guard updated != scopes, let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: "screenshotScopes")
        scopes = updated
        checkFolders()
        latestTask?.cancel()
        latestTask = nil
        if pageActive { refresh() }
    }

    func start() {
        pageActive = true
        watcher.changed = { [weak self] rebuild in
            guard let self, self.pageActive else { return }
            if rebuild { self.refresh() }
            else if self.scanTask != nil { self.needsRefresh = true }
            else { self.scan(self.scopes.compactMap(\.accessibleURL), showingProgress: false) }
        }
        refresh()
    }

    func refresh() {
        guard enabled else { return }
        scanTask?.cancel()
        scanTask = nil
        needsRefresh = false
        checkFolders()
        let folders = scopes.compactMap(\.accessibleURL)
        if pageActive {
            watcher.stop()
            releaseScopeAccess()
            scopeAccess = folders.filter { $0.startAccessingSecurityScopedResource() }
            watcher.start(roots: folders.map(\.path))
        }
        // Drop old results from scopes the user just removed or can no longer read.
        let paths = folders.map { $0.path == "/" ? "/" : $0.path + "/" }
        let authorized: (ScreenshotMedia) -> Bool = { item in paths.contains { item.id.hasPrefix($0) } }
        let previousCount = items.count
        items.removeAll { !authorized($0) }
        if items.count != previousCount {
            cancelSearch()
            searchingText = false
            publish(results.filter(authorized))
            applySearch(query, preservingResults: true)
        }
        scan(folders, showingProgress: true)
    }

    private func scan(_ folders: [URL], showingProgress: Bool) {
        guard !folders.isEmpty else {
            scanning = false
            cancelSearch()
            searchingText = false
            inaccessibleFolders = 0
            return
        }
        if showingProgress { scanning = true }
        let includeAll = includeAll
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = ScreenshotCatalog.scan(folders: folders, includeAllMedia: includeAll)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.scanTask = nil
                self.scanning = false
                self.inaccessibleFolders = snapshot.inaccessibleFolders
                self.checkFolders()
                if self.items != snapshot.items || showingProgress {
                    let preferred = self.selectionAfterRename(in: snapshot.items)
                    self.items = snapshot.items
                    self.applySearch(self.query, preservingResults: true, preferred: preferred)
                } else if self.results.isEmpty && self.searchingText == false {
                    self.applySearch(self.query, preservingResults: true)
                }
                if self.needsRefresh {
                    self.needsRefresh = false
                    self.scan(self.scopes.compactMap(\.accessibleURL), showingProgress: false)
                }
            }
        }
    }

    private func selectionAfterRename(in updated: [ScreenshotMedia]) -> ResultGridSelection<String>? {
        guard let selected, !updated.contains(where: { $0.id == selected.id }), let identity = selected.identity else { return nil }
        let matches = updated.filter { $0.identity == identity }
        guard matches.count == 1, let replacement = matches.first else { return nil }
        if pinnedIDs.remove(selected.id) != nil { pinnedIDs.insert(replacement.id) }
        return .init(sectionID: pinnedIDs.contains(replacement.id) ? Self.pinnedSection : Self.section, itemID: replacement.id)
    }

    func stop() {
        pageActive = false
        watcher.stop()
        releaseScopeAccess()
        needsRefresh = false
        scanTask?.cancel()
        scanTask = nil
        cancelSearch()
        scanning = false
        searchingText = false
    }

    private func releaseScopeAccess() {
        for folder in scopeAccess { folder.stopAccessingSecurityScopedResource() }
        scopeAccess.removeAll()
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchOCR?.cancel()
        searchOCR = nil
    }

    func search(_ value: String) {
        applySearch(value, preservingResults: false)
    }

    private func applySearch(_ value: String, preservingResults: Bool, preferred: ResultGridSelection<String>? = nil) {
        guard enabled else { return }
        let previousSelection = selection
        query = value
        cancelSearch()
        searchingText = false
        skippedOCR = 0
        let criteria = ScreenshotQuery(value)
        let candidates = items.filter { filter.includes($0) && criteria.matchesMetadata($0) }
        guard !criteria.text.isEmpty else { publish(candidates, preferred: preferred); return }
        guard recognizesText else { publish([]); return }
        if !preservingResults { publish([]) }
        searchingText = true
        let accurate = accurate
        let allowCloud = allowCloudOCR
        let cache = ocrCache
        let work = ImageTextRecognitionWork()
        searchOCR = work
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var matches: [ScreenshotMedia] = []
            var skipped = 0
            for item in candidates where item.kind == .image {
                if Task.isCancelled { return }
                guard allowCloud || !item.needsCloudAccess else { skipped += 1; continue }
                guard let text = cache.read(item, accurate: accurate, work: work) else { skipped += 1; continue }
                if text.localizedStandardContains(criteria.text) { matches.append(item) }
            }
            let completed = (matches: matches, skipped: skipped)
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.searchingText = false
                self.skippedOCR = completed.skipped
                self.publish(completed.matches, preferred: self.selection == previousSelection ? preferred : nil)
            }
        }
    }

    func move(_ delta: Int, vertical: Bool) {
        let next = selection?.moving(delta, vertical: vertical, columns: columns, in: sections)
        if next != selection { selection = next }
    }

    func resetZoom() { columns = Self.defaultColumnCount }

    func zoomIn() {
        if columns > Self.columnCounts.lowerBound { columns -= 1 }
    }

    func zoomOut() {
        if columns < Self.columnCounts.upperBound { columns += 1 }
    }

    func togglePin(_ item: ScreenshotMedia) throws {
        try validate(item)
        let pinned = pinnedIDs.contains(item.id)
        if pinned { pinnedIDs.remove(item.id) }
        else { pinnedIDs.insert(item.id) }
        if selection?.itemID == item.id {
            selection = .init(sectionID: pinned ? Self.section : Self.pinnedSection, itemID: item.id)
        }
    }

    var sections: [ResultGridSection<ScreenshotMedia>] {
        let title = filter == .all ? "图片与录屏" : filter.title
        if pinnedIDs.isEmpty {
            return [
                .init(id: Self.pinnedSection, title: "已置顶", items: []),
                .init(id: Self.section, title: title, items: results)
            ]
        }
        return [
            .init(id: Self.pinnedSection, title: "已置顶", items: results.filter { pinnedIDs.contains($0.id) }),
            .init(id: Self.section, title: title, items: results.filter { !pinnedIDs.contains($0.id) })
        ]
    }

    private func publish(_ results: [ScreenshotMedia], preferred: ResultGridSelection<String>? = nil) {
        if self.results != results { self.results = results }
        let next = ResultGridSelection.retaining(preferred ?? selection, in: sections)
        if selection != next { selection = next }
    }

    func latest(_ completion: @escaping (ScreenshotMedia?) -> Void) {
        latestTask?.cancel()
        guard enabled else { completion(nil); return }
        let folders = scopes.compactMap(\.accessibleURL)
        guard !folders.isEmpty else { completion(nil); return }
        let includeAll = includeAll
        latestTask = Task.detached(priority: .userInitiated) {
            let latest = ScreenshotCatalog.scan(folders: folders, includeAllMedia: includeAll).items.first { $0.kind == .image }
            await MainActor.run { if !Task.isCancelled { completion(latest) } }
        }
    }

    func copy(_ item: ScreenshotMedia, to board: NSPasteboard = .general) throws {
        try validate(item)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)
        if item.kind == .image {
            let data = try Data(contentsOf: item.url, options: .mappedIfSafe)
            let type = UTType(filenameExtension: item.url.pathExtension)
            if let type, !type.isDynamic { pasteboardItem.setData(data, forType: .init(type.identifier)) }
        }
        board.clearContents()
        guard board.writeObjects([pasteboardItem]) else { throw CocoaError(.fileWriteUnknown) }
    }

    func copyPath(_ item: ScreenshotMedia, to board: NSPasteboard = .general) throws {
        try validate(item)
        try writeText(item.url.path, to: board)
    }

    @MainActor func copyImageText(_ mode: ImageTextRecognition, from item: ScreenshotMedia,
                                  to board: NSPasteboard = .general) async throws -> Bool {
        try validate(item)
        guard item.kind == .image else { throw ImageTextError.notImage }
        guard allowCloudOCR || !item.needsCloudAccess else { throw ImageTextError.cloudDownloadDisabled }
        let changeCount = board.changeCount
        let accurate = accurate
        let work = ImageTextRecognitionWork()
        let id = UUID()
        copyWork[id] = work
        defer { copyWork.removeValue(forKey: id) }
        let outcome = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Result { try mode.recognize(in: VNImageRequestHandler(url: item.url), accurate: accurate, work: work) }
            }.value
        } onCancel: {
            work.cancel()
        }
        guard !work.cancelled else { throw CancellationError() }
        let text = try outcome.get()
        guard !text.isEmpty else { return false }
        try validate(item)
        guard board.changeCount == changeCount else { throw ImageTextError.pasteboardChanged }
        try writeText(text, to: board)
        return true
    }

    private enum ImageTextError: LocalizedError {
        case notImage, cloudDownloadDisabled, pasteboardChanged

        var errorDescription: String? {
            switch self {
            case .notImage: return "请选择一张截图。"
            case .cloudDownloadDisabled: return "图片尚未下载。请先下载图片，或在截图设置中允许识别云端文件。"
            case .pasteboardChanged: return "剪贴板内容已变化，请重新执行复制。"
            }
        }
    }

    private func writeText(_ text: String, to board: NSPasteboard) throws {
        board.clearContents()
        guard board.setString(text, forType: .string) else { throw CocoaError(.fileWriteUnknown) }
    }

    func validate(_ item: ScreenshotMedia) throws {
        guard enabled else { throw CancellationError() }
        let currentURL = URL(fileURLWithPath: item.url.path)
        let values = try currentURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                                                            .fileSizeKey, .fileResourceIdentifierKey, .volumeIdentifierKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.contentModificationDate == item.modified, values.fileSize == item.size,
              item.identity?.matches(values) ?? true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    @discardableResult func moveToTrash(_ item: ScreenshotMedia) throws -> URL? {
        try validate(item)
        var destination: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
        items.removeAll { $0.id == item.id }
        if pinnedIDs.contains(item.id) { pinnedIDs.remove(item.id) }
        applySearch(query, preservingResults: false)
        if pageActive { refresh() }
        return destination as URL?
    }
}

private final class ScreenshotTextCache: @unchecked Sendable {
    private let cache: NSCache<NSString, NSString> = {
        let value = NSCache<NSString, NSString>()
        value.countLimit = 2_000
        value.totalCostLimit = 16 * 1024 * 1024
        return value
    }()

    func read(_ item: ScreenshotMedia, accurate: Bool, work: ImageTextRecognitionWork) -> String? {
        let key = "\(item.url.absoluteString)|\(item.modified.timeIntervalSince1970)|\(item.size)|\(accurate)" as NSString
        if let text = cache.object(forKey: key) { return text as String }
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560
              ] as CFDictionary) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.automaticallyDetectsLanguage = true
        guard (try? work.perform(request, in: VNImageRequestHandler(cgImage: image))) != nil, !work.cancelled else { return nil }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        cache.setObject(text as NSString, forKey: key, cost: text.utf8.count)
        return text
    }
}
