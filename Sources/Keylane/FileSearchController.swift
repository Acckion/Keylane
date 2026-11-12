import AppKit
import Combine
import CoreServices
import KeylaneCore

private final class FileScanCancellation {
    private let lock = NSLock(); private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
struct AutomaticFileExclusion: Codable, Identifiable, Equatable {
    var id: String { path }; let path: String; let reason: String; var events: Int
}
final class FileSearchController: ObservableObject {
    @Published var options: FileSearchOptions { didSet { if options != oldValue { configure(old: oldValue) } } }
    @Published private(set) var automaticExclusions: [AutomaticFileExclusion] = []
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
    private var includesQueryContents = true
    private var standalone = true
    private var showPathItself = false
    private var hasQuery = false
    private var recentPaths: [String]
    private var recentlyRemoved = Set<String>()
    private var localQueryResolved = false
    private var didStart = false
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
    private var pendingRefresh: DispatchWorkItem?
    private var restored: Set<String> = []
    private var dirtyPaths = Set<String>()
    private var needsFullScan = false
    static var defaults: FileSearchOptions {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var options = FileSearchOptions(roots: [home, "/Applications", home + "/Library/Mobile Documents/com~apple~CloudDocs"])
        options.enabled = false
        return options
    }
    init(directory: URL? = nil, preferences: UserDefaults = .standard, defaultOptions: FileSearchOptions? = nil, watchChanges: Bool = true, availableCapacity: ((URL) -> Int64)? = nil, startImmediately: Bool = true) {
        self.preferences = preferences; self.watchEnabled = watchChanges
        indexPaused = preferences.bool(forKey: "fileIndexPaused")
        directorySort = preferences.string(forKey: "fileDirectorySort").flatMap(FileDirectorySort.init(rawValue:)) ?? .name
        recentPaths = Array((preferences.stringArray(forKey: "fileSearchRecentPaths") ?? []).prefix(60))
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
        automaticExclusions = preferences.data(forKey: "fileSearchAutomaticExclusions").flatMap { try? JSONDecoder().decode([AutomaticFileExclusion].self, from: $0) } ?? []
        if let data = preferences.data(forKey: "fileSearchLastStats"), let value = try? JSONDecoder().decode(FileIndexStats.self, from:data) { stats = value }
        spotlight.updated = { [weak self] results, _ in
            guard let self, self.isRunning else { return }
            self.spotlightResults = results
            if self.isSearching && !self.localQueryResolved && results.isEmpty { return }
            self.publish()
        }
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
                    self.reloadSearch()
                }
            } catch {
                DispatchQueue.main.async {
                    if !token.cancelled { self.indexStatus = error.localizedDescription; self.indexing = false }
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
        preferences.set(recentPaths, forKey: "fileSearchRecentPaths")
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
            preferences.set(recentPaths, forKey: "fileSearchRecentPaths")
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
        if !removed && (browsingDirectory != nil || currentQuery.isEmpty) { reloadSearch() }
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
    func restore(_ path: String) { restored.insert(path); automaticExclusions.removeAll { $0.path == path }; saveAutomatic(); startIndex() }
    private func saveAutomatic() { preferences.set(try? JSONEncoder().encode(automaticExclusions), forKey: "fileSearchAutomaticExclusions") }
    func reset() {
        grants.removeAll()
        selectedScopePaths.removeAll()
        preferences.removeObject(forKey: "fileSearchGrants")
        preferences.removeObject(forKey: "fileSearchSelectedScopes")
        resolveGrants()
        automaticExclusions = []
        saveAutomatic()
        recentPaths = []
        preferences.removeObject(forKey: "fileSearchRecentPaths")
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
            searchLocations([path], browse: standalone && !showPathItself)
            return
        }
        browsingDirectory = nil
        let blank = FileSearchRules.tokens(text).isEmpty
        if blank, standalone {
            searchLocations(recentPaths.map { URL(fileURLWithPath: $0) }, browse: false, recent: true)
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

    private func searchLocations(_ urls: [URL], browse: Bool, recent: Bool = false) {
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
                if recent {
                    let files = Array(urls.lazy.compactMap { try? locations.item(at: $0) }.filter { !$0.isDirectory }.prefix(30))
                    return (files, files.isEmpty ? "通过 Keylane 打开文件后会显示在这里。" : "最近使用 · \(files.count) 项", nil)
                }
                let file = try locations.item(at: urls[0])
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
        guard isRunning, options.enabled, !currentQuery.isEmpty else { return }
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
        guard isRunning, options.enabled, !currentQuery.isEmpty else { return }
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
            if !system.isEmpty {
                var locations = FileSearchLocation(options: config, automaticExclusions: exclusions, restored: restored)
                allowed = system.filter { hit in
                    config.roots.contains { FileSearchLocation.contains(hit.file.id, in: $0) }
                        && (try? locations.item(at: hit.file.url)) != nil
                }
            }
            var seen = Set<String>()
            let ordered = (local + allowed).filter { hit in
                !removed.contains { FileSearchLocation.contains(hit.file.id, in: $0) } && seen.insert(hit.file.id).inserted
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
                let status = rows.isEmpty
                    ? (self.indexing ? "正在建立索引，完成后自动更新结果。" : "没有匹配项。请检查搜索范围、忽略规则或文件夹授权。")
                    : "\(rows.count)项\(truncated ? " · 请增加关键词" : "") · 文件索引"
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

    private func scanIndex(paths: [String]? = nil, force: Bool = false) {
        guard isRunning, options.enabled else { return }
        guard !indexPaused else {
            indexStatus = "本地索引已暂停，仍可搜索已有条目。"
            return
        }
        didStart = true; cancellation.cancel(); let token = FileScanCancellation(); cancellation = token
        let config = authorizedOptions; let exclusions = config.excludedPaths + automaticExclusions.map(\.path); let restored = restored
        indexing = true; indexStatus = paths == nil ? "正在建立文件索引…" : "正在更新文件索引…"; inaccessible = []; startWatch()
        writer.async { [weak self] in
            guard let self, let db = self.writeDB, !token.cancelled else { return }
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
                                    || ([".build", "DerivedData", "node_modules"].contains(parent.lastPathComponent)
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
                                            if isDir && [".build","DerivedData","node_modules"].contains(url.lastPathComponent) && !restored.contains(path) {
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
                                if self.lastPublished.isEmpty && !self.currentQuery.isEmpty && FileSearchLocation.typedURL(self.currentQuery) == nil
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
                    if self.hasQuery, !self.currentQuery.isEmpty {
                        if FileSearchLocation.typedURL(self.currentQuery) == nil { self.refreshQuery() }
                        else { self.reloadSearch() }
                    }
                    self.scheduleRefresh()
                }
            } catch { DispatchQueue.main.async {
                guard self.cancellation === token else { return }
                self.indexing = false; self.indexStatus = error.localizedDescription
                self.scheduleRefresh()
            } }
        }
    }
    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
    }

    private func stopWatch() { pendingRefresh?.cancel(); pendingRefresh = nil; dirtyPaths.removeAll(); needsFullScan = false; if let watch { FSEventStreamStop(watch); FSEventStreamInvalidate(watch); FSEventStreamRelease(watch) }; watch = nil }
    private func startWatch() {
        let roots = authorizedRoots
        guard watch == nil, watchEnabled, options.enabled, !indexPaused, !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        watch = FSEventStreamCreate(nil, { _, context, count, rawPaths, flags, _ in
            guard let context else { return }
            let owner = Unmanaged<FileSearchController>.fromOpaque(context).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            let recovery = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            owner.changed(Array(paths.prefix(count)), requiresFullScan: (0..<count).contains { flags[$0] & recovery != 0 })
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let watch {
            FSEventStreamSetDispatchQueue(watch, .main)
            if !FSEventStreamStart(watch) {
                FSEventStreamInvalidate(watch)
                FSEventStreamRelease(watch)
                self.watch = nil
            }
        }
    }
    private var churn: [String:(Date,Int)] = [:]
    private func changed(_ paths: [String], requiresFullScan: Bool) {
        var exclusions = automaticExclusions
        var newExclusions: Set<String> = []
        var changedPaths: [String] = []
        for path in paths {
            if let i = exclusions.firstIndex(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                exclusions[i].events += 1
                continue
            }
            changedPaths.append(path)
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            guard ["build", "output", "dist", "cache", "target"].contains(directory.lastPathComponent.lowercased()),
                  !restored.contains(directory.path) else { continue }
            let now = Date()
            let previous = churn[directory.path] ?? (now, 0)
            let value = now.timeIntervalSince(previous.0) < 60 ? (previous.0, previous.1 + 1) : (now, 1)
            if value.1 >= 120 {
                exclusions.append(.init(path: directory.path, reason: "一分钟内持续变化的构建或缓存目录", events: 0))
                newExclusions.insert(directory.path)
                churn.removeValue(forKey: directory.path)
            } else {
                churn[directory.path] = value
            }
        }
        if exclusions != automaticExclusions {
            automaticExclusions = exclusions
            saveAutomatic()
        }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let targets = changedPaths.map { path in
            let url = URL(fileURLWithPath: path)
            guard options.useIgnoreFiles else { return path }
            if [".gitignore", ".ignore", ".rayignore"].contains(url.lastPathComponent) { return url.deletingLastPathComponent().path }
            if path.hasSuffix("/.git/info/exclude") { return String(path.dropLast("/.git/info/exclude".count)) }
            return path
        }
        let relevant = targets.filter { path in
            guard options.roots.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { return false }
            if !options.includeHidden && path.split(separator:"/").contains(where:{ $0.hasPrefix(".") }) { return false }
            if path == library || path.hasPrefix(library + "/") {
                guard options.roots.contains(where:{ ($0 == library || $0.hasPrefix(library + "/")) && (path == $0 || path.hasPrefix($0 + "/")) }) else { return false }
            }
            return !automaticExclusions.contains { FileSearchLocation.contains(path, in: $0.path) }
                && !options.excludedPaths.contains { FileSearchLocation.contains(path, in: $0) }
                && !options.ignorePatterns.contains { FileSearchRules.glob($0,matches:path) }
        }
        dirtyPaths.formUnion(relevant)
        // Purge newly excluded subtrees even though their own events are filtered above.
        dirtyPaths.formUnion(newExclusions.filter { path in
            options.roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
        })
        if requiresFullScan || dirtyPaths.count > 256 {
            needsFullScan = true
            dirtyPaths.removeAll()
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !indexPaused, !indexing, pendingRefresh == nil, needsFullScan || !dirtyPaths.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            guard !self.indexing else { return }
            if self.needsFullScan { self.startIndex(); return }
            let paths = self.dirtyPaths.sorted()
            self.dirtyPaths.removeAll()
            var targets: [String] = []
            for path in paths where !targets.contains(where: { path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) {
                targets.append(path)
            }
            if !targets.isEmpty { self.scanIndex(paths: targets) }
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }
}
