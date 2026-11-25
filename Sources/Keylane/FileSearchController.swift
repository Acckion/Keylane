import OSLog
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
// Pending event paths cross queues; reconciliation state belongs only to writer.
private final class FileScanSession: @unchecked Sendable {
    let token: FileScanCancellation
    let epoch: String
    let options: FileSearchOptions
    private let lock = NSLock()
    private var pending = Set<String>()
    private var recursive = Set<String>()
    var updated = Set<String>()
    var removed = Set<String>()
    init(token: FileScanCancellation, options: FileSearchOptions) {
        self.token = token; self.options = options
        epoch = (options.contentSearch ? "c:" : "n:") + UUID().uuidString
    }
    func enqueue(_ paths: Set<String>, recursive descendants: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        guard pending.count + paths.count <= 8192 else { return } // full dirty set still replays after baseline
        pending.formUnion(paths); recursive.formUnion(descendants.intersection(paths))
    }
    func takePaths() -> (paths: Set<String>, recursive: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        let result = (pending, recursive)
        pending.removeAll(keepingCapacity: false); recursive.removeAll(keepingCapacity: false)
        return result
    }
    func isRemoved(_ path: String) -> Bool {
        guard !removed.isEmpty else { return false }
        if removed.contains(path) { return true }
        var end = path.endIndex
        while let slash = path[..<end].lastIndex(of: "/"), slash != path.startIndex {
            if removed.contains(String(path[..<slash])) { return true }
            end = slash
        }
        return removed.contains("/")
    }
    func supersedes(_ path: String) -> Bool { updated.contains(path) || isRemoved(path) }
}

final class FileSearchController: ObservableObject {
    private var aiIndexRevision = UUID()
    var aiAccessRevision: UUID { aiIndexRevision }
    @Published var options: FileSearchOptions { willSet { if newValue != options { aiIndexRevision = UUID() } } didSet { if options != oldValue { configure(old: oldValue) } } }
    @Published private(set) var automaticExclusions: [AutomaticFileExclusion] = [] { willSet { if newValue != automaticExclusions { aiIndexRevision = UUID() } } didSet { if Set(oldValue.map(\.path)) != Set(automaticExclusions.map(\.path)) { cancelContent() } } }
    @Published private(set) var stats = FileIndexStats()
    @Published private(set) var indexStatus = "尚未建立本地补充索引"
    @Published private(set) var inaccessible: [String] = []
    @Published private(set) var indexing = false
    @Published private(set) var contentIndexing = false
    @Published private(set) var indexPaused: Bool
    @Published private(set) var directorySort: FileDirectorySort
    @Published private(set) var browsingDirectory: URL?
    @Published private(set) var isSearching = false
    var updated: (([SpotlightFile], String) -> Void)?
    private let preferences: UserDefaults
    private let availableCapacity: (URL) -> Int64
    private let watchEnabled: Bool
    private let writer = DispatchQueue(label: "org.keylane.files.index", qos: .utility)
    private let scanQueue = DispatchQueue(label: "org.keylane.files.metadata", qos: .utility)
    private let patchQueue = DispatchQueue(label: "org.keylane.files.live-metadata", qos: .utility)
    private lazy var scanWork = LatestWorkQueue(queue: scanQueue)
    private lazy var patchWork = LatestWorkQueue(queue: patchQueue)
    private var scanSession: FileScanSession?
    private let contentQueue = DispatchQueue(label: "org.keylane.files.content", qos: .utility)
    private var contentLifetime = FileScanCancellation()
    private var contentBusy = false
    private var contentFailure: String?
    private var contentRetryAfter = Date.distantPast
    private var pendingContentDrain: DispatchWorkItem?
    private var pendingContentRefresh: DispatchWorkItem?
    private let contentExtractor: ((FileSearchIndex.ContentJob, @escaping () -> Bool) throws -> String)?
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
    private var restoringIndex = false
    private var checkpointConfiguration: String?
    private var indexFailure: String?
    private var grants: [String: Data]
    private var selectedScopePaths: Set<String>
    private var activeURLs: [URL] = []
    private var spotlight = SpotlightSearch()
    private var spotlightResults: [RankedFile] = []
    private var localResults: [RankedFile] = []
    private let mergeQueue = DispatchQueue(label: "org.keylane.files.merge", qos: .userInitiated)
    private lazy var queryWork = LatestWorkQueue(queue: reader)
    private lazy var mergeWork = LatestWorkQueue(queue: mergeQueue)
    private var mergeVersion = 0
    private var watch: FSEventStreamRef?
    private let eventQueue = DispatchQueue(label: "org.keylane.files.events", qos: .utility)
    private var watchLifetime: FileScanCancellation?
    private var acceptedEventID: FSEventStreamEventId = 0
    private var checkpointReady = false
    private var pendingRepairPaths = Set<String>()
    private var replayingEvents = false
    private var pendingEvents: [IndexEventBatch] = []
    private var pendingEventCount = 0
    private var processingEvents = false
    private var recoverEvents = false
    private static let maxQueuedEvents = 8192
    private var pendingRefresh: DispatchWorkItem?
    private var restored: Set<String> = [] { didSet { if oldValue != restored { aiIndexRevision = UUID(); cancelContent() } } }
    private var dirtyPaths = Set<String>()
    private var dirtyRecursivePaths = Set<String>()
    private var needsFullScan = false
    static var defaults: FileSearchOptions {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var options = FileSearchOptions(roots: [home, "/Applications", home + "/Library/Mobile Documents/com~apple~CloudDocs"])
        options.enabled = false
        return options
    }
    init(directory: URL? = nil, preferences: UserDefaults = .standard, defaultOptions: FileSearchOptions? = nil, watchChanges: Bool = true,
         availableCapacity: ((URL) -> Int64)? = nil, startImmediately: Bool = true,
         recentSpotlightSearch: (([String], @escaping ([RecentlyUsedFile]) -> Void) -> Void)? = nil,
         contentExtractor: ((FileSearchIndex.ContentJob, @escaping () -> Bool) throws -> String)? = nil) {
        self.preferences = preferences; self.watchEnabled = watchChanges
        self.contentExtractor = contentExtractor
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
        restoringIndex = true
        resolveGrants()
        writer.async { [weak self] in
            guard let self, !token.cancelled else { return }
            do {
                self.writeDB = try FileSearchIndex(url: self.databaseURL)
                let recovery = try self.writeDB?.recoveryPoint()
                try self.reader.sync {
                    guard !token.cancelled else { return }
                    self.readDB = try FileSearchIndex(url: self.databaseURL)
                    self.refreshStats(runtime: token)
                }
                DispatchQueue.main.async {
                    guard !token.cancelled else { return }
                    self.restoringIndex = false
                    self.restoreIndex(recovery)
                    self.drainContent()
                    if !self.queryIsBlank { self.reloadSearch() }
                }
            } catch {
                DispatchQueue.main.async {
                    if !token.cancelled { self.restoringIndex = false; self.reportIndexFailure(error) }
                }
            }
        }
    }

    private struct RecoveryConfiguration: Codable {
        let version: Int
        let options: FileSearchOptions
        let restored: [String]
        let exclusions: [String]
        let rootIdentities: [String]
    }

    private static func recoveryConfiguration(options: FileSearchOptions, restored: Set<String>, exclusions: [String]) throws -> String {
        let identities = options.roots.map { path -> String in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return path + "\0unavailable" }
            return "\(path)\0\(attributes[.systemNumber] ?? "")\0\(attributes[.systemFileNumber] ?? "")"
        }
        let value = RecoveryConfiguration(version: 1, options: options, restored: restored.sorted(),
                                          exclusions: exclusions.sorted(), rootIdentities: identities)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func restoreIndex(_ recovery: FileSearchIndex.RecoveryPoint?) {
        guard !didStart, isRunning, options.enabled, !indexPaused, watchEnabled, !authorizedRoots.isEmpty else { return }
        let config = eventConfiguration
        let token = cancellation
        restoringIndex = true
        eventQueue.async { [weak self] in
            let fingerprint = try? Self.recoveryConfiguration(options: config.options, restored: config.restored,
                                                             exclusions: config.exclusions.map(\.path))
            DispatchQueue.main.async {
                guard let self, self.cancellation === token, !self.didStart, self.isRunning,
                      self.options.enabled, !self.indexPaused, config == self.eventConfiguration else { return }
                self.restoringIndex = false
                if let recovery, recovery.eventID > 0, recovery.eventID <= FSEventsGetCurrentEventId(),
                   fingerprint == recovery.configuration {
                    self.acceptedEventID = recovery.eventID
                    self.startWatch(since: recovery.eventID)
                    if self.watchLifetime != nil {
                        self.checkpointReady = true
                        self.checkpointConfiguration = fingerprint
                        self.didStart = true
                        self.pendingRepairPaths = recovery.retryPaths
                        self.dirtyPaths.formUnion(recovery.retryPaths)
                        self.dirtyRecursivePaths.formUnion(recovery.retryPaths)
                        self.scheduleRefresh()
                        self.indexStatus = "正在恢复文件变化…"
                        self.drainContent()
                    } else { self.startIndex() }
                } else {
                    self.startIndex()
                }
            }
        }
    }

    func stopRuntime() {
        guard let runtime else { return }
        cancelContent()
        runtime.cancel()
        self.runtime = nil
        recentlyRemoved.removeAll()
        cancellation.cancel()
        scanWork.cancel(); patchWork.cancel(); scanSession = nil
        cancellation = FileScanCancellation()
        cancel()
        stopWatch()
        didStart = false
        restoringIndex = false
        checkpointConfiguration = nil
        checkpointReady = false
        acceptedEventID = 0
        pendingRepairPaths.removeAll()
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

    deinit { contentLifetime.cancel(); pendingContentDrain?.cancel(); pendingContentRefresh?.cancel(); stopWatch(); cancelMerge(); cancellation.cancel(); activeURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
    private func configure(old: FileSearchOptions) {
        preferences.set(try? JSONEncoder().encode(options), forKey: "fileSearchOptions")
        var previous = old; previous.searchFromLauncher = options.searchFromLauncher
        guard previous != options, let runtime else { return }
        let changedExclusions = Set(previous.excludedPaths).symmetricDifference(options.excludedPaths)
        previous.excludedPaths = options.excludedPaths
        if previous == options {
            cancelContent()
            reloadSearch()
            if !indexPaused {
                dirtyPaths.formUnion(changedExclusions)
                dirtyRecursivePaths.formUnion(changedExclusions)
                scheduleRefresh()
            }
            return
        }
        cancelContent(); stopSearchJobs(); cancellation.cancel(); stopWatch()
        scanWork.cancel(); patchWork.cancel(); scanSession = nil
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
        else { indexing = false; isSearching = false; indexStatus = "文件搜索已关闭"; updated?([], indexStatus) }
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
            cancelContent()
            cancellation.cancel()
            scanWork.cancel(); patchWork.cancel(); scanSession = nil
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
            // A pre-mutation merge must not restore a row hidden immediately below.
            cancelMerge()
            recentlyRemoved.insert(url.path)
            let visible = lastPublished.filter { !FileSearchLocation.contains($0.id, in: url.path) }
            emit(visible, visible.isEmpty ? "没有匹配项。" : lastPublishedStatus)
            recentPaths.removeAll { FileSearchLocation.contains($0, in: url.path) }
            saveRecentHistory()
            let roots = authorizedRoots
            let token = runtime
            let activeScan = scanSession
            writer.async { [weak self] in
                guard let self, token?.cancelled == false else { return }
                do {
                    let epoch = UUID().uuidString
                    for root in roots { try self.writeDB?.removeUnseen(root: root, subtree: url.path, epoch: epoch) }
                    if let activeScan, !activeScan.token.cancelled {
                        activeScan.updated.remove(url.path); activeScan.removed.insert(url.path)
                    }
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
            dirtyRecursivePaths.insert(url.path)
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
        queryVersion += 1; queryWork.cancel(); pendingQuery?.cancel(); pendingQuery = nil; queryCancellation.cancel(); spotlight.cancel(); currentQuery = ""; localResults = []; spotlightResults = []; localQueryResolved = false; isSearching = false
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
        if !didStart && !restoringIndex { startIndex() }
        guard changed else { return }
        stopSearchJobs()
        isSearching = true
        if scopeChanged { emit([], "正在搜索…") }
        let roots = authorizedRoots
        if !options.useIgnoreFiles, !roots.isEmpty {
            spotlight.search(text, root: roots.count == 1 ? URL(fileURLWithPath: roots[0]) : nil)
        }
        refreshQuery(delay: 0.06)
    }

    private func stopSearchJobs() {
        cancelMerge()
        queryVersion += 1
        queryWork.cancel()
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
        let restoredPaths = restored
        let cancellation = FileScanCancellation()
        return try await withTaskCancellationHandler {
            let result: [SpotlightFile] = try await withCheckedThrowingContinuation { continuation in
                reader.async(execute: DispatchWorkItem { [weak self] in
                    do {
                        guard let self, let db = self.readDB, !runtime.cancelled, !cancellation.cancelled else { throw CancellationError() }
                        var locations = FileSearchLocation(options: config, automaticExclusions: exclusions, restored: restoredPaths)
                        let files = try db.search(query, options: config, excluded: exclusions + config.excludedPaths, limit: limit, within: within,
                            pathAllowed: { locations.includesSavedResult(at: $0, directory: $1) },
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
        queryWork.submit { [weak self] latest in
            guard !cancellation.cancelled, !latest.isCancelled else { return }
            var locations = FileSearchLocation(options: config, automaticExclusions: exclusions, restored: restored)
            let result = Result { () -> ([SpotlightFile], String, URL?) in
                let file = try locations.item(at: url)
                if browse && file.isDirectory {
                    let children = try locations.children(of: file.url, sortedBy: sort, isCancelled: { cancellation.cancelled || latest.isCancelled })
                    return (children, children.isEmpty ? "该文件夹没有可显示的项目。" : "\(file.name) · \(children.count) 项", file.url)
                }
                return ([file], file.url.path, nil)
            }
            DispatchQueue.main.async {
                guard let self, self.queryVersion == ticket, !cancellation.cancelled, !latest.isCancelled else { return }
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
        pendingQuery?.cancel()
        if queryCancellation.cancelled { queryCancellation = FileScanCancellation() }
        let cancellation = queryCancellation
        let ticket = queryVersion
        let text = currentQuery
        var config = authorizedOptions
        config.contentSearch = config.contentSearch && includesQueryContents
        let queryOptions = config
        let excluded = options.excludedPaths + automaticExclusions.map(\.path)
        let restoredPaths = restored
        let work = DispatchWorkItem { [weak self] in
            guard let self, !cancellation.cancelled else { return }
            self.queryWork.submit(cancelActive: false) { [weak self] latest in
                guard let self, !cancellation.cancelled, !latest.isCancelled else { return }
                #if KEYLANE_FILE_EVENT_TESTING
                self.testBeforeLocalQuery?(text)
                #endif
                guard !cancellation.cancelled, !latest.isCancelled else { return }
                do {
                    var locations = FileSearchLocation(options: queryOptions, automaticExclusions: excluded, restored: restoredPaths)
                    let result = try self.readDB?.searchRanked(text, options: queryOptions, excluded: excluded,
                        pathAllowed: { locations.includesSavedResult(at: $0, directory: $1) },
                        isCancelled: { cancellation.cancelled || latest.isCancelled }) ?? []
                    DispatchQueue.main.async {
                        guard self.queryVersion == ticket, !cancellation.cancelled, !latest.isCancelled else { return }
                        self.localResults = result
                        self.localQueryResolved = true
                        self.publish()
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.queryVersion == ticket, !cancellation.cancelled, !latest.isCancelled else { return }
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
        mergeWork.cancel()
        mergeVersion += 1
    }

    private func publish() {
        guard isRunning, options.enabled, !queryIsBlank else { return }
        let ticket = mergeVersion
        let query = currentQuery
        let config = authorizedOptions
        let exclusions = config.excludedPaths + automaticExclusions.map(\.path)
        let local = localResults
        let removed = recentlyRemoved
        let system = config.useIgnoreFiles ? [] : spotlightResults
        let restored = restored
        mergeWork.submit(cancelActive: false) { [weak self] latest in
            var locations = FileSearchLocation(options: config, automaticExclusions: exclusions, restored: restored)
            func saved(_ hit: RankedFile) -> Bool {
                !removed.contains { FileSearchLocation.contains(hit.file.id, in: $0) }
                    && locations.includesSavedResult(at: hit.file.id, directory: hit.file.isDirectory)
            }
            guard let ordered = FileSearchMerge.top(local: local, system: system, acceptsLocal: saved,
                acceptsSystem: { hit in
                    config.roots.contains { FileSearchLocation.contains(hit.file.id, in: $0) }
                        && saved(hit) && (try? locations.item(at: hit.file.url)) != nil
                }, isCancelled: { latest.isCancelled }) else { return }
            var best: [SpotlightFile] = []
            for hit in ordered {
                guard !latest.isCancelled else { return }
                best.append(hit.file.readingResourceMetadata())
            }
            let truncated = ordered.count >= 200
            DispatchQueue.main.async {
                guard let self, !latest.isCancelled, self.mergeVersion == ticket, self.currentQuery == query else { return }
                var rows = best
                if self.lastPublishedQuery == query {
                    let byID = Dictionary(uniqueKeysWithValues: best.map { ($0.id, $0) })
                    let previousIDs = Set(self.lastPublished.map(\.id))
                    rows = self.lastPublished.compactMap { byID[$0.id] } + best.filter { !previousIDs.contains($0.id) }
                }
                let status: String
                if !rows.isEmpty {
                    let notice = self.indexPaused ? "本地索引已暂停" : (self.indexFailure ?? (self.includesQueryContents ? self.contentFailure : nil))
                    status = "\(rows.count)项\(truncated ? " · 请增加关键词" : "")"
                        + (notice.map { " · " + $0 } ?? "")
                } else if self.indexPaused {
                    status = "本地索引已暂停。恢复索引后可搜索新增或更新的文件。"
                } else if let failure = self.indexFailure {
                    status = failure
                } else if self.indexing {
                    status = "正在建立索引，完成后自动更新结果。"
                } else if let failure = self.contentFailure, self.includesQueryContents {
                    status = failure
                } else if self.contentIndexing && self.includesQueryContents {
                    status = "正在后台补充正文索引，完成后自动更新结果。"
                } else {
                    status = "请检查搜索范围、忽略规则或文件夹授权。"
                }
                self.emit(rows, status)
                if self.isSearching && self.localQueryResolved { self.isSearching = false }
            }
        }
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
    private func cancelContent() {
        contentRetryAfter = .distantPast
        contentFailure = nil
        contentIndexing = false
        contentLifetime.cancel()
        contentLifetime = FileScanCancellation()
        pendingContentDrain?.cancel(); pendingContentDrain = nil
        pendingContentRefresh?.cancel(); pendingContentRefresh = nil
        // A native PDF call may still be returning. Keep its slot occupied so
        // toggling the module cannot accumulate concurrent extraction workers.
    }

    private func reportContentFailure(_ error: Error) {
        contentIndexing = false
        let message = "正文索引暂不可用：" + error.localizedDescription
        contentFailure = message
        contentRetryAfter = Date().addingTimeInterval(60)
        if !indexing { indexStatus = message }
        if localQueryResolved, includesQueryContents { publish() }
    }

    private func scheduleContentRefresh() {
        guard hasQuery, !queryIsBlank, includesQueryContents, pendingContentRefresh == nil else { return }
        let token = contentLifetime
        let work = DispatchWorkItem { [weak self] in
            guard let self, !token.cancelled else { return }
            self.pendingContentRefresh = nil
            if self.hasQuery, !self.queryIsBlank, self.includesQueryContents { self.refreshQuery() }
        }
        pendingContentRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func drainContent(after delay: Double = 0) {
        guard isRunning, options.enabled, options.contentSearch, !indexPaused,
              !restoringIndex, !contentBusy, pendingContentDrain == nil else { return }
        let token = contentLifetime
        let wait = max(delay, contentRetryAfter.timeIntervalSinceNow)
        if wait > 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !token.cancelled else { return }
                self.pendingContentDrain = nil
                self.drainContent()
            }
            pendingContentDrain = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        }
        contentBusy = true
        let config = eventConfiguration
        writer.async { [weak self] in
            guard let self else { return }
            do {
                guard !token.cancelled, let db = self.writeDB else {
                    DispatchQueue.main.async { self.contentBusy = false; self.drainContent() }; return
                }
                let jobs = try db.nextContentJobs()
                guard !jobs.isEmpty else {
                    let next = try db.nextContentRetry()
                    let blocked = try db.hasEventDeferredContent()
                    db.releaseCachedPages()
                    DispatchQueue.main.async {
                        self.contentBusy = false
                        if !token.cancelled {
                            self.contentIndexing = false
                            self.contentFailure = nil
                            if self.indexStatus == "正在补充文件正文…" { self.indexStatus = blocked ? "部分文件正文等待文件或权限变化后重试。" : (next == nil ? "索引已更新" : "部分文件正文暂不可读，将稍后重试。") }
                            if self.localQueryResolved { self.publish() }
                            if let next { self.drainContent(after: max(0.1, next.timeIntervalSinceNow)) }
                        } else { self.drainContent() }
                    }
                    return
                }
                DispatchQueue.main.async {
                    if !token.cancelled, !self.contentIndexing {
                        self.contentFailure = nil
                        self.contentIndexing = true
                        if !self.indexing, self.indexFailure == nil { self.indexStatus = "正在补充文件正文…" }
                        if self.localQueryResolved { self.publish() }
                    }
                }
                self.contentQueue.async {
                    let session = FileContentReader.Session()
                    var locations = FileSearchLocation(options: config.options, automaticExclusions: config.exclusions.map(\.path), restored: config.restored)
                    var updates: [FileSearchIndex.ContentUpdate] = []
                    for job in jobs {
                        if token.cancelled { break }
                        do {
                        let body = try autoreleasepool { () throws -> String in
                            guard !token.cancelled else { throw CancellationError() }
                            guard locations.includesSavedResult(at: job.path, directory: false) else { return "" }
                            if let extractor = self.contentExtractor { return try extractor(job, { token.cancelled }) }
                            return try session.read(job, cancelled: { token.cancelled })
                        }
                        updates.append(.init(job: job, body: body))
                        } catch {
                            let failure = FileContentReader.classify(error)
                            if failure == .cancelled && token.cancelled { break }
                            updates.append(.init(job: job, body: nil, failure: failure == .cancelled ? .transient : failure))
                        }
                    }
                    let completed = updates
                    self.writer.async {
                        var applied = false
                        var retryDelay = 0.025
                        if !token.cancelled, let db = self.writeDB {
                            do {
                                applied = try db.applyContent(completed, isCancelled: { token.cancelled })
                                db.releaseCachedPages()
                            } catch {
                                retryDelay = 60
                                DispatchQueue.main.async { if !token.cancelled { self.reportContentFailure(error) } }
                            }
                        }
                        let changed = applied
                        let delay = retryDelay
                        DispatchQueue.main.async {
                            self.contentBusy = false
                            if !token.cancelled, changed { self.scheduleContentRefresh() }
                            self.drainContent(after: delay)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.contentBusy = false
                    if !token.cancelled { self.reportContentFailure(error); self.drainContent(after: 60) }
                    else { self.drainContent() }
                }
            }
        }
    }

    func startIndex(force: Bool = false, reason: String = "request") {
        dirtyPaths.removeAll(); dirtyRecursivePaths.removeAll()
        needsFullScan = false
        scanIndex(force: force, reason: reason)
    }

    private func scanIndex(paths: Set<String>? = nil, recursivePaths: Set<String>? = nil, force: Bool = false, reason: String = "file-events") {
        guard isRunning, options.enabled else { return }
        guard !indexPaused else {
            indexStatus = "本地索引已暂停，仍可搜索已有条目。"
            return
        }
        didStart = true; cancellation.cancel(); let token = FileScanCancellation(); cancellation = token
        let config = authorizedOptions; let automatic = automaticExclusions.map(\.path)
        let exclusions = config.excludedPaths + automatic; let restored = restored
        let eventID = paths == nil ? FSEventsGetCurrentEventId() : acceptedEventID
        acceptedEventID = max(acceptedEventID, eventID)
        startWatch(since: eventID)
        let canCheckpoint = watchLifetime != nil && (paths == nil || checkpointReady)
        let previousRepairs = pendingRepairPaths
        checkpointReady = false
        restoringIndex = false
        indexFailure = nil
        indexing = true; indexStatus = paths == nil ? "正在建立文件索引…" : "正在更新文件索引…"; inaccessible = []
        let session = FileScanSession(token: token, options: config)
        scanSession = session
        scanWork.submit { [weak self] _ in
            guard let self, !token.cancelled else { return }
            func write<T>(_ body: (FileSearchIndex) throws -> T) throws -> T {
                try self.writer.sync {
                    guard !token.cancelled, let db = self.writeDB else { throw CancellationError() }
                    return try body(db)
                }
            }
            let paths = paths.map { Self.coalescedIndexPaths($0, recursive: recursivePaths) }
            var repairPaths: Set<String> = paths.map { targets in Set(previousRepairs.filter { path in
                !targets.contains { FileSearchLocation.contains(path, in: $0) }
            }) } ?? []
            // A crash or cancelled crawl must not advertise a complete index.
            // Save the new event position only after all database writes finish.
            do { try write { try $0.invalidateRecoveryPoint() } }
            catch {
                DispatchQueue.main.async { if !token.cancelled { self.reportIndexFailure(error) } }
                return
            }
            let initialFingerprint = try? Self.recoveryConfiguration(options: config, restored: restored, exclusions: automatic)
            defer { try? write { $0.releaseCachedPages() } }
            let scanStart = Date()
            let logger = Logger(subsystem: "org.keylane.launcher", category: "file-index-diagnostics")
            var scanSucceeded = false
            var processed = 0
            let scanKind = paths == nil ? "full" : "incremental"
            let targetCount = paths?.count ?? config.roots.count
            logger.info("scan_begin kind=\(scanKind, privacy: .public) reason=\(reason, privacy: .public) forced=\(force) targets=\(targetCount) recursive_targets=\(recursivePaths?.count ?? targetCount)")
            defer {
                let elapsed = Date().timeIntervalSince(scanStart)
                let d = self.writer.sync { self.writeDB?.writeDiagnostics }
                if let d {
                    logger.info("scan_end kind=\(scanKind, privacy: .public) cancelled=\(token.cancelled) succeeded=\(scanSucceeded) seconds=\(elapsed) processed=\(processed) lifetime_metadata_checks=\(d.metadataChecks) lifetime_metadata_writes=\(d.metadataWrites) lifetime_metadata_skips=\(d.metadataSkips) lifetime_seen_writes=\(d.seenWrites) lifetime_content_writes=\(d.contentWrites) lifetime_content_skips_or_stale=\(d.contentSkips) lifetime_content_deferrals=\(d.contentDeferrals) lifetime_transactions=\(d.transactions) lifetime_subtree_vm_steps=\(d.subtreeReconcileSteps)")
                }
            }
            let start = Date(); var lastProgress = Date.distantPast; var invalid = 0; var denied: [String] = []; var auto: [AutomaticFileExclusion] = []
            let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
            let epoch = session.epoch
            let ignoresFile = FileSearchRules.pathFilter(config.ignorePatterns)
            let ignoresDirectory = FileSearchRules.pathFilter(config.ignorePatterns, directory: true)
            do {
                if paths == nil {
                    if !config.contentSearch { try write { try $0.clearBodies() } }
                    if !config.keepRemovedVolumes { try write { try $0.removeUnavailableVolumes() } }
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
                    let recursiveEntry = subtree.map { recursivePaths?.contains($0) ?? true } ?? true
                    var retainedDirectoryEntry = false
                    if token.cancelled { return }
                    let rootURL = URL(fileURLWithPath: root)
                    guard FileManager.default.fileExists(atPath: root) else {
                        if !config.keepRemovedVolumes { try write { try $0.removeScope(root) } }
                        repairPaths.insert(root)
                        continue
                    }
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
                        if inaccessibleAncestor {
                            repairPaths.insert(firstDirectory.path)
                            invalid += 1
                            if denied.count < 24 { denied.append(firstDirectory.path) }
                            continue
                        }
                        if blocked { try write { try $0.removeUnseen(root: root, subtree: subtree, epoch: epoch) }; continue }
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
                            #if KEYLANE_FILE_EVENT_TESTING
                            self.testBeforeScanDirectory?(path)
                            #endif
                            guard !token.cancelled else { return }
                            let wasRemoved = try write { _ in session.isRemoved(path) }
                            guard !wasRemoved else { return }
                            let directory = URL(fileURLWithPath: path, isDirectory: true)
                            var rules = inherited; if config.useIgnoreFiles { rules += FileSearchRules.readIgnoreRules(in: directory) }
                            var readFailure: URL?
                            var children: AnyIterator<URL>
                            if let pendingEntry {
                                var next: URL? = pendingEntry
                                children = AnyIterator { defer { next = nil }; return next }
                            } else {
                                var flags: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
                                if !config.includeHidden { flags.insert(.skipsHiddenFiles) }
                                if let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                                    options: flags, errorHandler: { url, _ in readFailure = url; return false }) {
                                    let names = directory.path == FileManager.default.homeDirectoryForCurrentUser.path
                                        ? ["Downloads", "Desktop", "Documents"] : []
                                    var priority = names.makeIterator()
                                    children = AnyIterator {
                                        if let name = priority.next() { return directory.appendingPathComponent(name, isDirectory: false) }
                                        while let child = iterator.nextObject() as? URL {
                                            if !names.contains(child.lastPathComponent) { return child }
                                        }
                                        return nil
                                    }
                                } else { readFailure = directory; children = AnyIterator { nil } }
                            }
                            var staged: [FileIndexRecord] = []
                            func commitStaged() throws {
                                guard !staged.isEmpty else { return }
                                #if KEYLANE_FILE_EVENT_TESTING
                                self.testBeforeCommitMetadata?(path)
                                #endif
                                try write { db in
                                    try db.transaction {
                                        for record in staged where !session.supersedes(record.path) {
                                            guard !token.cancelled else { throw CancellationError() }
                                            try db.stageMetadata(record, root: root, epoch: epoch,
                                                                 contentSearch: config.contentSearch, force: force)
                                            processed += 1
                                        }
                                        guard !token.cancelled else { throw CancellationError() }
                                    }
                                }

                                staged.removeAll(keepingCapacity: true)
                            }
                            // Release URL/property snapshots every 64 entries. Filesystem
                            // reads never hold the database queue or a write transaction.
                            while !token.cancelled {
                                let hadBatch = try autoreleasepool { () throws -> Bool in
                                    var batch: [URL] = []
                                    for _ in 0..<64 {
                                        guard let child = children.next() else { break }
                                        batch.append(child)
                                    }
                                    guard !batch.isEmpty else { return false }
                                    if config.enforceDiskSpace {
                                        let free = self.availableCapacity(self.databaseURL.deletingLastPathComponent())
                                        let estimate = Int64(batch.count * (config.contentSearch ? 102_400 : 1024)) + 128 * 1024 * 1024
                                        guard free > estimate else { throw FileIndexError.diskSpace }
                                    }
                                    var records: [FileIndexRecord] = []
                                    for url in batch {
                                        guard !token.cancelled else { throw CancellationError() }
                                        let value: URLResourceValues
                                        do { value = try url.resourceValues(forKeys: keys) }
                                        catch {
                                            // A dangling symlink can report a missing target even
                                            // though the directory entry still exists. Retain it
                                            // for repair rather than deleting its saved record.
                                            if Self.isMissing(error), (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil { continue }
                                            repairPaths.insert(url.path)
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
                                        records.append(record)
                                        if path == subtree, isDir, !symlink { retainedDirectoryEntry = true }
                                        if recursiveEntry && isDir && !symlink && url.pathExtension != "app" { queue.append((path, rules)) }
                                    }
                                    staged.append(contentsOf: records)
                                    if staged.count >= 256 { try commitStaged() }
                                    return true
                                }
                                if !hadBatch { break }
                            }
                            try commitStaged()
                            if let failure = readFailure {
                                invalid += 1; complete = false; repairPaths.insert(failure.path)
                                if denied.count < 24 { denied.append(failure.path) }
                            }
                        }
                        if Date().timeIntervalSince(lastProgress) >= 1 {
                            lastProgress = Date(); let count = processed
                            DispatchQueue.main.async { if self.cancellation === token, !token.cancelled {
                                self.indexStatus = "正在索引：\(count)项"
                                self.pendingContentDrain?.cancel(); self.pendingContentDrain = nil
                                self.drainContent()
                                if self.lastPublished.isEmpty && !self.queryIsBlank && FileSearchLocation.typedURL(self.currentQuery) == nil
                                    && !self.isSearching { self.refreshQuery() }
                            } }
                        }
                    }
                    if token.cancelled { return }
                    if let subtree, !recursiveEntry, retainedDirectoryEntry {
                        // Metadata-only directory events must not age out descendants.
                        try write { try $0.removeUnseenEntry(root: root, path: subtree, epoch: epoch) }
                    } else {
                        try write { try $0.removeUnseen(root: root, subtree: subtree, epoch: epoch,
                                                       preserving: complete ? [] : repairPaths) }
                    }
                }
                repairPaths = Set(Self.coalescedIndexPaths(repairPaths))
                // Known caches discovered by this scan are already excluded from
                // its results. Persist the resulting rules, not the pre-scan list.
                let fingerprint = auto.isEmpty ? initialFingerprint : try? Self.recoveryConfiguration(
                    options: config, restored: restored, exclusions: Array(Set(automatic + auto.map(\.path))))
                if canCheckpoint, !token.cancelled, let fingerprint {
                    try write { try $0.saveRecoveryPoint(.init(eventID: eventID, configuration: fingerprint, retryPaths: repairPaths)) }
                }
                let completedRepairs = repairPaths
                scanSucceeded = true
                var stats = try write { try $0.stats() }; stats.invalid = invalid; stats.seconds = Date().timeIntervalSince(start)
                DispatchQueue.main.async {
                    guard self.cancellation === token, !token.cancelled else { return }
                    self.checkpointReady = canCheckpoint && fingerprint != nil
                    self.pendingRepairPaths = completedRepairs
                    self.checkpointConfiguration = self.checkpointReady ? fingerprint : nil
                    self.scanSession = nil
                    #if KEYLANE_FILE_EVENT_TESTING
                    self.testScanCompleted?(paths == nil, processed)
                    #endif
                    self.indexing = false; self.stats = stats; self.preferences.set(try? JSONEncoder().encode(stats), forKey:"fileSearchLastStats"); self.inaccessible = denied
                    for value in auto where !self.automaticExclusions.contains(where: { $0.path == value.path }) { self.automaticExclusions.append(value) }; self.saveAutomatic()
                    self.indexStatus = denied.isEmpty ? "索引已更新" : "部分目录无法访问，请重新授权搜索范围。"
                    if self.hasQuery, !self.queryIsBlank {
                        if FileSearchLocation.typedURL(self.currentQuery) == nil { self.refreshQuery() }
                        else { self.reloadSearch() }
                    }
                    self.scheduleRefresh()
                    self.saveIdleRecoveryPoint()
                    // Newly staged work must wake a queue waiting on an older
                    // file's retry deadline. Hard database failures retain their
                    // independent backoff through contentRetryAfter.
                    self.pendingContentDrain?.cancel()
                    self.pendingContentDrain = nil
                    self.drainContent()
                }
            } catch { DispatchQueue.main.async {
                guard self.cancellation === token, !token.cancelled else { return }
                self.reportIndexFailure(error)
                self.scheduleRefresh()
            } }
        }
    }
    // A slow baseline must not hold the writer or prevent ordinary file events
    // from becoming searchable. Reconcile with its epoch before baseline cleanup.
    private func patchLiveMetadata(_ paths: Set<String>, recursive: Set<String>) {
        guard !paths.isEmpty, indexing, let session = scanSession, session.options == authorizedOptions,
              !session.token.cancelled else { return }
        session.enqueue(paths, recursive: recursive)
        let config = authorizedOptions, restored = restored
        let exclusions = config.excludedPaths + automaticExclusions.map(\.path)
        patchWork.submit(cancelActive: false) { [weak self] _ in
            guard let self, !session.token.cancelled else { return }
            let request = session.takePaths()
            var pending = request.paths.sorted()
            var recursive = request.recursive
            var enqueued = Set(pending)
            var position = 0
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
                                           .volumeURLKey, .volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsInternalKey]
            var locations = FileSearchLocation(options: config, automaticExclusions: exclusions, restored: restored)
            while position < pending.count {
                let path = pending[position]; position += 1
                guard !session.token.cancelled else { return }
                guard !config.roots.contains(path),
                      let root = config.roots.filter({ FileSearchLocation.contains(path, in: $0) }).max(by: { $0.count < $1.count })
                else { continue }
                let url = URL(fileURLWithPath: path, isDirectory: false)
                // Match traversal: do not follow a user symlink directory.
                var parent = url.deletingLastPathComponent(), safe = true
                while parent.path != root {
                    guard FileSearchLocation.contains(parent.path, in: root),
                          let value = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          value.isDirectory == true, value.isSymbolicLink != true else { safe = false; break }
                    parent.deleteLastPathComponent()
                }
                guard safe else { continue }
                let record: FileIndexRecord?
                do {
                    let value = try url.resourceValues(forKeys: keys)
                    let directory = value.isDirectory == true
                    let external = value.volumeIsLocal == false || value.volumeIsRemovable == true || value.volumeIsInternal == false
                    if locations.includesIndexChange(at: path, directory: directory), config.externalVolumes || !external {
                        record = .init(path: path, name: url.lastPathComponent, volume: value.volume?.path ?? "/",
                                       modified: value.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                       directory: directory, symlink: value.isSymbolicLink == true, external: external)
                    } else { record = nil }
                } catch {
                    // Missing targets are removals. Permission/transient failures
                    // retain saved records and are retried by normal reconciliation.
                    guard Self.isMissing(error), (try? FileManager.default.attributesOfItem(atPath: path)) == nil else { continue }
                    record = nil
                }
                if config.enforceDiskSpace,
                   self.availableCapacity(self.databaseURL.deletingLastPathComponent()) <= 128 * 1024 * 1024 + 102_400 { continue }
                do {
                    try self.writer.sync {
                        guard !session.token.cancelled, let db = self.writeDB else { throw CancellationError() }
                        // Full reconciliation remains queued if the live journal fills.
                        guard session.updated.contains(path) || session.removed.contains(path)
                            || session.updated.count + session.removed.count < 8192 else { return }
                        try db.transaction {
                            if let record {
                                try db.stageMetadata(record, root: root, epoch: session.epoch, contentSearch: config.contentSearch)
                            } else {
                                for owner in config.roots { try db.removeUnseen(root: owner, subtree: path, epoch: UUID().uuidString) }
                            }
                            guard !session.token.cancelled else { throw CancellationError() }
                        }
                        if record != nil { session.updated.insert(path); session.removed.remove(path) }
                        else { session.updated.remove(path); session.removed.insert(path) }
                    }
                } catch { continue } // dirty paths still get the full reconciliation/error path
                if recursive.contains(path), let record, record.directory, !record.symlink, url.pathExtension.lowercased() != "app" {
                    var flags: FileManager.DirectoryEnumerationOptions = [.skipsSubdirectoryDescendants]
                    if !config.includeHidden { flags.insert(.skipsHiddenFiles) }
                    if let children = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: flags) {
                        while enqueued.count < 8192, let child = children.nextObject() as? URL {
                            if enqueued.insert(child.path).inserted { pending.append(child.path); recursive.insert(child.path) }
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                guard self.scanSession === session, !session.token.cancelled else { return }
                if self.hasQuery, !self.queryIsBlank, FileSearchLocation.typedURL(self.currentQuery) == nil { self.refreshQuery() }
                self.pendingContentDrain?.cancel(); self.pendingContentDrain = nil
                self.drainContent()
            }
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

    private static func coalescedIndexPaths(_ paths: Set<String>, recursive: Set<String>? = nil) -> [String] {
        // Sorting by the directory prefix keeps every subtree next to its parent.
        let sorted = paths.map { ($0, $0 == "/" ? "/" : $0 + "/") }.sorted { $0.1 < $1.1 }
        var targets: [String] = []
        var parent = ""
        for (path, prefix) in sorted where parent.isEmpty || !prefix.hasPrefix(parent) {
            targets.append(path)
            parent = recursive?.contains(path) == false ? "" : prefix
        }
        return targets
    }

    private struct IndexEventBatch {
        let paths: CFArray
        let flags: [FSEventStreamEventFlags]
        let date: Date
        let eventID: FSEventStreamEventId
        let historical: Bool
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
        var recursivePaths = Set<String>()
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
        dirtyPaths.removeAll(); dirtyRecursivePaths.removeAll()
        needsFullScan = false
        if let watch {
            FSEventStreamStop(watch)
            FSEventStreamInvalidate(watch)
            FSEventStreamRelease(watch)
        }
        watch = nil
    }

    private func startWatch(since eventID: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)) {
        let roots = authorizedRoots
        guard watch == nil, watchEnabled, options.enabled, !indexPaused, !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        watch = FSEventStreamCreate(nil, { _, context, count, rawPaths, flags, ids in
            guard let context else { return }
            let owner = Unmanaged<FileSearchController>.fromOpaque(context).takeUnretainedValue()
            owner.receiveIndexEvents(count: count, rawPaths: rawPaths, flags: flags, ids: ids)
        }, &context, roots as CFArray, eventID, 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let watch {
            FSEventStreamSetDispatchQueue(watch, .main)
            if FSEventStreamStart(watch) {
                watchLifetime = FileScanCancellation()
                replayingEvents = true
            } else {
                FSEventStreamInvalidate(watch)
                FSEventStreamRelease(watch)
                self.watch = nil
            }
        }
    }

    private func receiveIndexEvents(count: Int, rawPaths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>, ids: UnsafePointer<FSEventStreamEventId>) {
        guard !recoverEvents, count > 0 else { return }
        // The stream owns the flag buffer. Copy it and retain the immutable
        // path array so path bridging and classification can run off-main.
        if count <= Self.maxQueuedEvents - pendingEventCount {
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue()
            pendingEvents.append(.init(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)), date: Date(), eventID: ids[count - 1], historical: replayingEvents))
            if (0..<count).contains(where: { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 }) { replayingEvents = false }
            pendingEventCount += count
        } else {
            pendingEvents.removeAll()
            pendingEventCount = 0
            recoverEvents = true
        }
        processPendingEvents()
    }

    #if KEYLANE_FILE_EVENT_TESTING
    // Feed loss/wrap flags deterministically through the production event pipeline.
    var testScanCompleted: ((Bool, Int) -> Void)?
    var testBeforeLocalQuery: ((String) -> Void)?
    var testBeforeScanDirectory: ((String) -> Void)?
    var testBeforeCommitMetadata: ((String) -> Void)?
    var testEventsIdle: Bool { !processingEvents && pendingEvents.isEmpty && pendingRefresh == nil && !indexing }
    var testQueryDiagnostics: LatestWorkQueue.Diagnostics { queryWork.diagnostics }
    func testRefreshQuery() { refreshQuery() }
    func testIndexEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        precondition(paths.count == flags.count)
        pendingEvents.append(.init(paths: paths as CFArray, flags: flags, date: Date(),
                                   eventID: FSEventsGetCurrentEventId(), historical: false))
        pendingEventCount += paths.count
        processPendingEvents()
    }
    #endif

    private var churn: [String: (Date, Int)] = [:]

    private func processPendingEvents() {
        guard let lifetime = watchLifetime, !processingEvents else { return }
        if recoverEvents {
            recoverEvents = false
            needsFullScan = true
            dirtyPaths.removeAll(); dirtyRecursivePaths.removeAll()
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
                    self.acceptedEventID = max(self.acceptedEventID, batches.map(\.eventID).max() ?? 0)
                    self.churn = result.churn
                    if self.automaticExclusions != result.exclusions {
                        self.automaticExclusions = result.exclusions
                        self.saveAutomatic()
                    }
                    var paths = result.paths
                    var recursive = result.recursivePaths.intersection(paths)
                    // Permission/root metadata notifications may unlock saved repair
                    // subtrees. Retry those subtrees rather than clearing their repair
                    // state after only touching the directory's own row.
                    for repair in self.pendingRepairPaths {
                        var ancestor = repair
                        while true {
                            if result.paths.contains(ancestor) {
                                paths.insert(repair); recursive.insert(repair); break
                            }
                            if ancestor == "/" { break }
                            ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
                        }
                    }
                    for root in self.authorizedRoots where !recursive.contains(root) {
                        paths.remove(root) // Root metadata itself is not a searchable row.
                    }
                    if result.requiresFullScan {
                        self.needsFullScan = true
                    }
                    if !self.needsFullScan {
                        self.dirtyPaths.formUnion(paths)
                        self.dirtyRecursivePaths.formUnion(recursive)
                        self.needsFullScan = self.dirtyPaths.count > Self.maxQueuedEvents
                    }
                    if self.needsFullScan { self.checkpointReady = false; self.dirtyPaths.removeAll(); self.dirtyRecursivePaths.removeAll() }
                    if batches.contains(where: { $0.flags.contains { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 } }), !self.indexing { self.indexStatus = "索引已恢复" }
                    self.patchLiveMetadata(paths, recursive: recursive)
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
                self.saveIdleRecoveryPoint()
            }
        }
    }

    // Filtered events can advance the cursor only while the saved baseline is
    // complete and no accepted work is outstanding. Queue ordering keeps this
    // write before any later scan invalidation.
    private func saveIdleRecoveryPoint() {
        guard checkpointReady, !indexing, !processingEvents, pendingEvents.isEmpty,
              !recoverEvents, !needsFullScan, dirtyPaths.isEmpty,
              let lifetime = watchLifetime, let configuration = checkpointConfiguration else { return }
        let config = eventConfiguration
        let eventID = acceptedEventID
        let token = cancellation
        let repairs = pendingRepairPaths
        writer.async { [weak self] in
            guard let self, !lifetime.cancelled, !token.cancelled, let db = self.writeDB else { return }
            do {
                guard try Self.recoveryConfiguration(options: config.options, restored: config.restored,
                                                    exclusions: config.exclusions.map(\.path)) == configuration else { return }
                let value = FileSearchIndex.RecoveryPoint(eventID: eventID, configuration: configuration, retryPaths: repairs)
                if try db.recoveryPoint() != value { try db.saveRecoveryPoint(value) }
            } catch {
                DispatchQueue.main.async {
                    if !token.cancelled { self.checkpointReady = false; self.reportIndexFailure(error) }
                }
            }
        }
    }

    private static func classifyEvents(_ batches: [IndexEventBatch], configuration: IndexEventConfiguration,
                                       churn: [String: (Date, Int)], lifetime: FileScanCancellation) -> IndexEventResult? {
        let options = configuration.options
        var result = IndexEventResult(exclusions: configuration.exclusions, churn: churn)
        let ignores = FileSearchRules.pathFilter(options.ignorePatterns)
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let globalRecovery = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
        let scopedRecovery = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        for batch in batches {
            guard !lifetime.cancelled else { return nil }
            let paths = batch.paths as! [String]
            let requiresFullScan = zip(paths, batch.flags).contains { path, flags in
                if flags & globalRecovery != 0 { return true }
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0,
                   !options.roots.contains(where: { FileSearchLocation.contains(path, in: $0) }),
                   options.roots.contains(where: { FileSearchLocation.contains($0, in: path) }) { return true }
                return flags & scopedRecovery != 0 && options.roots.contains {
                    FileSearchLocation.contains(path, in: $0) || FileSearchLocation.contains($0, in: path)
                }
            }
            result.requiresFullScan = result.requiresFullScan || requiresFullScan
            result.churn = result.churn.filter { batch.date.timeIntervalSince($0.value.0) < 60 }
            var indexLocations: FileSearchLocation?
            var targets = Set<String>()
            var newExclusions = Set<String>()
            for (path, flags) in zip(paths, batch.flags) {
                if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                guard !lifetime.cancelled else { return nil }
                if let i = result.exclusions.firstIndex(where: { FileSearchLocation.contains(path, in: $0.path) }) {
                    result.exclusions[i].events += 1
                    continue
                }
                let target = options.useIgnoreFiles ? indexEventTarget(path) : path
                targets.insert(target)
                let directoryChange = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated
                    | kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemInodeMetaMod)
                if target != path || flags & directoryChange != 0 {
                    result.recursivePaths.insert(target)
                }
                // Historical changes may span days; they are not a one-minute burst.
                guard !batch.historical, !requiresFullScan, let directory = FileIndexExclusionPolicy.changeCandidate(
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
            // Keep known targets for prompt live patches even when an additional
            // conservative baseline is required to recover unknown changes.
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
            if self.needsFullScan || !self.checkpointReady { self.startIndex(reason: self.needsFullScan ? "event-recovery" : "incomplete-checkpoint"); return }
            let paths = self.dirtyPaths
            let recursive = self.dirtyRecursivePaths
            self.dirtyPaths.removeAll(); self.dirtyRecursivePaths.removeAll()
            if !paths.isEmpty { self.scanIndex(paths: paths, recursivePaths: recursive) }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
