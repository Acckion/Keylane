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
    var url: URL {
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                return resolved
            }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

final class ScreenshotLibrary: ObservableObject {
    private static let section = "captures"
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "screenshotsEnabled") } }
    @Published var disabledCommands: Set<String> { didSet { defaults.set(Array(disabledCommands), forKey: "disabledScreenshotCommands") } }
    @Published var columns: Int { didSet { defaults.set(columns, forKey: "screenshotColumns") } }
    @Published var includeAll: Bool { didSet { defaults.set(includeAll, forKey: "screenshotIncludeAll") } }
    @Published var recognizesText: Bool { didSet { defaults.set(recognizesText, forKey: "screenshotOCR") } }
    @Published var accurate: Bool { didSet { defaults.set(accurate, forKey: "screenshotOCRAccurate") } }
    @Published var allowCloudOCR: Bool { didSet { defaults.set(allowCloudOCR, forKey: "screenshotCloudOCR") } }
    @Published private(set) var scopes: [ScreenshotScope] = []
    @Published var filter = ScreenshotFilter.all { didSet { search(query) } }
    @Published var selection: ResultGridSelection<String>?
    @Published private(set) var results: [ScreenshotMedia] = []
    @Published private(set) var scanning = false
    @Published private(set) var searchingText = false
    @Published private(set) var inaccessibleFolders = 0
    @Published private(set) var skippedOCR = 0

    private var items: [ScreenshotMedia] = []
    private var query = ""
    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var latestTask: Task<Void, Never>?
    private let ocrCache = ScreenshotTextCache()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "screenshotsEnabled") as? Bool ?? true
        disabledCommands = Set(defaults.stringArray(forKey: "disabledScreenshotCommands") ?? [])
        columns = min(6, max(3, defaults.object(forKey: "screenshotColumns") as? Int ?? 3))
        includeAll = defaults.bool(forKey: "screenshotIncludeAll")
        recognizesText = defaults.bool(forKey: "screenshotOCR")
        accurate = defaults.object(forKey: "screenshotOCRAccurate") as? Bool ?? true
        allowCloudOCR = defaults.bool(forKey: "screenshotCloudOCR")
        if let data = defaults.data(forKey: "screenshotScopes") {
            scopes = (try? JSONDecoder().decode([ScreenshotScope].self, from: data)) ?? []
        }
    }

    var folders: [URL] {
        if !scopes.isEmpty { return scopes.map(\.url) }
        let systemPath = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        if let systemPath, !systemPath.isEmpty {
            let path = (systemPath as NSString).expandingTildeInPath
            if path.hasPrefix("/") { return [URL(fileURLWithPath: path, isDirectory: true)] }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)
    }

    var selected: ScreenshotMedia? {
        guard let selection else { return nil }
        return results.first { $0.id == selection.itemID }
    }

    func isEnabled(_ command: ScreenshotCommand) -> Bool {
        enabled && !disabledCommands.contains(command.rawValue)
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = folders.first
        panel.prompt = "添加搜索文件夹"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls.map(\.standardizedFileURL) where !scopes.contains(where: { $0.path == url.path }) {
            let bookmark = try? url.bookmarkData(options: .withSecurityScope)
            scopes.append(.init(path: url.path, bookmark: bookmark))
        }
        saveScopes()
    }

    func removeFolder(_ scope: ScreenshotScope) {
        scopes.removeAll { $0.id == scope.id }
        saveScopes()
    }

    private func saveScopes() {
        if let data = try? JSONEncoder().encode(scopes) { defaults.set(data, forKey: "screenshotScopes") }
    }

    func refresh() {
        stop()
        scanning = true
        let folders = folders
        let includeAll = includeAll
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = ScreenshotCatalog.scan(folders: folders, includeAllMedia: includeAll)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.scanning = false
                self.items = snapshot.items
                self.inaccessibleFolders = snapshot.inaccessibleFolders
                self.search(self.query)
            }
        }
    }

    func stop() {
        scanTask?.cancel()
        searchTask?.cancel()
        scanning = false
        searchingText = false
    }

    func search(_ value: String) {
        query = value
        searchTask?.cancel()
        searchingText = false
        skippedOCR = 0
        let criteria = ScreenshotQuery(value)
        let candidates = items.filter { filter.includes($0) && criteria.matchesMetadata($0) }
        guard !criteria.text.isEmpty else { publish(candidates); return }
        publish([])
        guard recognizesText else { return }
        searchingText = true
        let accurate = accurate
        let allowCloud = allowCloudOCR
        let cache = ocrCache
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var matches: [ScreenshotMedia] = []
            var skipped = 0
            for item in candidates where item.kind == .image {
                if Task.isCancelled { return }
                guard allowCloud || !item.needsCloudAccess else { skipped += 1; continue }
                guard let text = cache.read(item, accurate: accurate) else { skipped += 1; continue }
                if text.localizedStandardContains(criteria.text) { matches.append(item) }
            }
            let completed = (matches: matches, skipped: skipped)
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.searchingText = false
                self.skippedOCR = completed.skipped
                self.publish(completed.matches)
            }
        }
    }

    func move(_ offset: Int) {
        let index = results.firstIndex { $0.id == selection?.itemID } ?? 0
        guard !results.isEmpty else { return }
        let target = NavigationBounds.move(index, by: offset, count: results.count)
        selection = .init(sectionID: Self.section, itemID: results[target].id)
    }

    func select(_ item: ScreenshotMedia) {
        selection = .init(sectionID: Self.section, itemID: item.id)
    }

    var sections: [ResultGridSection<ScreenshotMedia>] {
        let title = filter == .all ? "图片与录屏" : filter.title
        return [.init(id: Self.section, title: title, items: results)]
    }

    private func publish(_ results: [ScreenshotMedia]) {
        self.results = results
        if let selection, results.contains(where: { $0.id == selection.itemID }) { return }
        selection = results.first.map { .init(sectionID: Self.section, itemID: $0.id) }
    }

    func latest(_ completion: @escaping (ScreenshotMedia?) -> Void) {
        latestTask?.cancel()
        let folders = folders
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

    func validate(_ item: ScreenshotMedia) throws {
        let values = try item.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.contentModificationDate == item.modified, values.fileSize == item.size else {
            throw CocoaError(.fileReadNoSuchFile)
        }
    }

    @discardableResult func moveToTrash(_ item: ScreenshotMedia) throws -> URL? {
        try validate(item)
        var destination: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
        items.removeAll { $0.id == item.id }
        search(query)
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

    func read(_ item: ScreenshotMedia, accurate: Bool) -> String? {
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
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        cache.setObject(text as NSString, forKey: key, cost: text.utf8.count)
        return text
    }
}
