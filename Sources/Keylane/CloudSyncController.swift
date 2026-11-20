import AppKit
import Combine
import KeylaneCore

final class CloudSyncController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未启用"
    @Published private(set) var lastSync: Date?
    @Published private(set) var devices: [SyncManifest] = []
    @Published private(set) var counts: [SyncCategory: Int] = [:]
    @Published private(set) var folderName: String
    @Published private(set) var categories: Set<SyncCategory>
    private let defaults: UserDefaults
    private let local: URL
    private let deviceID: UUID
    private let worker = DispatchQueue(label: "org.keylane.cloud-sync", qos: .utility)
    private var timer: Timer?
    private var queued: DispatchWorkItem?
    private var changes: NSObjectProtocol?
    private var contentChanges: NSObjectProtocol?
    private var watcher: NSMetadataQuery?
    private var watcherFolder: URL?
    private var watcherReady = false
    private var watcherAccess = false
    private var watcherObservers: [NSObjectProtocol] = []
    private var generation = UUID()
    private var running = false
    private var started = false
    private weak var model: Model?

    init(model: Model?, defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults
        deviceID = defaults.string(forKey: "sync.deviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        enabled = defaults.bool(forKey: "sync.enabled")
        categories = Set(SyncCategory.allCases.filter { defaults.object(forKey: "sync.category." + $0.rawValue) as? Bool ?? ($0 != .clipboard) })
        folderName = defaults.string(forKey: "sync.folderName") ?? "未选择"
        local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/Sync", isDirectory: true)
    }
    func start() {
        guard !started else { return }; started = true
        changes = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in self?.schedule() }
        contentChanges = NotificationCenter.default.addObserver(forName: .keylaneSyncSourceChanged, object: nil, queue: .main) { [weak self] _ in self?.schedule() }
        if enabled { defaults.set(deviceID.uuidString, forKey: "sync.deviceID"); startTimer(); schedule() }
    }
    func stop() {
        started = false; generation = UUID(); stopWatcher(); timer?.invalidate(); timer = nil; queued?.cancel()
        if let changes { NotificationCenter.default.removeObserver(changes) }; changes = nil
        if let contentChanges { NotificationCenter.default.removeObserver(contentChanges) }; contentChanges = nil
    }
    func setEnabled(_ value: Bool) {
        if value && defaults.data(forKey: "sync.folderBookmark") == nil { chooseFolder(enableAfter: true); return }
        generation = UUID(); enabled = value; defaults.set(value, forKey: "sync.enabled")
        queued?.cancel(); timer?.invalidate(); timer = nil
        if value { defaults.set(deviceID.uuidString, forKey: "sync.deviceID"); startTimer(); schedule() } else { stopWatcher(); status = "已暂停，保留本机与 iCloud 数据" }
    }
    func setCategory(_ category: SyncCategory, enabled value: Bool) {
        if value { categories.insert(category) } else { categories.remove(category) }
        defaults.set(value, forKey: "sync.category." + category.rawValue)
        generation = UUID(); schedule()
    }
    func chooseFolder(enableAfter: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "使用此文件夹"
        panel.message = "在 iCloud Drive 中选择或新建 Keylane 同步文件夹。其他 Mac 选择同一文件夹。该文件夹中的同步资料可由有访问权限的人读取。"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
            guard values.isUbiquitousItem == true else { status = "请选择 iCloud Drive 内的文件夹。"; return }
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            defaults.set(bookmark, forKey: "sync.folderBookmark"); defaults.set(url.lastPathComponent, forKey: "sync.folderName")
            folderName = url.lastPathComponent; generation = UUID(); stopWatcher()
            if enableAfter { setEnabled(true) } else { schedule() }
        } catch { status = "无法保存所选文件夹的访问权限。" }
    }
    func syncNow() { schedule(delay: 0) }
    func revealRecovery() {
        guard let bookmark = defaults.data(forKey: "sync.folderBookmark") else { return }
        let recovery = local.appendingPathComponent(SyncHash.digest(bookmark) + "/Recovery", isDirectory: true)
        if FileManager.default.fileExists(atPath: recovery.path) { NSWorkspace.shared.open(recovery) }
        else { status = "尚无需要保留的冲突恢复副本。" }
    }
    private func stopWatcher() {
        watcher?.stop(); watcher = nil; watcherReady = false
        watcherObservers.forEach(NotificationCenter.default.removeObserver); watcherObservers = []
        if watcherAccess, let watcherFolder { watcherFolder.stopAccessingSecurityScopedResource() }
        watcherFolder = nil; watcherAccess = false
    }
    /// iCloud may advertise a document before it has any local directory entry. Discovery is
    /// scoped to the explicitly chosen directory and remains on the main run loop.
    private func discoveredFiles(in folder: URL) throws -> [URL] {
        if watcherFolder?.standardizedFileURL != folder.standardizedFileURL || watcher == nil {
            stopWatcher(); watcherFolder = folder; watcherAccess = folder.startAccessingSecurityScopedResource()
            let query = NSMetadataQuery()
            query.searchScopes = [folder]
            query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.json")
            for name in [Notification.Name.NSMetadataQueryDidFinishGathering, Notification.Name.NSMetadataQueryDidUpdate] {
                watcherObservers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                    self?.watcherReady = true; self?.schedule()
                })
            }
            watcher = query
            guard query.start() else { stopWatcher(); throw SyncError.unavailable }
        }
        guard watcherReady, let watcher else { throw SyncError.unavailable }
        let directory = folder.appendingPathComponent("KeylaneSync-v1/devices", isDirectory: true).standardizedFileURL
        watcher.disableUpdates(); defer { watcher.enableUpdates() }
        return watcher.results.compactMap { ($0 as? NSMetadataItem)?.value(forAttribute: NSMetadataItemURLKey) as? URL }
            .filter { $0.deletingLastPathComponent().standardizedFileURL == directory }
    }
    private func startTimer() {
        // No timers or database reads while disabled. One coalesced serial pass per minute is
        // also the fallback for local database edits and iCloud downloads completing remotely.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.schedule(delay: 0) }
        timer?.tolerance = 10
    }
    private func schedule(delay: TimeInterval = 2) {
        guard started, enabled else { return }
        queued?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.run() }
        queued = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func run() {
        guard enabled, !running, let bookmark = defaults.data(forKey: "sync.folderBookmark") else { return }
        running = true; busy = true; status = "正在同步…"
        let token = generation, selected = categories, local = local, device = deviceID, name = Host.current().localizedName ?? "Mac"
        let contributions = model?.launcherModules?.syncContributions ?? []
        worker.async { [weak self] in
            var applied = Set<SyncCategory>()
            let allowed = { [weak self] () -> Bool in
                guard let self else { return false }
                return DispatchQueue.main.sync { self.enabled && self.generation == token }
            }
            let result = Result { () -> ([SyncManifest], [SyncCategory: Int], Set<SyncCategory>) in
                guard allowed() else { throw SyncError.cancelled }
                var stale = false
                let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale, FileManager.default.isUbiquitousItem(at: folder) else { throw SyncError.unavailable }
                let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let discovered: [URL] = try DispatchQueue.main.sync {
                    guard let self, self.enabled, self.generation == token else { throw SyncError.cancelled }
                    return try self.discoveredFiles(in: folder)
                }
                let transport = try SyncDriveTransport(directory: folder.appendingPathComponent("KeylaneSync-v1", isDirectory: true), discoveredManifests: discovered)
                return try Self.synchronize(local: local, journalID: SyncHash.digest(bookmark), deviceID: device, transport: transport, contributions: contributions, categories: selected, name: name,
                    allowed: allowed, didApply: { applied.insert($0) })
            }
            let appliedCategories = applied
            DispatchQueue.main.async {
                guard let self else { return }; self.running = false; self.busy = false
                if !appliedCategories.isEmpty {
                    self.model?.syncDidApply(appliedCategories)
                    NotificationCenter.default.post(name: .keylaneSyncApplied, object: nil, userInfo: ["categories": appliedCategories])
                }
                guard self.generation == token, self.enabled else { if self.enabled { self.schedule() }; return }
                switch result {
                case .success(let (devices, counts, _)):
                    self.devices = devices; self.counts = counts; self.lastSync = .now
                    self.status = "已与 iCloud Drive 文件夹同步，其他设备下载可能稍有延迟"
                case .failure(let error):
                    self.status = (error as? SyncError)?.localizedDescription ?? (error as? ClipboardError)?.localizedDescription ?? (error as? ConfigurationError)?.localizedDescription ?? "同步未完成，本机资料仍保留。请检查 iCloud Drive 后重试。"
                }
            }
        }
    }
    static func synchronize(local: URL, journalID: String, deviceID: UUID, transport: SyncDriveTransport, contributions: [LauncherSyncContribution], categories: Set<SyncCategory>, name: String,
                            allowed: () -> Bool = { true }, didApply: (SyncCategory) -> Void = { _ in }) throws -> ([SyncManifest], [SyncCategory: Int], Set<SyncCategory>) {
        let selected = contributions.filter { categories.contains($0.category) }
        guard Set(selected.map(\.category)).count == selected.count else { throw SyncError.invalidData }
        return try SyncEngine.run(local: local.appendingPathComponent(journalID, isDirectory: true), transport: transport,
            participants: selected.map { $0.make(local.deletingLastPathComponent()) },
            name: name, deviceID: deviceID, allowed: allowed, didApply: didApply)
    }
}

extension Notification.Name { static let keylaneSyncApplied = Notification.Name("org.keylane.sync.applied") }
