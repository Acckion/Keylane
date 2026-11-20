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

enum ScreenshotRetention: String, CaseIterable {
    case day, week, month, threeMonths, sixMonths, year, unlimited

    var title: String {
        switch self {
        case .day: "1 天"
        case .week: "1 周"
        case .month: "1 个月"
        case .threeMonths: "3 个月"
        case .sixMonths: "6 个月"
        case .year: "1 年"
        case .unlimited: "无限期"
        }
    }

    func cutoff(at now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .day: calendar.date(byAdding: .day, value: -1, to: now)
        case .week: calendar.date(byAdding: .day, value: -7, to: now)
        case .month: calendar.date(byAdding: .month, value: -1, to: now)
        case .threeMonths: calendar.date(byAdding: .month, value: -3, to: now)
        case .sixMonths: calendar.date(byAdding: .month, value: -6, to: now)
        case .year: calendar.date(byAdding: .year, value: -1, to: now)
        case .unlimited: nil
        }
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
            guard oldValue != enabled else { return }
            configureRetention()
            if !enabled {
                for work in aiContextWork.values { work.cancel() }
                aiContextWork.removeAll()
                stop()
                latestTask?.cancel()
                latestTask = nil
                ocrCache = ScreenshotTextCache()
                items = []
                query = ""
                skippedOCR = 0
                inaccessibleFolders = 0
                publish([])
            }
            configureShelfMonitoring()
        }
    }
    @Published var autoShelf: Bool {
        didSet {
            guard autoShelf != oldValue else { return }
            defaults.set(autoShelf, forKey: "screenshots.autoShelf")
            configureShelfMonitoring()
        }
    }
    @Published private(set) var shelfError = ""
    var addToShelf: (([URL]) -> Bool)?
    private var incomingTracker = IncomingFileTracker()
    private var incomingTimer: Task<Void, Never>?
    @Published var disabledCommands: Set<String> { didSet { defaults.set(Array(disabledCommands), forKey: "disabledScreenshotCommands") } }
    @Published var columns: Int { didSet { defaults.set(columns, forKey: "screenshotColumns") } }
    @Published private(set) var pinnedIDs: Set<String> {
        didSet { defaults.set(pinnedIDs.sorted(), forKey: "pinnedScreenshotPaths") }
    }
    @Published var retention: ScreenshotRetention {
        didSet {
            guard oldValue != retention else { return }
            defaults.set(retention.rawValue, forKey: "screenshotRetention")
            configureRetention()
        }
    }
    @Published private(set) var retentionFailures = 0
    @Published var includeAll: Bool {
        didSet {
            defaults.set(includeAll, forKey: "screenshotIncludeAll")
            if pageActive, oldValue != includeAll { refresh() }
        }
    }
    @Published var recognizesText: Bool {
        didSet {
            defaults.set(recognizesText, forKey: "screenshotOCR")
            if oldValue != recognizesText { updateTextSearch() }
        }
    }
    @Published var accurate: Bool {
        didSet {
            defaults.set(accurate, forKey: "screenshotOCRAccurate")
            if oldValue != accurate { updateTextSearch() }
        }
    }
    @Published var allowCloudOCR: Bool {
        didSet {
            defaults.set(allowCloudOCR, forKey: "screenshotCloudOCR")
            if oldValue != allowCloudOCR {
                cancelImageTextCopies()
                updateTextSearch()
            }
        }
    }
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
    private var aiContextWork: [UUID: ImageTextRecognitionWork] = [:]
    private var items: [ScreenshotMedia] = []
    private var query = ""
    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var latestTask: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private var retentionTimer: Timer?
    private var pinIdentities: [String: ScreenshotMedia.Identity]
    private let trashExpiredItem: (URL) throws -> Void
    private var ocrCache = ScreenshotTextCache()
    private var searchOCR: ImageTextRecognitionWork?
    private var copyWork: [UUID: ImageTextRecognitionWork] = [:]

    init(defaults: UserDefaults = .standard, trashExpiredItem: @escaping (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) {
        self.defaults = defaults
        self.trashExpiredItem = trashExpiredItem
        retention = defaults.string(forKey: "screenshotRetention").flatMap(ScreenshotRetention.init(rawValue:)) ?? .unlimited
        pinIdentities = defaults.data(forKey: "pinnedScreenshotIdentities").flatMap {
            try? JSONDecoder().decode([String: ScreenshotMedia.Identity].self, from: $0)
        } ?? [:]
        autoShelf = defaults.bool(forKey: "screenshots.autoShelf")
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

    deinit {
        retentionTimer?.invalidate()
        retentionTask?.cancel()
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
        for work in aiContextWork.values { work.cancel() }
        aiContextWork.removeAll()
        scopes = updated
        configureRetention()
        cancelImageTextCopies()
        checkFolders()
        latestTask?.cancel()
        latestTask = nil
        configureShelfMonitoring()
        if pageActive { refresh() }
    }

    private func configureRetention() {
        retentionTask?.cancel()
        retentionTask = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
        retentionFailures = 0
        guard enabled, retention != .unlimited, !scopes.isEmpty else { return }
        cleanExpiredCaptures()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.cleanExpiredCaptures()
        }
        retentionTimer?.tolerance = 60
    }

    private func cleanExpiredCaptures() {
        guard enabled, retentionTask == nil, let cutoff = retention.cutoff(at: Date()) else { return }
        let scopes = scopes
        retentionTask = Task.detached(priority: .utility) { [weak self] in
            let folders = scopes.compactMap(\.accessibleURL).map { ($0, $0.resolvingSymlinksInPath().path) }
            let snapshot = ScreenshotCatalog.scan(folders: folders.map(\.0), includeAllMedia: false)
            guard !Task.isCancelled else { return }
            await self?.trashExpiredCaptures(snapshot.items, cutoff: cutoff, folders: folders)
        }
    }

    @MainActor private func trashExpiredCaptures(_ captures: [ScreenshotMedia], cutoff: Date, folders: [(URL, String)]) async {
        guard !Task.isCancelled else { return }
        reconcilePins(in: captures)
        var removed: Set<String> = []
        var failures = 0
        let access = folders.map(\.0).filter { $0.startAccessingSecurityScopedResource() }
        defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
        for item in captures where item.date < cutoff && item.date != .distantPast && !item.needsCloudAccess {
            // Let settings, pinning and scope changes take effect between moves.
            await Task.yield()
            guard !Task.isCancelled else { break }
            guard !pinnedIDs.contains(item.id),
                  let identity = item.identity, !pinIdentities.values.contains(identity),
                  folders.contains(where: { folder, root in
                      let prefix = root == "/" ? "/" : root + "/"
                      return folder.resolvingSymlinksInPath().path == root && item.url.resolvingSymlinksInPath().path.hasPrefix(prefix)
                  }),
                  (try? ScreenshotFileVersion.check(item, allowCloud: false, checkCreationDate: true)) != nil else { continue }
            do {
                try trashExpiredItem(item.url)
                removed.insert(item.id)
            } catch {
                failures += 1
            }
        }
        if !removed.isEmpty {
            items.removeAll { removed.contains($0.id) }
            publish(results.filter { !removed.contains($0.id) })
            if pageActive { refresh() }
        }
        guard !Task.isCancelled else { return }
        retentionFailures = failures
        retentionTask = nil
    }

    private func reconcilePins(in snapshot: [ScreenshotMedia]) {
        guard !pinnedIDs.isEmpty else { return }
        let byPath = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        let byIdentity = Dictionary(grouping: snapshot.compactMap { item in
            item.identity.map { ($0, item.id) }
        }, by: { $0.0 })
        var paths = pinnedIDs
        var updated = pinIdentities
        for path in pinnedIDs {
            if let item = byPath[path] {
                // The visible pin applies to the current file at this path.
                updated[path] = item.identity
            } else if let identity = updated[path], let matches = byIdentity[identity], matches.count == 1 {
                paths.remove(path)
                paths.insert(matches[0].1)
                updated.removeValue(forKey: path)
                updated[matches[0].1] = identity
            }
        }
        if updated != pinIdentities { savePinIdentities(updated) }
        if paths != pinnedIDs { pinnedIDs = paths }
    }

    private func savePinIdentities(_ updated: [String: ScreenshotMedia.Identity]) {
        pinIdentities = updated
        defaults.set(try? JSONEncoder().encode(updated), forKey: "pinnedScreenshotIdentities")
    }

    private func configureShelfMonitoring() {
        incomingTracker.reset()
        incomingTimer?.cancel(); incomingTimer = nil
        shelfError = ""
        if enabled && (autoShelf || pageActive) { refresh() }
        else if !pageActive { stop() }
    }

    private func receiveNewCaptures(_ candidates: [IncomingFile], complete: Bool) {
        guard autoShelf, enabled, complete else { return }
        let ready = incomingTracker.update(candidates)
        if !ready.isEmpty {
            let access = scopes.compactMap(\.accessibleURL).filter { $0.startAccessingSecurityScopedResource() }
            defer { access.forEach { $0.stopAccessingSecurityScopedResource() } }
            if addToShelf?(ready.map(\.url)) != true { shelfError = "自动加入失败，请先启用暂存架。截图仍在原位置。" }
        }
        incomingTimer?.cancel(); incomingTimer = nil
        if incomingTracker.needsRescan {
            incomingTimer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(2100)) } catch { return }
                self?.refresh()
            }
        }
    }

    func start() {
        pageActive = true
        refresh()
    }

    func refresh() {
        guard enabled else { return }
        scanTask?.cancel()
        scanTask = nil
        needsRefresh = false
        checkFolders()
        let folders = scopes.compactMap(\.accessibleURL)
        if pageActive || autoShelf {
            watcher.changed = { [weak self] rebuild in
                guard let self, self.enabled, self.pageActive || self.autoShelf else { return }
                if rebuild { self.refresh() }
                else if self.scanTask != nil { self.needsRefresh = true }
                else { self.scan(self.scopes.compactMap(\.accessibleURL), showingProgress: false) }
            }
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
        if showingProgress && (pageActive || !autoShelf) { scanning = true }
        let includeAll = includeAll
        let watchForShelf = autoShelf
        // A temporarily unavailable configured scope is filtered out before scanning.
        // Its absence is not an empty snapshot: retain the previous incoming baseline.
        let scansEveryScope = Set(folders.map { $0.standardizedFileURL.path }) == Set(scopes.map {
            URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path
        })
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = ScreenshotCatalog.scan(folders: folders, includeAllMedia: includeAll)
            // Classification/metadata reads stay off the UI thread; reuse this scan for both consumers.
            let incoming = watchForShelf ? snapshot.items.filter {
                !$0.needsCloudAccess && (!includeAll || ScreenshotCatalog.isSystemCapture($0.url))
            }.map { IncomingFile(url: $0.url, modified: $0.modified, size: Int64($0.size)) } : []
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.scanTask = nil
                self.scanning = false
                self.inaccessibleFolders = snapshot.inaccessibleFolders
                self.checkFolders()
                self.reconcilePins(in: snapshot.items)
                self.receiveNewCaptures(incoming, complete: scansEveryScope && snapshot.inaccessibleFolders == 0 && self.unavailableScopePaths.isEmpty)
                if self.items != snapshot.items || showingProgress {
                    let preferred = self.selectionAfterRename(in: snapshot.items)
                    self.items = snapshot.items
                    if self.pageActive || !self.autoShelf { self.applySearch(self.query, preservingResults: true, preferred: preferred) }
                } else if (self.pageActive || !self.autoShelf) && self.results.isEmpty && self.searchingText == false {
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
        if pinnedIDs.remove(selected.id) != nil {
            pinnedIDs.insert(replacement.id)
            var updated = pinIdentities
            updated.removeValue(forKey: selected.id)
            updated[replacement.id] = replacement.identity
            savePinIdentities(updated)
        }
        return .init(sectionID: pinnedIDs.contains(replacement.id) ? Self.pinnedSection : Self.section, itemID: replacement.id)
    }

    func stop() {
        pageActive = false
        cancelSearch(); cancelImageTextCopies()
        searchingText = false; scanning = false; skippedOCR = 0
        guard !enabled || !autoShelf else { return }
        incomingTimer?.cancel(); incomingTimer = nil; incomingTracker.reset()
        watcher.stop()
        releaseScopeAccess()
        needsRefresh = false
        scanTask?.cancel()
        scanTask = nil
        cancelSearch()
        cancelImageTextCopies()
        scanning = false
        searchingText = false
        skippedOCR = 0
    }

    private func cancelImageTextCopies() {
        for work in copyWork.values { work.cancel() }
        copyWork.removeAll()
    }

    private func updateTextSearch() {
        if pageActive, !ScreenshotQuery(query).text.isEmpty { applySearch(query, preservingResults: false) }
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
                guard let text = cache.read(item, accurate: accurate, allowCloud: allowCloud, work: work) else {
                    if work.cancelled { return }
                    skipped += 1
                    continue
                }
                if text.localizedStandardContains(criteria.text) { matches.append(item) }
            }
            let completed = (matches: matches, skipped: skipped)
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self, self.searchOCR === work, !work.cancelled else { return }
                self.searchTask = nil
                self.searchOCR = nil
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
        var updated = pinIdentities
        updated[item.id] = pinned ? nil : item.identity
        savePinIdentities(updated)
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
        try validateTextCopy(item)
        guard item.kind == .image else { throw ImageTextError.notImage }
        let changeCount = board.changeCount
        let accurate = accurate
        let allowCloud = allowCloudOCR
        let work = ImageTextRecognitionWork()
        let id = UUID()
        copyWork[id] = work
        defer { copyWork.removeValue(forKey: id) }
        let outcome = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Result {
                    guard !work.cancelled else { throw CancellationError() }
                    try ScreenshotFileVersion.check(item, allowCloud: allowCloud)
                    return try mode.recognize(in: VNImageRequestHandler(url: item.url), accurate: accurate, work: work)
                }
            }.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, !work.cancelled else { throw CancellationError() }
        let text = try outcome.get()
        try validateTextCopy(item)
        guard !text.isEmpty else { return false }
        guard board.changeCount == changeCount else { throw ImageTextError.pasteboardChanged }
        try writeText(text, to: board)
        return true
    }

    var aiContextItems: [ScreenshotMedia] { items }

    @MainActor func aiTextContext(_ item: ScreenshotMedia) async throws -> String {
        try validateAIContext(item)
        guard item.kind == .image else { throw ImageTextError.notImage }
        let folders = scopes.compactMap(\.accessibleURL).filter { folder in
            let root = folder.standardizedFileURL.path
            let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
            return root == "/" || parent == root || parent.hasPrefix(root + "/")
        }
        let access = folders.filter { $0.startAccessingSecurityScopedResource() }
        defer { for folder in access { folder.stopAccessingSecurityScopedResource() } }
        let cache = ocrCache, accurate = accurate
        let work = ImageTextRecognitionWork()
        let id = UUID()
        aiContextWork[id] = work
        defer { aiContextWork.removeValue(forKey: id) }
        let text = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                cache.read(item, accurate: accurate, allowCloud: false, work: work)
            }.value
        } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard !work.cancelled else { throw CancellationError() }
        try validateAIContext(item)
        guard let text, !text.isEmpty else { throw ImageTextError.noText }
        guard text.utf8.count <= 32_000 else { throw ImageTextError.textTooLarge }
        return text
    }

    func validateAIContext(_ item: ScreenshotMedia) throws {
        try validateTextAccess(item, requiresPage: false, allowCloud: false)
    }

    private func validateTextCopy(_ item: ScreenshotMedia) throws {
        try validateTextAccess(item, requiresPage: true, allowCloud: allowCloudOCR)
    }

    private func validateTextAccess(_ item: ScreenshotMedia, requiresPage: Bool, allowCloud: Bool) throws {
        guard enabled, !requiresPage || pageActive else { throw CancellationError() }
        let parent = item.url.deletingLastPathComponent().standardizedFileURL.path
        guard scopes.contains(where: { scope in
            guard let folder = scope.accessibleURL else { return false }
            let root = folder.standardizedFileURL.path
            return root == "/" || parent == root || parent.hasPrefix(root + "/")
        }) else { throw CocoaError(.fileReadNoPermission) }
        try ScreenshotFileVersion.check(item, allowCloud: allowCloud)
    }

    fileprivate enum ImageTextError: LocalizedError {
        case notImage, cloudDownloadDisabled, pasteboardChanged, noText, textTooLarge

        var errorDescription: String? {
            switch self {
            case .noText: return "截图中没有可处理的文字。"
            case .textTooLarge: return "截图文字超过 32,000 字节，请缩小处理范围。"
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
        try ScreenshotFileVersion.check(item)
    }

    @discardableResult func moveToTrash(_ item: ScreenshotMedia) throws -> URL? {
        try validate(item)
        var destination: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &destination)
        items.removeAll { $0.id == item.id }
        if pinnedIDs.remove(item.id) != nil {
            var updated = pinIdentities
            updated.removeValue(forKey: item.id)
            savePinIdentities(updated)
        }
        applySearch(query, preservingResults: false)
        if pageActive { refresh() }
        return destination as URL?
    }
}

private enum ScreenshotFileVersion {
    static func check(_ item: ScreenshotMedia, allowCloud: Bool = true, checkCreationDate: Bool = false) throws {
        let currentURL = URL(fileURLWithPath: item.url.path)
        var keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
                                         .fileSizeKey, .fileResourceIdentifierKey, .volumeIdentifierKey]
        if !allowCloud {
            keys.formUnion([.fileAllocatedSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        }
        if checkCreationDate { keys.insert(.creationDateKey) }
        let values = try currentURL.resourceValues(forKeys: keys)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.contentModificationDate == item.modified, values.fileSize == item.size,
              !checkCreationDate || (values.creationDate ?? values.contentModificationDate) == item.date,
              item.identity?.matches(values) ?? true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if !allowCloud, item.needsCloudAccess || ScreenshotCatalog.needsCloudAccess(currentURL, values: values) {
            throw ScreenshotLibrary.ImageTextError.cloudDownloadDisabled
        }
    }
}

private final class ScreenshotTextCache: @unchecked Sendable {
    private struct Key: Hashable {
        let url: URL
        let modified: Date
        let size: Int
        let identity: ScreenshotMedia.Identity?
        let accurate: Bool
    }
    private final class CacheKey: NSObject {
        let value: Key
        init(_ value: Key) { self.value = value }
        override var hash: Int { value.hashValue }
        override func isEqual(_ object: Any?) -> Bool { (object as? CacheKey)?.value == value }
    }
    private let cache: NSCache<CacheKey, NSString> = {
        let value = NSCache<CacheKey, NSString>()
        value.countLimit = 2_000
        value.totalCostLimit = 16 * 1024 * 1024
        return value
    }()

    func read(_ item: ScreenshotMedia, accurate: Bool, allowCloud: Bool, work: ImageTextRecognitionWork) -> String? {
        guard !work.cancelled else { return nil }
        let key = CacheKey(.init(url: item.url, modified: item.modified, size: item.size, identity: item.identity, accurate: accurate))
        if let text = cache.object(forKey: key) { return text as String }
        guard (try? ScreenshotFileVersion.check(item, allowCloud: allowCloud)) != nil, !work.cancelled,
              let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2560
              ] as CFDictionary),
              !work.cancelled,
              let text = try? ImageTextRecognition.ocr.recognize(in: VNImageRequestHandler(cgImage: image),
                                                                 accurate: accurate, work: work),
              !work.cancelled, (try? ScreenshotFileVersion.check(item, allowCloud: allowCloud)) != nil else { return nil }
        cache.setObject(text as NSString, forKey: key, cost: text.utf8.count)
        return text
    }
}
