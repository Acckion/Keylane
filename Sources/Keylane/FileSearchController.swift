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
    @Published private(set) var isSearching = false
    var updated: (([SpotlightFile], String) -> Void)?
    private let preferences: UserDefaults
    private let availableCapacity: (URL) -> Int64
    private let watchEnabled: Bool
    private let writer = DispatchQueue(label: "org.keylane.files.index", qos: .utility)
    private let reader = DispatchQueue(label: "org.keylane.files.search", qos: .userInitiated)
    private var writeDB: FileSearchIndex?
    private var readDB: FileSearchIndex?
    private var cancellation = FileScanCancellation()
    private var queryVersion = 0
    private var pendingQuery: DispatchWorkItem?
    private var queryCancellation = FileScanCancellation()
    private var lastPublished: [SpotlightFile] = []
    private var lastPublishedQuery = ""
    private var lastPublishedStatus = ""
    private var currentQuery = ""
    private var includesQueryContents = true
    private var localQueryResolved = false
    private var didStart = false
    private var grants: [String: Data]
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
        return FileSearchOptions(roots: [home, "/Applications", home + "/Library/Mobile Documents/com~apple~CloudDocs"])
    }
    init(directory: URL? = nil, preferences: UserDefaults = .standard, defaultOptions: FileSearchOptions? = nil, watchChanges: Bool = true, availableCapacity: ((URL) -> Int64)? = nil) {
        self.preferences = preferences; self.watchEnabled = watchChanges
        self.availableCapacity = availableCapacity ?? { url in (try? FileManager.default.attributesOfFileSystem(forPath:url.path)[.systemFreeSize] as? Int64) ?? 0 }
        options = preferences.data(forKey: "fileSearchOptions").flatMap { try? JSONDecoder().decode(FileSearchOptions.self, from: $0) } ?? defaultOptions ?? Self.defaults
        grants = preferences.dictionary(forKey: "fileSearchGrants") as? [String: Data] ?? [:]
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
        resolveGrants()
        let url = directory?.appendingPathComponent("index.sqlite") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/FileSearch/index.sqlite")
        writer.async { [weak self] in
            guard let self else { return }
            do {
                self.writeDB = try FileSearchIndex(url: url)
                try self.reader.sync { self.readDB = try FileSearchIndex(url: url); self.refreshStats() }
                DispatchQueue.main.async { if !self.currentQuery.isEmpty { self.refreshQuery() } }
            }
            catch { self.fail(error) }
        }
        spotlight.updated = { [weak self] results, _ in
            guard let self else { return }
            self.spotlightResults = results
            if self.isSearching && !self.localQueryResolved && results.isEmpty { return }
            self.publish()
        }
    }
    deinit { stopWatch(); cancelMerge(); cancellation.cancel(); activeURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
    private func fail(_ error: Error) { DispatchQueue.main.async { self.indexStatus = error.localizedDescription } }
    private func configure(old: FileSearchOptions) {
        preferences.set(try? JSONEncoder().encode(options), forKey: "fileSearchOptions")
        var previous = old; previous.searchFromLauncher = options.searchFromLauncher
        if previous == options { return }
        cancelMerge(); cancellation.cancel(); spotlight.cancel(); spotlightResults = []; localResults = []; stopWatch()
        let contentEnabled = options.contentSearch
        let removed = old.roots.filter { !options.roots.contains($0) }
        writer.async { [weak self] in
            guard let self else { return }
            do { for root in removed { try self.writeDB?.removeScope(root) }; if !contentEnabled { try self.writeDB?.clearBodies() } } catch { self.fail(error) }
        }
        if options.enabled {
            let query = currentQuery
            currentQuery = ""
            startIndex()
            search(query, includeContents: includesQueryContents)
        }
        else { indexing = false; indexStatus = "文件搜索已关闭"; updated?([], indexStatus) }
    }
    private func resolveGrants() {
        activeURLs.forEach { $0.stopAccessingSecurityScopedResource() }; activeURLs = []
        for (_,data) in grants {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope,.withoutUI], bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() { activeURLs.append(url) }
        }
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
            if let data = try? url.bookmarkData(options: [.withSecurityScope,.securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) { grants[path] = data }
            if !roots.contains(path) { roots.append(path) }
        }
        preferences.set(grants, forKey: "fileSearchGrants"); resolveGrants()
        if options.roots == roots { startIndex() } else { options.roots = roots }
    }
    func removeScope(_ path: String) { grants.removeValue(forKey: path); preferences.set(grants, forKey: "fileSearchGrants"); options.roots.removeAll { $0 == path }; resolveGrants() }
    func restore(_ path: String) { restored.insert(path); automaticExclusions.removeAll { $0.path == path }; saveAutomatic(); startIndex() }
    private func saveAutomatic() { preferences.set(try? JSONEncoder().encode(automaticExclusions), forKey: "fileSearchAutomaticExclusions") }
    func reset() {
        grants = [:]; preferences.removeObject(forKey: "fileSearchGrants"); resolveGrants()
        automaticExclusions = []; saveAutomatic(); options = Self.defaults; startIndex()
    }
    func cancel() {
        cancelMerge()
        queryVersion += 1; pendingQuery?.cancel(); queryCancellation.cancel(); spotlight.cancel(); currentQuery = ""; localResults = []; spotlightResults = []; localQueryResolved = false; isSearching = false
    }
    func search(_ text: String, homeOnly: Bool = false, root: URL? = nil, includeContents: Bool = true) {
        let scopeChanged = includesQueryContents != includeContents
        let changed = currentQuery != text || scopeChanged
        currentQuery = text
        includesQueryContents = includeContents
        guard options.enabled else { emit([], "文件搜索已关闭，请在设置中开启。"); return }
        guard !FileSearchRules.tokens(text).isEmpty, text.count <= 256 else {
            cancelMerge()
            queryVersion += 1; pendingQuery?.cancel(); queryCancellation.cancel(); spotlight.cancel(); isSearching = false
            localResults = []; spotlightResults = []; localQueryResolved = false
            emit([], text.count > 256 ? "文件搜索最多256个字符。" : "输入文件名或多个关键词；搜索范围可在设置中添加并授权。")
            return
        }
        if !didStart { startIndex() }
        if changed {
            cancelMerge()
            spotlight.cancel(); spotlightResults = []; localResults = []
            localQueryResolved = false
            isSearching = true
            if scopeChanged { emit([], "正在搜索…") }
            if !options.useIgnoreFiles { spotlight.search(text, root: options.roots.count == 1 ? URL(fileURLWithPath:options.roots[0]) : nil) }
        }
        refreshQuery(delay: changed ? 0.06 : 0)
    }
    private func refreshQuery(delay: Double = 0) {
        guard options.enabled, !currentQuery.isEmpty else { return }
        pendingQuery?.cancel(); queryCancellation.cancel(); queryCancellation = FileScanCancellation()
        let cancellation = queryCancellation
        queryVersion += 1; let ticket = queryVersion
        let text = currentQuery
        var config = options
        config.contentSearch = config.contentSearch && includesQueryContents
        let queryOptions = config
        let excluded = automaticExclusions.map(\.path)
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
        guard options.enabled, !currentQuery.isEmpty else { return }
        cancelMerge()
        let ticket = mergeVersion
        let query = currentQuery
        let config = options
        let exclusions = automaticExclusions.map(\.path)
        let local = localResults
        let system = config.useIgnoreFiles ? [] : spotlightResults
        let task = DispatchWorkItem { [weak self] in
            let ignored = FileSearchRules.pathFilter(config.ignorePatterns)
            let allowed = system.filter { hit in
                let path = hit.file.id
                return config.roots.contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
                    && (config.includeHidden || !path.split(separator: "/").contains { $0.hasPrefix(".") })
                    && !ignored(path, hit.file.url.lastPathComponent)
                    && !exclusions.contains { path == $0 || path.hasPrefix($0 + "/") }
            }
            var seen = Set<String>()
            let ordered = (local + allowed).filter { seen.insert($0.file.id).inserted }
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
    private func refreshStats() {
        do { if let stats = try readDB?.stats() { DispatchQueue.main.async { var current = stats; current.invalid = self.stats.invalid; current.seconds = self.stats.seconds; self.stats = current } } } catch { fail(error) }
    }
    func startIndex() {
        dirtyPaths.removeAll()
        needsFullScan = false
        scanIndex()
    }
    private func scanIndex(paths: [String]? = nil) {
        guard options.enabled else { return }
        didStart = true; cancellation.cancel(); let token = FileScanCancellation(); cancellation = token
        let config = options; let exclusions = automaticExclusions.map(\.path); let restored = restored
        indexing = true; indexStatus = paths == nil ? "正在建立文件索引…" : "正在更新文件索引…"; inaccessible = []; startWatch()
        writer.async { [weak self] in
            guard let self, let db = self.writeDB, !token.cancelled else { return }
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
                    var queue: [(URL,[FileSearchRules.IgnoreRule])] = [(firstDirectory,inheritedRules)]; var position = 0; var complete = true
                    while position < queue.count && !token.cancelled {
                        let (directory,inherited) = queue[position]; position += 1
                        var rules = inherited; if config.useIgnoreFiles { rules += FileSearchRules.readIgnoreRules(in: directory) }
                        let children: [URL]
                        do {
                            if let entry, position == 1 {
                                children = [entry]
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
                            continue
                        }
                        if config.enforceDiskSpace {
                            let free = self.availableCapacity(db.url.deletingLastPathComponent())
                            // Reserve room for SQLite/WAL and the next directory batch.
                            let estimate = Int64(children.count * (config.contentSearch ? 102_400 : 1024)) + 128 * 1024 * 1024
                            guard free > estimate else { throw FileIndexError.diskSpace }
                        }
                        try db.transaction {
                            for url in children {
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
                                if try db.touchUnchanged(record,root:root,epoch:epoch,contentSearch:config.contentSearch) { processed += 1; if isDir && !symlink && url.pathExtension != "app" { queue.append((url,rules)) }; continue }
                                let body = config.contentSearch && !isDir && !symlink ? FileSearchIndex.content(at:url) : ""
                                try db.put(record,body:body,root:root,epoch:epoch); processed += 1
                                if isDir && !symlink && url.pathExtension != "app" { queue.append((url,rules)) }
                            }
                        }
                        if Date().timeIntervalSince(lastProgress) >= 1 {
                            lastProgress = Date(); let count = processed
                            DispatchQueue.main.async { if self.cancellation === token {
                                self.indexStatus = "正在索引：\(count)项"
                                if self.lastPublished.isEmpty && !self.currentQuery.isEmpty && !self.isSearching { self.refreshQuery() }
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
                    if !self.currentQuery.isEmpty { self.refreshQuery() }
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
        guard watch == nil, watchEnabled, options.enabled, !options.roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        watch = FSEventStreamCreate(nil, { _, context, count, rawPaths, flags, _ in
            guard let context else { return }
            let owner = Unmanaged<FileSearchController>.fromOpaque(context).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            let recovery = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
            owner.changed(Array(paths.prefix(count)), requiresFullScan: (0..<count).contains { flags[$0] & recovery != 0 })
        }, &context, options.roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
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
            return !automaticExclusions.contains { path == $0.path || path.hasPrefix($0.path + "/") } && !options.ignorePatterns.contains { FileSearchRules.glob($0,matches:path) }
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
        guard !indexing, pendingRefresh == nil, needsFullScan || !dirtyPaths.isEmpty else { return }
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
