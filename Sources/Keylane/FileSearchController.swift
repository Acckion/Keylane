import AppKit
import Combine
import CoreServices
import KeylaneCore

private final class FileScanCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
struct AutomaticFileExclusion: Codable, Identifiable, Equatable {
    var id: String { path }; let path: String; let reason: String; var events: Int
}
final class FileSearchController: ObservableObject {
    private var aiIndexRevision = UUID()
    var aiAccessRevision: UUID { aiIndexRevision }
    @Published var options: FileSearchOptions { willSet { if newValue != options { aiIndexRevision = UUID() } } didSet { if options != oldValue { configure(old: oldValue) } } }
    @Published private(set) var automaticExclusions: [AutomaticFileExclusion] = [] { willSet { if newValue != automaticExclusions { aiIndexRevision = UUID() } } }
    @Published private(set) var stats = FileIndexStats()
    @Published private(set) var indexStatus = "尚未建立本地补充索引"
    @Published private(set) var inaccessible: [String] = []
    @Published private(set) var indexing = false
    @Published private(set) var indexPaused: Bool
    @Published private(set) var directorySort: FileDirectorySort
    @Published private(set) var browsingDirectory: URL?
    @Published private(set) var isSearching = false
    var updated: (([SpotlightFile], String) -> Void)?
    private let preferences: UserDefaults
    private let availableCapacity: (URL) -> Int64
    private let watchEnabled: Bool
    private let writer = DispatchQueue(label: "org.keylane.files.index", qos: .utility)
    private let reader = DispatchQueue(label: "org.keylane.files.search", qos: .userInitiated)
    private let databaseURL: URL
    private var runtime: FileScanCancellation?
    var isRunning: Bool { runtime != nil }
    private var writeDB: FileSearchIndex?
    private var readDB: FileSearchIndex?
    private var cancellation = FileScanCancellation()
    private var queryVersion = 0
    private var pendingQuery: DispatchWorkItem?
    private var queryCancellation = FileScanCancellation()
    private var lastPublished: [SpotlightFile] = []
    private(set) var lastPublishedQuery = ""
    private var lastPublishedStatus = ""
    private var currentQuery = ""
    private var queryIsBlank: Bool { currentQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var includesQueryContents = true
    private var standalone = true
    private var showPathItself = false
    private var hasQuery = false
    private var recentPaths: [String]
    private var recentOpenDates: [String: Date]
    private let recentSpotlightSearch: (([String], @escaping ([RecentlyUsedFile]) -> Void) -> Void)?
    private var recentlyRemoved = Set<String>()
    private var preparedRecents: (roots: [String], expires: ContinuousClock.Instant, files: [RecentlyUsedFile])?
    private var usePreparedRecents = false
    private var localQueryResolved = false
    private var didStart = false
    private var indexFailure: String?
    private var grants: [String: Data]
    private var selectedScopePaths: Set<String>
    private var activeURLs: [URL] = []
    private var spotlight = SpotlightSearch()
    private var spotlightResults: [RankedFile] = []
    private var localResults: [RankedFile] = []
    private let mergeQueue = DispatchQueue(label: "org.keylane.files.merge", qos: .userInitiated)
    private var pendingMerge: DispatchWorkItem?
    private var mergeVersion = 0
    private var watch: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "org.keylane.files.events", qos: .utility)
    private var watchLifetime: FileScanCancellation?
    private var pendingEvents: [IndexEventBatch] = []
    private var pendingEventCount = 0
    private var processingEvents = false
    private var recoverEvents = false
    private static let maxQueuedEvents = 8192
    private var pendingRefresh: DispatchWorkItem?
    private var restored: Set<String> = [] { didSet { if oldValue != restored { aiIndexRevision = UUID() } } }
    private var dirtyPaths = Set<String>()
    private var needsFullScan = false
    static var defaults: FileSearchOptions {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var options = FileSearchOptions(roots: [home, "/Applications", home + "/Library/Mobile Documents/com~apple~CloudDocs"])
        options.enabled = false
        return options
    }
    init(directory: URL? = nil, preferences: UserDefaults = .standard, defaultOptions: FileSearchOptions? = nil, watchChanges: Bool = true,
         availableCapacity: ((URL) -> Int64)? = nil, startImmediately: Bool = true,
         recentSpotlightSearch: (([String], @escaping ([RecentlyUsedFile]) -> Void) -> Void)? = nil) {
        self.preferences = preferences; self.watchEnabled = watchChanges
        self.recentSpotlightSearch = recentSpotlightSearch
        indexPaused = preferences.bool(forKey: "fileIndexPaused")
        directorySort = preferences.string(forKey: "fileDirectorySort").flatMap(FileDirectorySort.init(rawValue:)) ?? .name
        recentPaths = Array((preferences.stringArray(forKey: "fileSearchRecentPaths") ?? []).prefix(60))
        let paths = Set(recentPaths)
        recentOpenDates = (preferences.dictionary(forKey: "fileSearchRecentOpenDates") as? [String: Date] ?? [:])
            .filter { paths.contains($0.key) }
        databaseURL = directory?.appendingPathComponent("index.sqlite") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/FileSearch/index.sqlite")
        self.availableCapacity = availableCapacity ?? { url in (try? FileManager.default.attributesOfFileSystem(forPath:url.path)[.systemFreeSize] as? Int64) ?? 0 }
        options = preferences.data(forKey: "fileSearchOptions").flatMap { try? JSONDecoder().decode(FileSearchOptions.self, from: $0) } ?? defaultOptions ?? Self.defaults
        grants = preferences.dictionary(forKey: "fileSearchGrants") as? [String: Data] ?? [:]
        selectedScopePaths = Set(preferences.stringArray(forKey: "fileSearchSelectedScopes") ?? [])
        if preferences.data(forKey:"fileSearchOptions") == nil, preferences.string(forKey:"fileSearchScope") == "folder", let data = preferences.data(forKey:"fileSearchBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],bookmarkDataIsStale:&stale) {
                options.roots = [url.path]; grants[url.path] = data
                preferences.set(grants,forKey:"fileSearchGrants")
                preferences.set(try? JSONEncoder().encode(options),forKey:"fileSearchOptions")
            }
        }
        restored = Set(preferences.stringArray(forKey: "fileSearchRestoredPaths") ?? [])
        automaticExclusions = preferences.data(forKey: "fileSearchAutomaticExclusions").flatMap { try? JSONDecoder().decode([AutomaticFileExclusion].self, from: $0) } ?? []
        // Move Python bytecode caches to an editable rule once. A later explicit
        // removal must survive restart, and unrelated custom rules are retained.
        if !preferences.bool(forKey: "fileSearchPythonCacheIgnoreMigrated") {
            if !options.ignorePatterns.contains("__pycache__") { options.ignorePatterns.append("__pycache__") }
            preferences.set(try? JSONEncoder().encode(options), forKey: "fileSearchOptions")
            preferences.set(true, forKey: "fileSearchPythonCacheIgnoreMigrated")
        }
        let previousExclusions = automaticExclusions
        automaticExclusions.removeAll { URL(fileURLWithPath: $0.path).lastPathComponent == "__pycache__" }
        if automaticExclusions != previousExclusions {
            preferences.set(try? JSONEncoder().encode(automaticExclusions), forKey: "fileSearchAutomaticExclusions")
        }
        if let data = preferences.data(forKey: "fileSearchLastStats"), let value = try? JSONDecoder().decode(FileIndexStats.self, from:data) { stats = value }
        spotlight.updated = { [weak self] results, _ in
            guard let self, self.isRunning else { return }
            self.spotlightResults = results
            if self.isSearching && !self.localQueryResolved && results.isEmpty { return }
            self.publish()
        }
        if indexPaused { indexStatus = "本地索引已暂停，仍可搜索已有条目。" }
        if startImmediately { startRuntime() }
    }

    func startRuntime() {
        guard runtime == nil else { return }
        let token = FileScanCancellation()
        runtime = token
        resolveGrants()
        writer.async { [weak self] in
            guard let self, !token.cancelled else { return }
            do {
                self.writeDB = try FileSearchIndex(url: self.databaseURL)
                try self.reader.sync {
                    guard !token.cancelled else { return }
                    self.readDB = try FileSearchIndex(url: self.databaseURL)
                    self.refreshStats(runtime: token)
                }
                DispatchQueue.main.async {
                    guard !token.cancelled else { return }
                    if !self.queryIsBlank { self.reloadSearch() }
                }
            } catch {
                DispatchQueue.main.async {
                    if !token.cancelled { self.reportIndexFailure(error) }
                }
            }
        }
    }

    func stopRuntime() {
        guard let runtime else { return }
        runtime.cancel()
        self.runtime = nil
        recentlyRemoved.removeAll()
        cancellation.cancel()
        cancellation = FileScanCancellation()
        cancel()
        stopWatch()
        didStart = false
        indexFailure = nil
        indexing = false
        inaccessible = []
        lastPublished = []
        lastPublishedQuery = ""
        lastPublishedStatus = ""
        indexStatus = "文件搜索扩展已关闭"
        updated?([], indexStatus)
        resolveGrants()
        writer.async { [weak self] in self?.writeDB = nil }
        reader.async { [weak self] in self?.readDB = nil }
    }

    deinit { stopWatch(); cancelMerge(); cancellation.cancel(); activeURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
    private func configure(old: FileSearchOptions) {
        preferences.set(try? JSONEncoder().encode(options), forKey: "fileSearchOptions")
        var previous = old; previous.searchFromLauncher = options.searchFromLauncher
        guard previous != options, let runtime else { return }
        let changedExclusions = Set(previous.excludedPaths).symmetricDifference(options.excludedPaths)
        previous.excludedPaths = options.excludedPaths
        if previous == options {
            reloadSearch()
            if !indexPaused {
                dirtyPaths.formUnion(changedExclusions)
                scheduleRefresh()
            }
            return
        }
        cancelMerge(); cancellation.cancel(); spotlight.cancel(); spotlightResults = []; localResults = []; stopWatch()
        let contentEnabled = options.contentSearch
        let removed = old.roots.filter { !options.roots.contains($0) }
        writer.async { [weak self] in
            guard let self else { return }
            do { for root in removed { try self.writeDB?.removeScope(root) }; if !contentEnabled { try self.writeDB?.clearBodies() } } catch {
                DispatchQueue.main.async { if !runtime.cancelled { self.indexStatus = error.localizedDescription } }
            }
        }
        if options.enabled {
            startIndex()
            reloadSearch()
        }
        else { indexing = false; indexStatus = "文件搜索已关闭"; updated?([], indexStatus) }
    }
    private func resolveGrants() {
        aiIndexRevision = UUID()
        activeURLs.forEach { $0.stopAccessingSecurityScopedResource() }; activeURLs = []
        guard isRunning else { return }
        for (_,data) in grants {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope,.withoutUI], bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() { activeURLs.append(url) }
        }
    }
    var hasAuthorizedScope: Bool {
        authorizedRoots.contains { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && directory.boolValue && FileManager.default.isReadableFile(atPath: path)
        }
    }

    private var authorizedRoots: [String] {
        // Authorization survives a disconnected volume. The scanner applies
        // keepRemovedVolumes when a configured root is temporarily missing.
        options.roots.filter { selectedScopePaths.contains($0) || grants[$0] != nil }
    }

    private var authorizedOptions: FileSearchOptions {
        var authorized = options
        authorized.roots = authorizedRoots
        return authorized
    }

    func inspect(_ url: URL) throws -> SpotlightFile {
        guard isRunning, options.enabled else { throw FileSearchLocation.Failure.outsideScope }
        var locations = FileSearchLocation(options: authorizedOptions, automaticExclusions: automaticExclusions.map(\.path), restored: restored)
        return try locations.item(at: url)
    }

    func rememberOpenedFile(_ file: SpotlightFile) {
        guard !file.isDirectory else { return }
        recentPaths.removeAll { $0 == file.id }
        recentPaths.insert(file.id, at: 0)
        if recentPaths.count > 60 { recentPaths.removeLast() }
        recentOpenDates[file.id] = Date()
        saveRecentHistory()
    }

    private func saveRecentHistory() {
        let retained = Set(recentPaths)
        recentOpenDates = recentOpenDates.filter { retained.contains($0.key) }
        preferences.set(recentPaths, forKey: "fileSearchRecentPaths")
        preferences.set(recentOpenDates, forKey: "fileSearchRecentOpenDates")
    }

    func setDirectorySort(_ sort: FileDirectorySort) {
        guard directorySort != sort else { return }
        directorySort = sort
        preferences.set(sort.rawValue, forKey: "fileDirectorySort")
        if browsingDirectory != nil { reloadSearch() }
    }

    func setIndexPaused(_ paused: Bool) {
        guard indexPaused != paused else { return }
        indexPaused = paused
        preferences.set(paused, forKey: "fileIndexPaused")
        if paused {
            cancellation.cancel()
            cancellation = FileScanCancellation()
            stopWatch()
            indexing = false
            indexStatus = "本地索引已暂停，仍可搜索已有条目。"
        } else { startIndex() }
        if localQueryResolved { publish() }
    }

    func exclude(_ url: URL) throws -> String {
        let item = try inspect(url)
        guard !authorizedRoots.contains(item.id) else {
            throw FileSearchLocation.Failure.scopeRoot
        }
        if !options.excludedPaths.contains(item.id) {
            let path = item.id
            let visible = lastPublished.filter { !FileSearchLocation.contains($0.id, in: path) }
            options.excludedPaths.append(path)
            if hasQuery { emit(visible, visible.isEmpty ? "没有匹配项。" : lastPublishedStatus) }
        }
        return item.id
    }

    func undoExclusion(_ path: String) {
        options.excludedPaths.removeAll { $0 == path }
    }

    func mutationTarget(_ url: URL) throws -> FileResultOperations.Target {
        let file = try inspect(url)
        guard !authorizedRoots.contains(file.id),
              let root = authorizedRoots.filter({ FileSearchLocation.contains(file.id, in: $0) }).max(by: { $0.count < $1.count }),
              let canonicalRoot = FileSearchLocation.canonicalPath(root) else { throw FileResultOperations.Failure.unsupported }
        let relative = file.id.dropFirst(root.count).drop(while: { $0 == "/" })
        let expected = URL(fileURLWithPath: canonicalRoot).appendingPathComponent(String(relative)).path
        guard FileSearchLocation.canonicalPath(file.id) == expected else { throw FileResultOperations.Failure.unsupported }
        return try FileResultOperations.target(for: file.url)
    }

    func refreshAfterFileAction(_ url: URL, removed: Bool) {
        guard isRunning, options.enabled else { return }
        if removed {
            recentlyRemoved.insert(url.path)
            let visible = lastPublished.filter { !FileSearchLocation.contains($0.id, in: url.path) }
            emit(visible, visible.isEmpty ? "没有匹配项。" : lastPublishedStatus)
            recentPaths.removeAll { FileSearchLocation.contains($0, in: url.path) }
            saveRecentHistory()
            let roots = authorizedRoots
            let token = runtime
            writer.async { [weak self] in
                guard let self, token?.cancelled == false else { return }
                do {
                    let epoch = UUID().uuidString
                    for root in roots { try self.writeDB?.removeUnseen(root: root, subtree: url.path, epoch: epoch) }
                } catch {
                    DispatchQueue.main.async { if token?.cancelled == false { self.indexStatus = error.localizedDescription } }
                }
                DispatchQueue.main.async {
                    guard token?.cancelled == false else { return }
                    self.recentlyRemoved.remove(url.path)
                    self.reloadSearch()
                }
            }
        }
        if !indexPaused {
            dirtyPaths.insert(url.path)
            scheduleRefresh()
        }
        if !removed && (browsingDirectory != nil || queryIsBlank) { reloadSearch() }
    }

    func applyPermissionEnabled(_ enabled: Bool) {
        var updated = options
        updated.enabled = enabled && hasAuthorizedScope
        if updated.enabled { updated.roots = authorizedRoots }
        if updated != options { options = updated }
    }

    func addScope(suggested: URL? = nil) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.directoryURL = suggested ?? FileManager.default.homeDirectoryForCurrentUser
        panel.message = "选择并授权文件搜索范围。中文文件名不需要额外语言设置；内容搜索另行开启。"
        panel.prompt = "添加搜索范围"
        guard panel.runModal() == .OK else { return }
        var roots = options.roots
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            selectedScopePaths.insert(path)
            if let data = try? url.bookmarkData(options: [.withSecurityScope,.securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) { grants[path] = data }
            if !roots.contains(path) { roots.append(path) }
        }
        preferences.set(grants, forKey: "fileSearchGrants")
        preferences.set(Array(selectedScopePaths), forKey: "fileSearchSelectedScopes")
        resolveGrants()
        if options.roots == roots { startIndex() } else { options.roots = roots }
    }
    func removeScope(_ path: String) {
        grants.removeValue(forKey: path)
        selectedScopePaths.remove(path)
        preferences.set(grants, forKey: "fileSearchGrants")
        preferences.set(Array(selectedScopePaths), forKey: "fileSearchSelectedScopes")
        options.roots.removeAll { $0 == path }
        resolveGrants()
    }
    func restore(_ path: String) {
        restored.insert(path)
        preferences.set(restored.sorted(), forKey: "fileSearchRestoredPaths")
        automaticExclusions.removeAll { $0.path == path }
        saveAutomatic()
        startIndex()
    }
    private func saveAutomatic() { preferences.set(try? JSONEncoder().encode(automaticExclusions), forKey: "fileSearchAutomaticExclusions") }
    func reset() {
        grants.removeAll()
        selectedScopePaths.removeAll()
        preferences.removeObject(forKey: "fileSearchGrants")
        preferences.removeObject(forKey: "fileSearchSelectedScopes")
        resolveGrants()
        automaticExclusions = []
        restored.removeAll()
        churn.removeAll()
        preferences.removeObject(forKey: "fileSearchRestoredPaths")
        saveAutomatic()
        recentPaths = []
        recentOpenDates = [:]
        preferences.removeObject(forKey: "fileSearchRecentPaths")
        preferences.removeObject(forKey: "fileSearchRecentOpenDates")
        indexPaused = false
        preferences.removeObject(forKey: "fileIndexPaused")
        directorySort = .name
        preferences.removeObject(forKey: "fileDirectorySort")
        options = Self.defaults
    }
    func cancel() {
        cancelMerge()
        let wasSearching = hasQuery
        hasQuery = false
        browsingDirectory = nil
        queryVersion += 1; pendingQuery?.cancel(); pendingQuery = nil; queryCancellation.cancel(); spotlight.cancel(); currentQuery = ""; localResults = []; spotlightResults = []; localQueryResolved = false; isSearching = false
        lastPublished = []
        lastPublishedQuery = ""
        lastPublishedStatus = ""
        if wasSearching {
            reader.async { [weak self] in self?.readDB?.releaseCachedPages() }
        }
    }
    func search(_ text: String, includeContents: Bool = true, standalone: Bool = true, showPathItself: Bool = false) {
        let scopeChanged = includesQueryContents != includeContents || self.standalone != standalone
        let changed = !hasQuery || currentQuery != text || scopeChanged || self.showPathItself != showPathItself
        hasQuery = true
        currentQuery = text
        includesQueryContents = includeContents
        self.standalone = standalone
        self.showPathItself = showPathItself
        guard isRunning, options.enabled else { emit([], "文件搜索已关闭，请在设置中开启。"); return }
        if let path = FileSearchLocation.typedURL(text) {
            searchLocation(path, browse: standalone && !showPathItself)
            return
        }
        browsingDirectory = nil
        let blank = queryIsBlank
        if blank, standalone {
            searchRecentFiles()
            return
        }
        guard !blank, text.count <= 256 else {
            stopSearchJobs()
            isSearching = false
            emit([], text.count > 256 ? "文件搜索最多256个字符。" : "输入文件名或多个关键词；搜索范围可在设置中添加并授权。")
            return
        }
        if !didStart { startIndex() }
        if changed {
            stopSearchJobs()
            isSearching = true
            if scopeChanged { emit([], "正在搜索…") }
            let roots = authorizedRoots
            if !options.useIgnoreFiles, !roots.isEmpty {
                spotlight.search(text, root: roots.count == 1 ? URL(fileURLWithPath: roots[0]) : nil)
            }
        }
        refreshQuery(delay: changed ? 0.06 : 0)
    }

    private func stopSearchJobs() {
        cancelMerge()
        queryVersion += 1
        pendingQuery?.cancel()
        queryCancellation.cancel()
        spotlight.cancel()
        localResults = []
        spotlightResults = []
        localQueryResolved = false
    }

    private func reloadSearch() {
        guard hasQuery else { return }
        let query = currentQuery
        hasQuery = false
        search(query, includeContents: includesQueryContents, standalone: standalone, showPathItself: showPathItself)
    }

    /// Capture authorization metadata only. Filesystem validation runs off the UI actor.
    @MainActor func aiReadScope() throws -> (@Sendable () -> FileSearchLocation) {
        guard isRunning, options.enabled else { throw AIToolContractError.unavailable }
        let options = authorizedOptions, exclusions = automaticExclusions.map(\.path), restored = restored
        return { FileSearchLocation(options: options, automaticExclusions: exclusions, restored: restored) }
    }

    /// Pure declaration snapshot. Search runs only after the file tool's root-bound approval.
    @MainActor func aiToolIndexSource() -> AIFileToolIndexSource? {
        guard let runtime, !runtime.cancelled, options.enabled else { return nil }
        let revision = aiIndexRevision, config = options, scopeGrants = grants, selected = selectedScopePaths
        let exclusions = automaticExclusions, restoredPaths = restored
        let current: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.runtime === runtime && !runtime.cancelled && self.aiIndexRevision == revision &&
                self.options == config && self.grants == scopeGrants && self.selectedScopePaths == selected &&
                self.automaticExclusions == exclusions && self.restored == restoredPaths
        }
        return .init(isCurrent: current, search: { [weak self] query, directory in
            guard let self, current() else { throw CancellationError() }
            let result = try await self.aiSearch(query, limit: 200, within: directory)
            guard current() else { throw CancellationError() }
            return result.map(\.url.path)
        })
    }

    /// Independent bounded filename query. Never changes the visible page or starts an index scan.
    @MainActor func aiSearch(_ query: String, limit: Int, within: String? = nil) async throws -> [SpotlightFile] {
        guard let runtime, options.enabled, (1...200).contains(limit) else { throw AIToolContractError.unavailable }
        var snapshot = authorizedOptions
        snapshot.contentSearch = false
        let config = snapshot
        let exclusions = automaticExclusions.map(\.path)
        let cancellation = FileScanCancellation()
        return try await withTaskCancellationHandler {
            let result: [SpotlightFile] = try await withCheckedThrowingContinuation { continuation in
                reader.async(execute: DispatchWorkItem { [weak self] in
                    do {
                        guard let self, let db = self.readDB, !runtime.cancelled, !cancellation.cancelled else { throw CancellationError() }
                        let files = try db.search(query, options: config, excluded: exclusions + config.excludedPaths, limit: limit, within: within,
                            isCancelled: { cancellation.cancelled || runtime.cancelled })
                        continuation.resume(returning: files)
                    } catch { continuation.resume(throwing: error) }
                })
            }
            try Task.checkCancellation()
            var latest = authorizedOptions
            latest.contentSearch = false
            guard !runtime.cancelled, options.enabled, latest == config,
                  automaticExclusions.map(\.path) == exclusions else { throw AIToolContractError.unavailable }
            return result
        } onCancel: { cancellation.cancel() }
    }

    func recentForLauncherSwipe() async -> [SpotlightFile] {
        guard options.enabled else { return [] }
        let config = authorizedOptions
        let paths = recentPaths
        let dates = recentOpenDates
        let exclusions = automaticExclusions.map(\.path)
        let restored = restored
        let removed = recentlyRemoved
        // The visible search cancels its own Spotlight query when entering a page.
        let previewSpotlight = SpotlightSearch()
        defer { withExtendedLifetime(previewSpotlight) {} }
        let search = recentSpotlightSearch ?? previewSpotlight.recentlyUsed
        let system: [RecentlyUsedFile] = await withCheckedContinuation { continuation in
            search(config.roots) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled else { return [] }
        preparedRecents = (config.roots, ContinuousClock.now + .seconds(10), system)
        return await withCheckedContinuation { continuation in
            reader.async {
                let files = Self.recentFiles(paths: paths, dates: dates, system: system, config: config,
                                             exclusions: exclusions, restored: restored, removed: removed, limit: 12)
                continuation.resume(returning: files)
            }
        }
    }

    func usePreparedRecentsOnNextSearch() {
        usePreparedRecents = true
    }

    private nonisolated static func recentFiles(
        paths: [String], dates: [String: Date], system: [RecentlyUsedFile],
        config: FileSearchOptions, exclusions: [String], restored: Set<String>, removed: Set<String>,
        limit: Int, cancellation: FileScanCancellation? = nil
    ) -> [SpotlightFile] {
        var used = dates
        for file in system where file.date > (used[file.path] ?? .distantPast) {
            used[file.path] = file.date
        }
        let newest = used.keys.sorted { a, b in
            let first = used[a] ?? .distantPast
            let second = used[b] ?? .distantPast
            return first == second ? a < b : first > second
        }
        let candidates = newest + paths.filter { used[$0] == nil }
        var locations = FileSearchLocation(options: config, automaticExclusions: exclusions, restored: restored)
        var seen = Set<String>()
        var files: [SpotlightFile] = []
        for path in candidates {
            if cancellation?.cancelled == true { return [] }
            guard path.hasPrefix("/"), !removed.contains(where: { FileSearchLocation.contains(path, in: $0) }),
                  let file = try? locations.item(at: URL(fileURLWithPath: path)), !file.isDirectory,
                  let canonical = FileSearchLocation.canonicalPath(file.id),
                  seen.insert(canonical).inserted else { continue }
            files.append(file)
            if files.count == limit { break }
        }
        return files
    }

    private func searchRecentFiles() {
        stopSearchJobs()
        let cancellation = FileScanCancellation()
        queryCancellation = cancellation
        let ticket = queryVersion
        let config = authorizedOptions
        let paths = recentPaths
        let dates = recentOpenDates
        let exclusions = automaticExclusions.map(\.path)
        let restored = restored
        let removed = recentlyRemoved
        isSearching = true
        if lastPublishedQuery != currentQuery { emit([], "正在载入最近使用的文件…") }

        let publish: ([RecentlyUsedFile], Bool) -> Void = { [weak self] system, finished in
            guard let self, !cancellation.cancelled else { return }
            self.reader.async { [weak self] in
                guard !cancellation.cancelled else { return }
                let files = Self.recentFiles(paths: paths, dates: dates, system: system, config: config,
                                             exclusions: exclusions, restored: restored, removed: removed,
                                             limit: 30, cancellation: cancellation)
                DispatchQueue.main.async {
                    guard let self, self.queryVersion == ticket, self.isRunning, self.options.enabled, !cancellation.cancelled,
                          finished || !files.isEmpty else { return }
                    self.emit(files, files.isEmpty ? "最近打开的文件会显示在这里。" : "最近使用")
                    self.isSearching = !finished
                }
            }
        }
        let usePrepared = usePreparedRecents
        usePreparedRecents = false
        if usePrepared, let preparedRecents, preparedRecents.roots == config.roots,
           preparedRecents.expires > ContinuousClock.now {
            publish(preparedRecents.files, true)
            return
        }
        if !paths.isEmpty { publish([], false) }
        let search = recentSpotlightSearch ?? spotlight.recentlyUsed
        search(config.roots) { publish($0, true) }
    }

    private func searchLocation(_ url: URL, browse: Bool) {
        stopSearchJobs()
        let cancellation = FileScanCancellation()
        queryCancellation = cancellation
        let ticket = queryVersion
        let config = authorizedOptions
        let exclusions = automaticExclusions.map(\.path)
        let restored = restored
        let sort = directorySort
        if !browse { browsingDirectory = nil }
        isSearching = true
        reader.async { [weak self] in
            guard !cancellation.cancelled else { return }
            var locations = FileSearchLocation(options: config, automaticExclusions: exclusions, restored: restored)
            let result = Result { () -> ([SpotlightFile], String, URL?) in
                let file = try locations.item(at: url)
                if browse && file.isDirectory {
                    let children = try locations.children(of: file.url, sortedBy: sort, isCancelled: { cancellation.cancelled })
                    return (children, children.isEmpty ? "该文件夹没有可显示的项目。" : "\(file.name) · \(children.count) 项", file.url)
                }
                return ([file], file.url.path, nil)
            }
            DispatchQueue.main.async {
                guard let self, self.queryVersion == ticket, !cancellation.cancelled else { return }
                switch result {
                case .success(let (items, status, directory)):
                    self.browsingDirectory = directory
                    self.emit(items, status)
                case .failure(let error):
                    self.browsingDirectory = nil
                    self.emit([], error.localizedDescription)
                }
                self.isSearching = false
            }
        }
    }
    private func refreshQuery(delay: Double = 0) {
        guard isRunning, options.enabled, !queryIsBlank else { return }
        pendingQuery?.cancel(); queryCancellation.cancel(); queryCancellation = FileScanCancellation()
        let cancellation = queryCancellation
        queryVersion += 1; let ticket = queryVersion
        let text = currentQuery
        var config = authorizedOptions
        config.contentSearch = config.contentSearch && includesQueryContents
        let queryOptions = config
        let excluded = options.excludedPaths + automaticExclusions.map(\.path)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !cancellation.cancelled else { return }
            self.reader.async { [weak self] in
                guard let self, !cancellation.cancelled else { return }
                do {
                    let result = try self.readDB?.searchRanked(text, options: queryOptions, excluded: excluded, isCancelled: { cancellation.cancelled }) ?? []
                    DispatchQueue.main.async {
                        guard self.queryVersion == ticket, !cancellation.cancelled else { return }
                        self.localResults = result
                        self.localQueryResolved = true
                        self.publish()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.queryVersion == ticket, !cancellation.cancelled else { return }
                        self.localQueryResolved = true
                        if !self.spotlightResults.isEmpty { self.publish() }
                        else {
                            self.emit([], error.localizedDescription)
                            self.isSearching = false
                        }
                    }
                }
            }
        }
        pendingQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func emit(_ rows: [SpotlightFile], _ status: String) {
        guard lastPublished != rows || lastPublishedStatus != status || lastPublishedQuery != currentQuery else { return }
        lastPublished = rows; lastPublishedStatus = status; lastPublishedQuery = currentQuery; updated?(rows, status)
    }
    private func cancelMerge() {
        pendingMerge?.cancel()
        pendingMerge = nil
        mergeVersion += 1
    }

    private func publish() {
        guard isRunning, options.enabled, !queryIsBlank else { return }
        cancelMerge()
        let ticket = mergeVersion
        let query = currentQuery
        let config = authorizedOptions
        let exclusions = config.excludedPaths + automaticExclusions.map(\.path)
        let local = localResults
        let removed = recentlyRemoved
        let system = config.useIgnoreFiles ? [] : spotlightResults
        let restored = restored
        let task = DispatchWorkItem { [weak self] in
            var allowed: [RankedFile] = []
            var locations = FileSearchLocation(options: config, automaticExclusions: exclusions, restored: restored)
            if !system.isEmpty {
                allowed = system.filter { hit in
                    config.roots.contains { FileSearchLocation.contains(hit.file.id, in: $0) }
                        && (try? locations.item(at: hit.file.url)) != nil
                }
            }
            var seen = Set<String>()
            let ordered = (local + allowed).filter { hit in
                // Saved rows can predate changed ignore rules while indexing is paused.
                // Check ancestors without requiring the file to be online, preserving
                // retained records for disconnected volumes.
                locations.includesSavedResult(at: hit.file.id, directory: hit.file.isDirectory)
                    && !removed.contains { FileSearchLocation.contains(hit.file.id, in: $0) } && seen.insert(hit.file.id).inserted
            }
                .sorted { $0.precedes($1) }
            let best = ordered.prefix(200).map { $0.file.readingResourceMetadata() }
            let truncated = ordered.count >= 200
            DispatchQueue.main.async {
                guard let self, self.mergeVersion == ticket, self.currentQuery == query else { return }
                var rows = best
                if self.lastPublishedQuery == query {
                    let byID = Dictionary(uniqueKeysWithValues: best.map { ($0.id, $0) })
                    let previousIDs = Set(self.lastPublished.map(\.id))
                    rows = self.lastPublished.compactMap { byID[$0.id] } + best.filter { !previousIDs.contains($0.id) }
                }
                let status: String
                if !rows.isEmpty {
                    let notice = self.indexPaused ? "本地索引已暂停" : self.indexFailure
                    status = "\(rows.count)项\(truncated ? " · 请增加关键词" : "")"
                        + (notice.map { " · " + $0 } ?? "")
                } else if self.indexPaused {
                    status = "本地索引已暂停。恢复索引后可搜索新增或更新的文件。"
                } else if let failure = self.indexFailure {
                    status = failure
                } else if self.indexing {
                    status = "正在建立索引，完成后自动更新结果。"
                } else {
                    status = "请检查搜索范围、忽略规则或文件夹授权。"
                }
                self.emit(rows, status)
                if self.isSearching && self.localQueryResolved { self.isSearching = false }
            }
        }
        pendingMerge = task
        mergeQueue.async(execute: task)
    }
    private func refreshStats(runtime: FileScanCancellation) {
        do {
            if let stats = try readDB?.stats() {
                DispatchQueue.main.async {
                    guard !runtime.cancelled else { return }
                    var current = stats
                    current.invalid = self.stats.invalid
                    current.seconds = self.stats.seconds
                    self.stats = current
                }
            }
        } catch {
            DispatchQueue.main.async { if !runtime.cancelled { self.indexStatus = error.localizedDescription } }
        }
    }
    func startIndex(force: Bool = false) {
        dirtyPaths.removeAll()
        needsFullScan = false
        scanIndex(force: force)
    }

    private func scanIndex(paths: Set<String>? = nil, force: Bool = false) {
        guard isRunning, options.enabled else { return }
        guard !indexPaused else {
            indexStatus = "本地索引已暂停，仍可搜索已有条目。"
            return
        }
        didStart = true; cancellation.cancel(); let token = FileScanCancellation(); cancellation = token
        let config = authorizedOptions; let exclusions = config.excludedPaths + automaticExclusions.map(\.path); let restored = restored
        indexFailure = nil
        indexing = true; indexStatus = paths == nil ? "正在建立文件索引…" : "正在更新文件索引…"; inaccessible = []; startWatch()
        writer.async { [weak self] in
            guard let self, let db = self.writeDB, !token.cancelled else { return }
            let paths = paths.map(Self.coalescedIndexPaths)
            defer { db.releaseCachedPages() }
            let start = Date(); var lastProgress = Date.distantPast; var invalid = 0; var denied: [String] = []; var auto: [AutomaticFileExclusion] = []; var processed = 0
            let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
            let epoch = (config.contentSearch ? "c:" : "n:") + UUID().uuidString
            let ignoresFile = FileSearchRules.pathFilter(config.ignorePatterns)
            let ignoresDirectory = FileSearchRules.pathFilter(config.ignorePatterns, directory: true)
            do {
                if paths == nil {
                    if !config.contentSearch { try db.clearBodies() }
                    if !config.keepRemovedVolumes { try db.removeUnavailableVolumes() }
                }
                let targets = config.roots.flatMap { root -> [(String, String?)] in
                    guard let paths else { return [(root, nil)] }
                    return paths.compactMap { path in
                        if path == root { return (root, nil) }
                        return path.hasPrefix(root == "/" ? "/" : root + "/") ? (root, path) : nil
                    }
                }
                let keys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey,.volumeURLKey,.volumeIsLocalKey,.volumeIsRemovableKey,.volumeIsInternalKey]
                func excluded(_ url: URL, directory: Bool, rules: [FileSearchRules.IgnoreRule]) -> Bool {
                    let path = url.path
                    let ignoresPath = directory ? ignoresDirectory : ignoresFile
                    return (!config.includeHidden && url.lastPathComponent.hasPrefix("."))
                        || exclusions.contains { path == $0 || path.hasPrefix($0 + "/") }
                        || ignoresPath(path, url.lastPathComponent)
                        || FileSearchRules.ignored(url, directory: directory, patterns: [], rules: rules)
                }
                for (root, subtree) in targets {
                    if token.cancelled { return }
                    let rootURL = URL(fileURLWithPath: root)
                    guard FileManager.default.fileExists(atPath: root) else { if !config.keepRemovedVolumes { try db.removeScope(root) }; continue }
                    let entry = subtree.map { URL(fileURLWithPath: $0) }
                    let firstDirectory = entry?.deletingLastPathComponent() ?? rootURL
                    var inheritedRules: [FileSearchRules.IgnoreRule] = []
                    if let subtree {
                        var ancestors: [URL] = []
                        var ancestor = firstDirectory
                        while ancestor.path != root {
                            ancestors.append(ancestor)
                            ancestor.deleteLastPathComponent()
                        }
                        var blocked = false
                        var inaccessibleAncestor = false
                        for parent in [rootURL] + ancestors.reversed() {
                            if parent.path != root {
                                if excluded(parent, directory: true, rules: inheritedRules)
                                    || (parent.path == homeLibrary && root != homeLibrary) || parent.pathExtension == "app"
                                    || (FileIndexExclusionPolicy.isKnownCache(parent)
                                        && !restored.contains(parent.path)) {
                                    blocked = true; break
                                }
                                do {
                                    let metadata = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                                    if metadata.isDirectory != true || metadata.isSymbolicLink == true { blocked = true; break }
                                } catch {
                                    if Self.isMissing(error) { blocked = true }
                                    else { inaccessibleAncestor = true }
                                    break
                                }
                            }
                            if config.useIgnoreFiles && parent.path != firstDirectory.path {
                                inheritedRules += FileSearchRules.readIgnoreRules(in: parent)
                            }
                        }
                        if inaccessibleAncestor { continue }
                        if blocked { try db.removeUnseen(root: root, subtree: subtree, epoch: epoch); continue }
                    }
                    // Keep only pending paths and inherited rules. Enumerated URLs can
                    // carry prefetched resource values for each file and directory.
                    var queue: [(path: String, rules: [FileSearchRules.IgnoreRule])?] = [(firstDirectory.path, inheritedRules)]
                    var position = 0
                    var complete = true
                    var explicitEntry = entry
                    while position < queue.count && !token.cancelled {
                        let (path, inherited) = queue[position]!
                        queue[position] = nil
                        position += 1
                        if position >= 1024 && position >= queue.count - position {
                            queue.removeFirst(position)
                            position = 0
                        }
                        let pendingEntry = explicitEntry
                        explicitEntry = nil
                        try autoreleasepool {
                            let directory = URL(fileURLWithPath: path, isDirectory: true)
                            var rules = inherited; if config.useIgnoreFiles { rules += FileSearchRules.readIgnoreRules(in: directory) }
                            let children: [URL]
                            do {
                                if let pendingEntry {
                                    children = [pendingEntry]
                                } else {
                                    let priority = ["Downloads": 0, "Desktop": 1, "Documents": 2]
                                    children = try FileManager.default.contentsOfDirectory(
                                        at: directory, includingPropertiesForKeys: Array(keys),
                                        options: config.includeHidden ? [] : [.skipsHiddenFiles]
                                    ).sorted { (priority[$0.lastPathComponent] ?? 3) < (priority[$1.lastPathComponent] ?? 3) }
                                }
                            } catch {
                                invalid += 1; complete = false
                                if denied.count < 24 { denied.append(directory.path) }
                                return
                            }
                            if config.enforceDiskSpace {
                                let free = self.availableCapacity(db.url.deletingLastPathComponent())
                                // Reserve room for SQLite/WAL and the next directory batch.
                                let estimate = Int64(children.count * (config.contentSearch ? 102_400 : 1024)) + 128 * 1024 * 1024
                                guard free > estimate else { throw FileIndexError.diskSpace }
                            }
                            try db.transaction {
                                // Bound temporary metadata and content allocations even in wide directories.
                                let batchSize = 64
                                for offset in stride(from: 0, to: children.count, by: batchSize) {
                                    try autoreleasepool {
                                        for url in children[offset..<min(offset + batchSize, children.count)] {
                                            if token.cancelled { return }
                                            let value: URLResourceValues
                                            do { value = try url.resourceValues(forKeys: keys) }
                                            catch {
                                                if entry == url, Self.isMissing(error) { continue }
                                                invalid += 1; complete = false; continue
                                            }
                                            let isDir = value.isDirectory == true; let symlink = value.isSymbolicLink == true; let path = url.path
                                            guard !excluded(url, directory: isDir, rules: rules) else { continue }
                                            if !config.externalVolumes && (value.volumeIsLocal == false || value.volumeIsRemovable == true || value.volumeIsInternal == false) { continue }
                                            if isDir && path == homeLibrary && root != homeLibrary { continue } // iCloud is a separate explicit scope.
                                            if isDir && FileIndexExclusionPolicy.isKnownCache(url) && !restored.contains(path) {
                                                auto.append(.init(path: path, reason: "构建输出或依赖缓存", events: 0)); continue
                                            }
                                            let record = FileIndexRecord(path:path,name:url.lastPathComponent,volume:value.volume?.path ?? "/",modified:value.contentModificationDate?.timeIntervalSince1970 ?? 0,directory:isDir,symlink:symlink,external:value.volumeIsLocal == false || value.volumeIsRemovable == true || value.volumeIsInternal == false)
                                            if try force || !db.touchUnchanged(record, root: root, epoch: epoch, contentSearch: config.contentSearch) {
                                                let body = config.contentSearch && !isDir && !symlink ? FileSearchIndex.content(at: url) : ""
                                                try db.put(record, body: body, root: root, epoch: epoch)
                                            }
                                            processed += 1
                                            if isDir && !symlink && url.pathExtension != "app" { queue.append((path, rules)) }
                                        }
                                    }
                                    if token.cancelled { return }
                                }
                            }
                        }
                        if Date().timeIntervalSince(lastProgress) >= 1 {
                            lastProgress = Date(); let count = processed
                            DispatchQueue.main.async { if self.cancellation === token {
                                self.indexStatus = "正在索引：\(count)项"
                                if self.lastPublished.isEmpty && !self.queryIsBlank && FileSearchLocation.typedURL(self.currentQuery) == nil
                                    && !self.isSearching { self.refreshQuery() }
                            } }
                        }
                    }
                    if token.cancelled { return }
                    if complete {
                        if let subtree { try db.removeUnseen(root: root, subtree: subtree, epoch: epoch) }
                        else { try db.removeUnseen(root: root, epoch: epoch) }
                    }
                }
                var stats = try db.stats(); stats.invalid = invalid; stats.seconds = Date().timeIntervalSince(start)
                DispatchQueue.main.async {
                    guard self.cancellation === token else { return }
                    self.indexing = false; self.stats = stats; self.preferences.set(try? JSONEncoder().encode(stats), forKey:"fileSearchLastStats"); self.inaccessible = denied
                    for value in auto where !self.automaticExclusions.contains(where: { $0.path == value.path }) { self.automaticExclusions.append(value) }; self.saveAutomatic()
                    self.indexStatus = denied.isEmpty ? "索引已更新" : "部分目录无法访问，请重新授权搜索范围。"
                    if self.hasQuery, !self.queryIsBlank {
                        if FileSearchLocation.typedURL(self.currentQuery) == nil { self.refreshQuery() }
                        else { self.reloadSearch() }
                    }
                    self.scheduleRefresh()
                }
            } catch { DispatchQueue.main.async {
                guard self.cancellation === token else { return }
                self.reportIndexFailure(error)
                self.scheduleRefresh()
            } }
        }
    }
    private func reportIndexFailure(_ error: Error) {
        indexing = false
        let message = error.localizedDescription
        indexFailure = message
        indexStatus = message
        if localQueryResolved { publish() }
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    private static func coalescedIndexPaths(_ paths: Set<String>) -> [String] {
        // Sorting by the directory prefix keeps every subtree next to its parent.
        let sorted = paths.map { ($0, $0 == "/" ? "/" : $0 + "/") }.sorted { $0.1 < $1.1 }
        var targets: [String] = []
        var parent = ""
        for (path, prefix) in sorted where targets.isEmpty || !prefix.hasPrefix(parent) {
            targets.append(path)
            parent = prefix
        }
        return targets
    }

    private struct IndexEventBatch {
        let paths: CFArray
        let flags: [FSEventStreamEventFlags]
        let date: Date
    }

    private struct IndexEventConfiguration: Equatable {
        let options: FileSearchOptions
        let restored: Set<String>
        let exclusions: [AutomaticFileExclusion]
    }

    private struct IndexEventResult {
        var exclusions: [AutomaticFileExclusion]
        var churn: [String: (Date, Int)]
        var paths = Set<String>()
        var requiresFullScan = false
    }

    private var eventConfiguration: IndexEventConfiguration {
        .init(options: authorizedOptions, restored: restored, exclusions: automaticExclusions)
    }

    private func stopWatch() {
        watchLifetime?.cancel()
        watchLifetime = nil
        pendingEvents.removeAll()
        pendingEventCount = 0
        recoverEvents = false
        processingEvents = false
        pendingRefresh?.cancel()
        pendingRefresh = nil
        dirtyPaths.removeAll()
        needsFullScan = false
        if let watch {
            FSEventStreamStop(watch)
            FSEventStreamInvalidate(watch)
            FSEventStreamRelease(watch)
        }
        watch = nil
    }

    private func startWatch() {
        let roots = authorizedRoots
        guard watch == nil, watchEnabled, options.enabled, !indexPaused, !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        watch = FSEventStreamCreate(nil, { _, context, count, rawPaths, flags, _ in
            guard let context else { return }
            let owner = Unmanaged<FileSearchController>.fromOpaque(context).takeUnretainedValue()
            owner.receiveIndexEvents(count: count, rawPaths: rawPaths, flags: flags)
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let watch {
            FSEventStreamSetDispatchQueue(watch, .main)
            if FSEventStreamStart(watch) {
                watchLifetime = FileScanCancellation()
            } else {
                FSEventStreamInvalidate(watch)
                FSEventStreamRelease(watch)
                self.watch = nil
            }
        }
    }

    private func receiveIndexEvents(count: Int, rawPaths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>) {
        guard !recoverEvents, count > 0 else { return }
        // The stream owns the flag buffer. Copy it and retain the immutable
        // path array so path bridging and classification can run off-main.
        if count <= Self.maxQueuedEvents - pendingEventCount {
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue()
            pendingEvents.append(.init(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)), date: Date()))
            pendingEventCount += count
        } else {
            pendingEvents.removeAll()
            pendingEventCount = 0
            recoverEvents = true
        }
        processPendingEvents()
    }

    private var churn: [String: (Date, Int)] = [:]

    private func processPendingEvents() {
        guard let lifetime = watchLifetime, !processingEvents else { return }
        if recoverEvents {
            recoverEvents = false
            needsFullScan = true
            dirtyPaths.removeAll()
            scheduleRefresh()
        }
        guard !pendingEvents.isEmpty else { return }
        let batches = pendingEvents
        let count = pendingEventCount
        let config = eventConfiguration
        let churn = churn
        pendingEvents = []
        pendingEventCount = 0
        processingEvents = true
        eventQueue.async { [weak self] in
            guard let result = Self.classifyEvents(batches, configuration: config, churn: churn, lifetime: lifetime) else { return }
            DispatchQueue.main.async {
                guard let self, self.watchLifetime === lifetime else { return }
                self.processingEvents = false
                if config == self.eventConfiguration {
                    self.churn = result.churn
                    if self.automaticExclusions != result.exclusions {
                        self.automaticExclusions = result.exclusions
                        self.saveAutomatic()
                    }
                    if result.requiresFullScan {
                        self.needsFullScan = true
                    }
                    if !self.needsFullScan {
                        self.dirtyPaths.formUnion(result.paths)
                        self.needsFullScan = self.dirtyPaths.count > Self.maxQueuedEvents
                    }
                    if self.needsFullScan { self.dirtyPaths.removeAll() }
                    self.scheduleRefresh()
                } else if !self.recoverEvents {
                    // An exclusion, grant, or restore changed while filtering.
                    // Replay the batch in order using the new rules.
                    if count <= Self.maxQueuedEvents - self.pendingEventCount {
                        self.pendingEvents = batches + self.pendingEvents
                        self.pendingEventCount += count
                    } else {
                        self.pendingEvents.removeAll()
                        self.pendingEventCount = 0
                        self.recoverEvents = true
                    }
                }
                self.processPendingEvents()
            }
        }
    }

    private static func classifyEvents(_ batches: [IndexEventBatch], configuration: IndexEventConfiguration,
                                       churn: [String: (Date, Int)], lifetime: FileScanCancellation) -> IndexEventResult? {
        let options = configuration.options
        var result = IndexEventResult(exclusions: configuration.exclusions, churn: churn)
        let ignores = FileSearchRules.pathFilter(options.ignorePatterns)
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let recovery = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        for batch in batches {
            guard !lifetime.cancelled else { return nil }
            let paths = batch.paths as! [String]
            let requiresFullScan = batch.flags.contains { $0 & recovery != 0 }
            result.requiresFullScan = result.requiresFullScan || requiresFullScan
            result.churn = result.churn.filter { batch.date.timeIntervalSince($0.value.0) < 60 }
            var indexLocations: FileSearchLocation?
            var targets = Set<String>()
            var newExclusions = Set<String>()
            for (path, flags) in zip(paths, batch.flags) {
                guard !lifetime.cancelled else { return nil }
                if let i = result.exclusions.firstIndex(where: { FileSearchLocation.contains(path, in: $0.path) }) {
                    result.exclusions[i].events += 1
                    continue
                }
                targets.insert(options.useIgnoreFiles ? indexEventTarget(path) : path)
                guard !requiresFullScan, let directory = FileIndexExclusionPolicy.changeCandidate(
                    for: path, scopes: options.roots, restored: configuration.restored, includeHidden: options.includeHidden
                ) else { continue }
                if indexLocations == nil {
                    indexLocations = FileSearchLocation(options: options, automaticExclusions: [], restored: configuration.restored)
                }
                let isDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
                guard indexLocations?.includesIndexChange(at: path, directory: isDirectory) == true else { continue }
                let previous = result.churn[directory] ?? (batch.date, 0)
                if previous.1 + 1 >= 120 {
                    result.exclusions.append(.init(path: directory, reason: "一分钟内持续变化的构建或缓存目录", events: 0))
                    newExclusions.insert(directory)
                    result.churn.removeValue(forKey: directory)
                } else {
                    result.churn[directory] = (previous.0, previous.1 + 1)
                }
            }
            guard !result.requiresFullScan else { continue }
            for path in targets {
                guard !lifetime.cancelled else { return nil }
                guard options.roots.contains(where: { FileSearchLocation.contains(path, in: $0) }) else { continue }
                if !options.includeHidden && path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                if FileSearchLocation.contains(path, in: library),
                   !options.roots.contains(where: { FileSearchLocation.contains($0, in: library) && FileSearchLocation.contains(path, in: $0) }) { continue }
                if result.exclusions.contains(where: { FileSearchLocation.contains(path, in: $0.path) })
                    || options.excludedPaths.contains(where: { FileSearchLocation.contains(path, in: $0) })
                    || ignores(path, URL(fileURLWithPath: path).lastPathComponent) { continue }
                result.paths.insert(path)
            }
            // Purge newly excluded subtrees even though their own events were filtered above.
            result.paths.formUnion(newExclusions)
        }
        return result
    }

    private static func indexEventTarget(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if [".gitignore", ".ignore", ".rayignore"].contains(url.lastPathComponent) {
            return url.deletingLastPathComponent().path
        }
        if path.hasSuffix("/.git/info/exclude") { return String(path.dropLast("/.git/info/exclude".count)) }
        return path
    }

    private func scheduleRefresh() {
        guard !indexPaused, !indexing, pendingRefresh == nil, needsFullScan || !dirtyPaths.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            guard !self.indexing else { return }
            if self.needsFullScan { self.startIndex(); return }
            let paths = self.dirtyPaths
            self.dirtyPaths.removeAll()
            if !paths.isEmpty { self.scanIndex(paths: paths) }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
