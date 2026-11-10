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
    private var didStart = false
    private var grants: [String: Data]
    private var activeURLs: [URL] = []
    private var spotlight = SpotlightSearch()
    private var spotlightResults: [SpotlightFile] = []
    private var localResults: [SpotlightFile] = []
    private var watch: FSEventStreamRef?
    private var pendingRefresh: DispatchWorkItem?
    private var restored: Set<String> = []
    private var lastBuild = Date.distantPast
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
            self.spotlightResults = results.filter { file in
                let path = file.url.path
                return self.options.roots.contains { path == $0 || path.hasPrefix($0 + "/") } &&
                    (self.options.includeHidden || !path.split(separator:"/").contains { $0.hasPrefix(".") }) &&
                    !self.options.ignorePatterns.contains { FileSearchRules.glob($0, matches: path) } &&
                    !self.automaticExclusions.contains { path == $0.path || path.hasPrefix($0.path + "/") }
            }
            // Respect per-directory ignore files: results from our indexed roots are
            // authoritative when ignore-file filtering is enabled.
            self.publish()
        }
    }
    deinit { stopWatch(); cancellation.cancel(); activeURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
    private func fail(_ error: Error) { DispatchQueue.main.async { self.indexStatus = error.localizedDescription } }
    private func configure(old: FileSearchOptions) {
        preferences.set(try? JSONEncoder().encode(options), forKey: "fileSearchOptions")
        var previous = old; previous.searchFromLauncher = options.searchFromLauncher
        if previous == options { return }
        cancellation.cancel(); spotlight.cancel(); spotlightResults = []; localResults = []; stopWatch()
        let contentEnabled = options.contentSearch
        let removed = old.roots.filter { !options.roots.contains($0) }
        writer.async { [weak self] in
            guard let self else { return }
            do { for root in removed { try self.writeDB?.removeScope(root) }; if !contentEnabled { try self.writeDB?.clearBodies() } } catch { self.fail(error) }
        }
        if options.enabled { startIndex(); search(currentQuery) }
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
        queryVersion += 1; pendingQuery?.cancel(); queryCancellation.cancel(); spotlight.cancel(); currentQuery = ""; localResults = []; spotlightResults = []; isSearching = false
    }
    func search(_ text: String, homeOnly: Bool = false, root: URL? = nil) {
        let changed = currentQuery != text
        currentQuery = text
        guard options.enabled else { emit([], "文件搜索已关闭，请在设置中开启。"); return }
        if !didStart { didStart = true; startIndex() }
        guard !FileSearchRules.tokens(text).isEmpty, text.count <= 256 else {
            queryVersion += 1; pendingQuery?.cancel(); queryCancellation.cancel(); spotlight.cancel(); isSearching = false
            localResults = []; spotlightResults = []
            emit([], text.count > 256 ? "文件搜索最多256个字符。" : "输入文件名或多个关键词；搜索范围可在设置中添加并授权。")
            return
        }
        if changed {
            spotlight.cancel(); spotlightResults = []
            isSearching = true
            if !options.useIgnoreFiles { spotlight.search(text, root: options.roots.count == 1 ? URL(fileURLWithPath:options.roots[0]) : nil) }
        }
        refreshQuery(delay: changed ? 0.06 : 0)
    }
    private func refreshQuery(delay: Double = 0) {
        guard options.enabled, !currentQuery.isEmpty else { return }
        pendingQuery?.cancel(); queryCancellation.cancel(); queryCancellation = FileScanCancellation()
        let cancellation = queryCancellation
        queryVersion += 1; let ticket = queryVersion
        let text = currentQuery; let config = options; let excluded = automaticExclusions.map(\.path)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !cancellation.cancelled else { return }
            self.reader.async { [weak self] in
                guard let self, !cancellation.cancelled else { return }
                do {
                    let result = try self.readDB?.search(text, options: config, excluded: excluded, isCancelled: { cancellation.cancelled }) ?? []
                    DispatchQueue.main.async {
                        guard self.queryVersion == ticket, !cancellation.cancelled else { return }
                        self.localResults = result; if self.isSearching { self.isSearching = false }; self.publish()
                    }
                } catch { if !cancellation.cancelled { self.fail(error) } }
            }
        }
        pendingQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func emit(_ rows: [SpotlightFile], _ status: String) {
        guard lastPublished != rows || lastPublishedStatus != status || lastPublishedQuery != currentQuery else { return }
        lastPublished = rows; lastPublishedStatus = status; lastPublishedQuery = currentQuery; updated?(rows, status)
    }
    private func publish() {
        guard options.enabled, !currentQuery.isEmpty else { return }
        var seen = Set<String>()
        let candidates = (localResults + (options.useIgnoreFiles ? [] : spotlightResults)).filter { seen.insert($0.id).inserted }
        let ranked = candidates.map { (file: $0, score: FileSearchRules.rank($0.name, query: currentQuery)) }
        var rows = ranked.sorted { a,b in a.score == b.score ? (a.file.modified == b.file.modified ? a.file.id < b.file.id : a.file.modified > b.file.modified) : a.score > b.score }.map(\.file)
        if lastPublishedQuery == currentQuery {
            let fresh = Dictionary(uniqueKeysWithValues: rows.map { ($0.id,$0) })
            let previousIDs = Set(lastPublished.map(\.id))
            rows = lastPublished.compactMap { fresh[$0.id] } + rows.filter { !previousIDs.contains($0.id) }
        }
        let status = rows.isEmpty ? (indexing ? "正在建立索引，完成后自动更新结果。" : "没有匹配项。请检查搜索范围、忽略规则或文件夹授权。") : "\(min(200,rows.count))项\(rows.count >= 200 ? " · 请增加关键词" : "") · 文件索引"
        emit(Array(rows.prefix(200)), status)
    }
    private func refreshStats() {
        do { if let stats = try readDB?.stats() { DispatchQueue.main.async { var current = stats; current.invalid = self.stats.invalid; current.seconds = self.stats.seconds; self.stats = current } } } catch { fail(error) }
    }
    func startIndex() {
        guard options.enabled else { return }
        didStart = true; cancellation.cancel(); let token = FileScanCancellation(); cancellation = token
        let config = options; let exclusions = automaticExclusions.map(\.path); let restored = restored
        indexing = true; indexStatus = "正在建立文件索引…"; inaccessible = []; startWatch()
        writer.async { [weak self] in
            guard let self, let db = self.writeDB, !token.cancelled else { return }
            let start = Date(); var lastProgress = Date.distantPast; var invalid = 0; var denied: [String] = []; var auto: [AutomaticFileExclusion] = []; var processed = 0
            let homeLibrary = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
            let epoch = (config.contentSearch ? "c:" : "n:") + UUID().uuidString
            do {
                if !config.contentSearch { try db.clearBodies() }
                if !config.keepRemovedVolumes { try db.removeUnavailableVolumes() }
                for root in config.roots {
                    if token.cancelled { return }
                    let rootURL = URL(fileURLWithPath: root)
                    guard FileManager.default.fileExists(atPath: root) else { if !config.keepRemovedVolumes { try db.removeScope(root) }; continue }
                    var queue: [(URL,[FileSearchRules.IgnoreRule])] = [(rootURL,[])]; var position = 0; var complete = true
                    while position < queue.count && !token.cancelled {
                        let (directory,inherited) = queue[position]; position += 1
                        var rules = inherited; if config.useIgnoreFiles { rules += FileSearchRules.readIgnoreRules(in: directory) }
                        let keys: Set<URLResourceKey> = [.isDirectoryKey,.isSymbolicLinkKey,.contentModificationDateKey,.volumeURLKey,.volumeIsLocalKey,.volumeIsRemovableKey,.volumeIsInternalKey]
                        let children: [URL]
                        do { children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: config.includeHidden ? [] : [.skipsHiddenFiles]).sorted { a,b in
                            let priority = ["Downloads":0,"Desktop":1,"Documents":2]; return (priority[a.lastPathComponent] ?? 3) < (priority[b.lastPathComponent] ?? 3)
                        } } catch { invalid += 1; complete = false; if denied.count < 24 { denied.append(directory.path) }; continue }
                        if config.enforceDiskSpace {
                            let free = self.availableCapacity(db.url.deletingLastPathComponent())
                            // Reserve room for SQLite/WAL and the next directory batch.
                            let estimate = Int64(children.count * (config.contentSearch ? 102_400 : 1024)) + 128 * 1024 * 1024
                            guard free > estimate else { throw FileIndexError.diskSpace }
                        }
                        try db.transaction {
                            for url in children {
                                if token.cancelled { return }
                                guard let value = try? url.resourceValues(forKeys: keys) else { invalid += 1; continue }
                                let isDir = value.isDirectory == true; let symlink = value.isSymbolicLink == true; let path = url.path
                                guard !exclusions.contains(where: { path == $0 || path.hasPrefix($0 + "/") }), !FileSearchRules.ignored(url, directory: isDir, patterns: config.ignorePatterns, rules: rules) else { continue }
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
                            self.reader.async { self.refreshStats() }
                            DispatchQueue.main.async { if self.cancellation === token {
                                self.indexStatus = "正在索引：\(count)项"
                                if self.lastPublished.isEmpty && !self.currentQuery.isEmpty && !self.isSearching { self.refreshQuery() }
                            } }
                        }
                    }
                    if token.cancelled { return }
                    if complete { try db.removeUnseen(root:root,epoch:epoch) }
                }
                var stats = try db.stats(); stats.invalid = invalid; stats.seconds = Date().timeIntervalSince(start)
                DispatchQueue.main.async {
                    guard self.cancellation === token else { return }
                    self.indexing = false; self.stats = stats; self.preferences.set(try? JSONEncoder().encode(stats), forKey:"fileSearchLastStats"); self.inaccessible = denied; self.lastBuild = Date()
                    for value in auto where !self.automaticExclusions.contains(where: { $0.path == value.path }) { self.automaticExclusions.append(value) }; self.saveAutomatic()
                    self.indexStatus = denied.isEmpty ? "索引已更新" : "部分目录无法访问，请重新授权搜索范围。"
                    if !self.currentQuery.isEmpty { self.refreshQuery() }
                }
            } catch { DispatchQueue.main.async { guard self.cancellation === token else { return }; self.indexing = false; self.indexStatus = error.localizedDescription } }
        }
    }
    private func stopWatch() { pendingRefresh?.cancel(); pendingRefresh = nil; if let watch { FSEventStreamStop(watch); FSEventStreamInvalidate(watch); FSEventStreamRelease(watch) }; watch = nil }
    private func startWatch() {
        stopWatch(); guard watchEnabled, options.enabled, !options.roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        watch = FSEventStreamCreate(nil, { _, context, count, rawPaths, _, _ in
            guard let context else { return }
            let owner = Unmanaged<FileSearchController>.fromOpaque(context).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as! [String]
            owner.changed(Array(paths.prefix(count)))
        }, &context, options.roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let watch { FSEventStreamSetDispatchQueue(watch,.main); FSEventStreamStart(watch) }
    }
    private var churn: [String:(Date,Int)] = [:]
    private func changed(_ paths: [String]) {
        var changedExclusions = false
        for path in paths {
            if let i = automaticExclusions.firstIndex(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { automaticExclusions[i].events += 1; changedExclusions = true; continue }
            let directory = URL(fileURLWithPath:path).deletingLastPathComponent()
            guard ["build","output","dist","cache","target"].contains(directory.lastPathComponent.lowercased()), !restored.contains(directory.path) else { continue }
            let previous = churn[directory.path] ?? (Date(),0)
            let value = Date().timeIntervalSince(previous.0) < 60 ? (previous.0,previous.1+1) : (Date(),1)
            churn[directory.path] = value
            if value.1 >= 120 { automaticExclusions.append(.init(path:directory.path,reason:"一分钟内持续变化的构建或缓存目录",events:0)); changedExclusions = true }
        }
        if changedExclusions { saveAutomatic() }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path
        let relevant = paths.filter { path in
            if !options.includeHidden && path.split(separator:"/").contains(where:{ $0.hasPrefix(".") }) { return false }
            if path == library || path.hasPrefix(library + "/") {
                guard options.roots.contains(where:{ ($0 == library || $0.hasPrefix(library + "/")) && (path == $0 || path.hasPrefix($0 + "/")) }) else { return false }
            }
            return !automaticExclusions.contains { path == $0.path || path.hasPrefix($0.path + "/") } && !options.ignorePatterns.contains { FileSearchRules.glob($0,matches:path) }
        }
        guard !relevant.isEmpty else { return }
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in guard let self else { return }; if !self.indexing { self.startIndex() } }
        pendingRefresh = work; DispatchQueue.main.asyncAfter(deadline:.now()+max(2,15-Date().timeIntervalSince(lastBuild)),execute:work)
    }
}
