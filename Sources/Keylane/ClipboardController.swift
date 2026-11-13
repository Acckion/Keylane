import AppKit
import Combine
import ImageIO
import Vision
import UniformTypeIdentifiers
import KeylaneCore

enum ClipboardPrimaryAction: String {
    case paste, copy
}

enum ClipboardReplayFormat: Hashable {
    case preferred, original, plainText, representation(String), pngFromTIFF
}

struct ClipboardTextDraft: Identifiable, Equatable {
    let id: String
    let text: String
    let hasOtherFormats: Bool
}

final class ClipboardFiles {
    let urls: [URL]
    private let scopedURLs: [URL]

    init(_ references: [ClipFile]) {
        urls = references.map { reference in
            var stale = false
            if let bookmark = reference.bookmark,
               let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                       bookmarkDataIsStale: &stale) { return resolved }
            return URL(fileURLWithPath: reference.path)
        }
        scopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
    }

    deinit { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

    var isAvailable: Bool { !urls.isEmpty && urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
}

/// Pasteboard reads and published state belong to the main thread. SQLite belongs
/// exclusively to worker; OCR never blocks that queue or resurrects deleted rows.
final class ClipboardController: ObservableObject {
    @Published var captureEnabled: Bool {
        didSet {
            guard captureEnabled != oldValue else { return }
            preferences.set(captureEnabled, forKey: "clipboardPersistentCapture")
            if runtime != nil { finishCapture(of: board.changeCount) }
            updateCaptureTimer()
        }
    }
    @Published var savesUniversalClipboardImmediately: Bool {
        didSet {
            guard savesUniversalClipboardImmediately != oldValue else { return }
            preferences.set(savesUniversalClipboardImmediately, forKey: "clipboardSaveUniversalImmediately")
            if let pending = pendingClipboardRead { finishCapture(of: pending.generation) }
            updateUniversalClipboardMonitor()
        }
    }
    @Published var automaticOCR: Bool {
        didSet {
            preferences.set(automaticOCR, forKey: "clipboardAutomaticOCR")
            continueOCR()
        }
    }
    @Published var accurateOCR: Bool {
        didSet {
            preferences.set(accurateOCR, forKey: "clipboardAccurateOCR")
            ocrAttempts.removeAll()
            requestOCRScan()
        }
    }
    @Published var primaryAction: ClipboardPrimaryAction {
        didSet { preferences.set(primaryAction.rawValue, forKey: "clipboardPrimaryAction") }
    }
    @Published var prefersPlainText: Bool {
        didSet { preferences.set(prefersPlainText, forKey: "clipboardPrefersPlainText") }
    }
    @Published var updatesHistoryAfterReplay: Bool {
        didSet { preferences.set(updatesHistoryAfterReplay, forKey: "clipboardUpdatesHistoryAfterReplay") }
    }
    @Published var showsLinkVisuals: Bool {
        didSet { preferences.set(showsLinkVisuals, forKey: "clipboardShowsLinkVisuals") }
    }
    @Published var historyCommandEnabled: Bool { didSet { preferences.set(historyCommandEnabled, forKey: "clipboardHistoryCommandEnabled") } }
    @Published var retentionDays: Int { didSet { preferences.set(retentionDays, forKey: "clipboardRetentionDays"); updateLimits() } }
    @Published var maxItems: Int { didSet { preferences.set(maxItems, forKey: "clipboardMaxItems"); updateLimits() } }
    @Published var excludedApps: Set<String> { didSet { preferences.set(Array(excludedApps), forKey: "clipboardExcludedApps") } }
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var detail: ClipDetail?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var status = ""
    @Published private(set) var total = 0
    @Published private(set) var migrationBackupCount = 0
    @Published private(set) var loadingDetail = false
    @Published private(set) var searching = false
    @Published private(set) var indexingImageText = false
    @Published private(set) var accessMessage = ""
    @Published var textDraft: ClipboardTextDraft?
    @Published var showsHistorySettings = false
    @Published var kind: String = "all" { didSet { reload() } }
    @Published var pinnedOnly = false { didSet { reload() } }
    private let board: NSPasteboard
    private let preferences: UserDefaults
    private let worker = DispatchQueue(label: "org.keylane.clipboard.storage", qos: .utility)
    private let previewWorker = DispatchQueue(label: "org.keylane.clipboard.preview", qos: .userInitiated)
    private let listPreviewWorker = DispatchQueue(label: "org.keylane.clipboard.list-preview", qos: .utility)
    private let ocrWorker = DispatchQueue(label: "org.keylane.clipboard.ocr", qos: .utility)
    private let storageDirectory: URL
    private var runtime: ImageTextRecognitionWork?
    private var store: ClipboardStore?
    private let listThumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200; cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    private var monitoringRequested = false
    private var timer: Timer?
    private var pollTicks = 0
    private var capturedChanges = 0
    private var captureOutcome = "starting"
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["KEYLANE_CLIPBOARD_DIAGNOSTICS"] == "1"
    private var lastChange: Int
    private var lastIncompleteChange: Int?
    private var pendingClipboardRead: PendingClipboardRead?
    private var currentUniversalFiles: (generation: Int, paths: [String])?
    private let universalClipboardMonitor = UniversalClipboardMonitor()

    private struct PendingClipboardRead {
        let generation: Int
        let deadline: TimeInterval
        var retryAfter: TimeInterval
        var expectsRemote: Bool
    }

    private var query = ""
    private var generation = 0
    private var pendingSearch: DispatchWorkItem?
    private var pendingReload: DispatchWorkItem?
    private var detailRequest: ImageTextRecognitionWork?
    private var presentationActive: Bool
    private var lastMaintenance = Date()
    private var ocrNeedsScan = true
    private var ocrRunning = false
    private var ocrPending: ArraySlice<ClipboardOCRCandidate> = []
    private var ocrAttempts: [String: Date] = [:]
    init(directory: URL? = nil, board: NSPasteboard = .general, preferences: UserDefaults = .standard, startTimer: Bool = true, presentationActive: Bool = true, startStorage: Bool = true) {
        self.presentationActive = presentationActive
        self.board = board; self.preferences = preferences; lastChange = 0
        // The old memory-only opt-in does not silently become permission to persist.
        captureEnabled = preferences.bool(forKey: "clipboardPersistentCapture")
        savesUniversalClipboardImmediately = preferences.bool(forKey: "clipboardSaveUniversalImmediately")
        automaticOCR = preferences.bool(forKey: "clipboardAutomaticOCR")
        accurateOCR = preferences.object(forKey: "clipboardAccurateOCR") as? Bool ?? true
        primaryAction = preferences.string(forKey: "clipboardPrimaryAction").flatMap(ClipboardPrimaryAction.init(rawValue:)) ?? .paste
        prefersPlainText = preferences.bool(forKey: "clipboardPrefersPlainText")
        updatesHistoryAfterReplay = preferences.bool(forKey: "clipboardUpdatesHistoryAfterReplay")
        showsLinkVisuals = preferences.object(forKey: "clipboardShowsLinkVisuals") as? Bool ?? true
        historyCommandEnabled = preferences.object(forKey: "clipboardHistoryCommandEnabled") as? Bool ?? true
        retentionDays = preferences.object(forKey: "clipboardRetentionDays") as? Int ?? 30
        maxItems = preferences.object(forKey: "clipboardMaxItems") as? Int ?? 500
        excludedApps = Set(preferences.stringArray(forKey: "clipboardExcludedApps") ?? []).union(ClipboardPolicy.defaultExcluded)
        storageDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/Clipboard", isDirectory: true)
        if startStorage { startRuntime() }
        if startTimer { startMonitoring() }
    }

    func startRuntime() {
        guard runtime == nil else { return }
        let token = ImageTextRecognitionWork()
        runtime = token
        finishCapture(of: board.changeCount)
        let limits = ClipboardLimits(maxItems: maxItems, retentionDays: retentionDays)
        worker.async { [weak self] in
            guard let self, !token.cancelled else { return }
            do {
                self.store = try ClipboardStore(directory: self.storageDirectory, limits: limits)
                guard !token.cancelled else { return }
                try self.store?.prune()
                DispatchQueue.main.async {
                    if !token.cancelled { self.reload() }
                }
            } catch {
                DispatchQueue.main.async { if !token.cancelled { self.status = error.localizedDescription } }
            }
        }
    }

    func stopRuntime() {
        guard let runtime else { return }
        runtime.cancel()
        self.runtime = nil
        stopMonitoring()
        generation += 1
        pendingSearch?.cancel(); pendingSearch = nil
        pendingReload?.cancel(); pendingReload = nil
        detailRequest?.cancel(); detailRequest = nil
        presentationActive = false
        query = ""
        items = []; selectedID = nil; detail = nil; thumbnail = nil; textDraft = nil
        searching = false; loadingDetail = false; indexingImageText = false
        listThumbnailCache.removeAllObjects()
        sharingPicker = nil
        ocrPending = []; ocrAttempts = [:]; ocrRunning = false; ocrNeedsScan = true
        worker.async { [weak self] in self?.store = nil }
    }

    func startMonitoring() {
        monitoringRequested = true
        finishCapture(of: board.changeCount)
        updateCaptureTimer()
    }

    func stopMonitoring() {
        monitoringRequested = false
        pendingClipboardRead = nil
        lastIncompleteChange = nil
        updateCaptureTimer()
    }

    private func updateCaptureTimer() {
        updateUniversalClipboardMonitor()
        guard runtime != nil, monitoringRequested && captureEnabled else {
            timer?.invalidate()
            timer = nil
            recordMonitorHealth()
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        recordMonitorHealth()
    }
    private func updateUniversalClipboardMonitor() {
        guard runtime != nil, monitoringRequested, captureEnabled, savesUniversalClipboardImmediately,
              board.name == .general, board.accessBehavior == .alwaysAllow else {
            universalClipboardMonitor.stop()
            return
        }
        universalClipboardMonitor.start { [weak self] generation in self?.universalClipboardArrived(generation) }
    }

    deinit { timer?.invalidate(); detailRequest?.cancel(); pendingReload?.cancel() }
    func feedback(_ text: String) { status = text }
    func search(_ value: String) {
        guard runtime != nil else { return }
        presentationActive = true
        query = value; searching = true; pendingSearch?.cancel(); pendingReload?.cancel(); generation += 1
        let work = DispatchWorkItem { [weak self] in self?.reload() }; pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.06,execute:work)
    }
    /// Closing the page ends preview work; capture and storage remain independent.
    func endPresentation() {
        textDraft = nil
        guard presentationActive else { return }
        presentationActive = false
        generation += 1
        pendingSearch?.cancel()
        pendingReload?.cancel()
        detailRequest?.cancel()
        detailRequest = nil
        detail = nil
        thumbnail = nil
        searching = false
        loadingDetail = false
        reload()
    }
    func reload() {
        guard let runtime else { return }
        generation += 1; let ticket = generation; let value = query; let filter = ClipboardCategory(rawValue: kind); let pins = pinnedOnly
        let includeRecords = presentationActive
        pendingReload?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !runtime.cancelled, let store = self.store else { return }
            do {
                let records = includeRecords ? try store.list(query: value, category: filter, pinnedOnly: pins) : []; let count = try store.count(); let backups = (try? store.migrationBackups().count) ?? self.migrationBackupCount
                DispatchQueue.main.async {
                    guard ticket == self.generation else { return }
                    if self.total != count { self.total = count }
                    if self.migrationBackupCount != backups { self.migrationBackupCount = backups }
                    self.searching = false
                    guard includeRecords, self.presentationActive else { return }
                    let previousItems = self.items
                    if self.items != records { self.items = records }
                    let id = records.contains(where:{ $0.id == self.selectedID }) ? self.selectedID : records.first?.id
                    let item = records.first { $0.id == id }
                    let priorItem = previousItems.first { $0.id == id }
                    if id != self.selectedID || self.detail?.item != item {
                        self.select(id, force: self.loadingDetail && priorItem != item)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard ticket == self.generation else { return }
                    self.searching = false
                    self.status = error.localizedDescription
                }
            }
        }
        pendingReload = task
        worker.async(execute: task)
        continueOCR()
    }
    func select(_ id: String?, force: Bool = false) {
        guard presentationActive else { return }
        if !force, id == selectedID {
            if loadingDetail || (detail != nil && detail?.item == items.first(where: { $0.id == id })) { return }
        }
        let changed = selectedID != id
        selectedID = id
        if changed { detail = nil; thumbnail = nil }
        detailRequest?.cancel()
        detailRequest = nil
        guard let id else { detail = nil; thumbnail = nil; loadingDetail = false; return }
        let request = ImageTextRecognitionWork()
        detailRequest = request
        loadingDetail = true
        let finish: (ClipDetail?, NSImage?) -> Void = { [weak self] record, image in
            DispatchQueue.main.async {
                guard let self, self.detailRequest === request else { return }
                self.detail = record; self.thumbnail = image; self.loadingDetail = false
            }
        }
        worker.async { [weak self] in
            guard let self, !request.cancelled else { return }
            do {
                guard let record = try self.store?.detail(id: id) else { finish(nil, nil); return }
                guard !request.cancelled else { return }
                let file = record.files.count == 1 ? record.files.first : nil
                guard record.item.kind == .image || file.map(Self.isImageFile) == true else {
                    finish(record, nil)
                    return
                }
                self.previewWorker.async {
                    guard !request.cancelled else { return }
                    let maximumPixelSize = 1536
                    let image: CGImage?
                    if let file {
                        image = Self.makeFileThumbnail(file, maximumPixelSize: maximumPixelSize, singleFrameOnly: true)
                    } else {
                        let source = record.assetURL.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
                            ?? Self.imageRepresentation(record).flatMap { CGImageSourceCreateWithData($0.data as CFData, nil) }
                        image = source.flatMap { Self.makeThumbnail($0, maximumPixelSize: maximumPixelSize) }
                    }
                    if !request.cancelled { finish(record, image.map { NSImage(cgImage: $0, size: .zero) }) }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.detailRequest === request else { return }
                    self.loadingDetail = false
                    self.status = error.localizedDescription
                }
            }
        }
    }
    func listThumbnail(for item: ClipItem) async -> NSImage? {
        let request = ImageTextRecognitionWork()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loadListThumbnail(for: item, request: request) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            request.cancel()
        }
    }

    func loadListThumbnail(for item: ClipItem, completion: @escaping (NSImage?) -> Void) {
        loadListThumbnail(for: item, request: ImageTextRecognitionWork(), completion: completion)
    }

    /// SQLite supplies the image reference; thumbnail decoding never occupies the storage queue.
    private func loadListThumbnail(for item: ClipItem, request: ImageTextRecognitionWork,
                                   completion: @escaping (NSImage?) -> Void) {
        guard let runtime, item.kind != .text, !runtime.cancelled, !request.cancelled else { completion(nil); return }
        let finish: (NSImage?) -> Void = { image in
            DispatchQueue.main.async { completion(request.cancelled || runtime.cancelled ? nil : image) }
        }
        let key = (item.id + (item.kind == .files ? ":" + String(item.copiedAt.timeIntervalSince1970) : "")) as NSString
        if let image = listThumbnailCache.object(forKey: key) { finish(image); return }
        worker.async { [weak self] in
            guard let self, let store = self.store, !runtime.cancelled, !request.cancelled else { finish(nil); return }
            let file: ClipFile?
            let imageSource: CGImageSource?
            if item.kind == .files {
                guard let detail = try? store.detail(id: item.id), detail.files.count == 1 else { finish(nil); return }
                file = detail.files.first
                imageSource = nil
            } else {
                file = nil
                let asset = item.assetName.flatMap(store.assetURL)
                if let source = asset.flatMap({ CGImageSourceCreateWithURL($0 as CFURL, nil) }) {
                    imageSource = source
                } else {
                    let detail = try? store.detail(id: item.id)
                    let bytes = detail?.snapshot?.items.lazy.flatMap(\.representations).first { representation in
                        ClipboardCapture.imageFormats.contains { $0.0 == representation.type }
                    }?.data
                    imageSource = bytes.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                }
            }
            self.listPreviewWorker.async {
                guard !runtime.cancelled, !request.cancelled else { finish(nil); return }
                if let cached = self.listThumbnailCache.object(forKey: key) { finish(cached); return }
                let cg = file.flatMap { Self.makeFileThumbnail($0, maximumPixelSize: 64) }
                    ?? imageSource.flatMap { Self.makeThumbnail($0, maximumPixelSize: 64) }
                guard let cg, !runtime.cancelled, !request.cancelled else { finish(nil); return }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.listThumbnailCache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
                finish(image)
            }
        }
    }

    private static func makeFileThumbnail(_ file: ClipFile, maximumPixelSize: Int, singleFrameOnly: Bool = false) -> CGImage? {
        let access = ClipboardFiles([file])
        return withExtendedLifetime(access) {
            guard let url = access.urls.first, isImagePath(url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  !singleFrameOnly || CGImageSourceGetCount(source) == 1 else { return nil }
            return makeThumbnail(source, maximumPixelSize: maximumPixelSize)
        }
    }

    private static func makeThumbnail(_ source: CGImageSource, maximumPixelSize: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary)
    }
    func move(_ delta: Int) {
        let current = items.firstIndex { $0.id == selectedID } ?? 0
        let index = NavigationBounds.move(current, by: delta, count: items.count)
        if items.indices.contains(index) { select(items[index].id) }
    }
    /// Opt-in local health report contains counts and states only, never pasteboard contents.
    private func recordMonitorHealth() {
        guard diagnosticsEnabled else { return }
        let report: [String:Any] = ["pollTicks":pollTicks,"capturedChanges":capturedChanges,"outcome":captureOutcome,"enabled":captureEnabled,"accessBehavior":board.accessBehavior.rawValue,"observedChangeCount":board.changeCount,"processedChangeCount":lastChange,"timerActive":timer?.isValid ?? false,"queryActive":!query.isEmpty,"pinnedOnly":pinnedOnly,"kind":kind]
        let destination = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Keylane/Diagnostics/clipboard-health.json")
        worker.async {
            var report = report; report["storageReady"] = self.store != nil
            try? FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            if let data = try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]) { try? data.write(to:destination,options:.atomic) }
        }
    }
    func poll() {
        guard let runtime else { return }
        pollTicks += 1
        defer { if pollTicks % 4 == 0 { recordMonitorHealth() } }
        if Date().timeIntervalSince(lastMaintenance) > 3600 { lastMaintenance = Date(); mutate { try $0.prune() } }
        guard captureEnabled else { return }
        let observation = board.changeCount
        if pendingClipboardRead?.generation != observation { pendingClipboardRead = nil }
        guard observation != lastChange || pendingClipboardRead != nil else { return }
        if let pending = pendingClipboardRead {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= pending.deadline {
                finishCapture(of: observation)
                captureOutcome = "read-timed-out"
                return
            }
            if now < pending.retryAfter { return }
        }
        if board.name == .general, board.accessBehavior != .alwaysAllow {
            captureOutcome = "access-denied"
            accessMessage = "后台采集需要持续访问剪贴板。请在系统设置中选择始终允许。"
            finishCapture(of: observation)
            return
        }
        guard let pasteboardItems = board.pasteboardItems else {
            if savesUniversalClipboardImmediately {
                deferCapture(of: observation, expectsRemote: false)
            } else {
                captureOutcome = "read-unavailable"
                accessMessage = "无法读取剪贴板，请检查系统授权。"
                finishCapture(of: observation, incomplete: true)
            }
            return
        }
        var types = pasteboardItems.flatMap { $0.types.map(\.rawValue) }
        if savesUniversalClipboardImmediately { types += board.types?.map(\.rawValue) ?? [] }
        let remote = types.contains(ClipboardCapture.remoteType)
        if pendingClipboardRead?.expectsRemote == true, !remote {
            deferCapture(of: observation, expectsRemote: true)
            return
        }
        let immediateRemote = remote && savesUniversalClipboardImmediately
        let front = NSWorkspace.shared.frontmostApplication
        let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")
        let source = types.contains(sourceType.rawValue) ? board.string(forType: sourceType) : nil
        guard !ClipboardPolicy.shouldSkip(types: types, source: source, frontmost: front?.bundleIdentifier, excluded: excludedApps) else {
            captureOutcome = "excluded"
            finishCapture(of: observation)
            return
        }
        guard pasteboardItems.count <= 128 else {
            finishCapture(of: observation)
            status = ClipboardError.oversized.localizedDescription
            return
        }
        let fileType = NSPasteboard.PasteboardType.fileURL.rawValue
        let hasFiles = types.contains(fileType)
        var transferredFiles: [URL] = []
        var items: [ClipSnapshotItem] = []
        if immediateRemote && hasFiles {
            guard let urls = ClipboardCapture.readUniversalFileURLs(from: board, items: pasteboardItems) else {
                deferCapture(of: observation, expectsRemote: true)
                return
            }
            transferredFiles = urls
        }
        var size = 0
        for item in transferredFiles.isEmpty ? pasteboardItems : [] {
            let candidates: AnySequence<ClipRepresentation>
            if immediateRemote {
                guard let available = ClipboardCapture.readUniversalItem(item) else {
                    deferCapture(of: observation, expectsRemote: true)
                    return
                }
                candidates = AnySequence(available)
            } else {
                candidates = AnySequence(item.types.lazy.compactMap { type in
                    guard ClipSnapshot.allowedTypes.contains(type.rawValue),
                          let data = item.data(forType: type), !data.isEmpty else { return nil }
                    return ClipRepresentation(type: type.rawValue, data: data)
                })
            }
            var representations: [ClipRepresentation] = []
            for representation in candidates {
                size += representation.data.count
                guard representation.data.count <= 16 * 1024 * 1024, size <= 32 * 1024 * 1024 else {
                    finishCapture(of: observation)
                    status = ClipboardError.oversized.localizedDescription
                    return
                }
                representations.append(representation)
            }
            if !representations.isEmpty { items.append(ClipSnapshotItem(representations)) }
        }
        let fileURLs = hasFiles && !immediateRemote ? ClipboardCapture.readFileURLs(from: board) : []
        let references: [ClipFile]? = fileURLs.isEmpty ? nil : fileURLs.map { url in
            ClipFile(path: url.path, bookmark: try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        guard board.changeCount == observation else { return }
        if !transferredFiles.isEmpty {
            currentUniversalFiles = (observation, transferredFiles.map(\.path))
        }
        if items.isEmpty && transferredFiles.isEmpty && immediateRemote {
            deferCapture(of: observation, expectsRemote: true)
            return
        }
        finishCapture(of: observation, incomplete: items.isEmpty && transferredFiles.isEmpty)
        accessMessage = ""
        guard !items.isEmpty || !transferredFiles.isEmpty else { captureOutcome = "unsupported"; status = "此内容没有可保存的文字、图片或文件格式。"; return }
        captureOutcome = "saving"
        let name = immediateRemote ? ClipboardCapture.universalSource : source.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { FileManager.default.displayName(atPath: $0.path) } ?? front?.localizedName ?? "未知来源"
        let bundle = immediateRemote ? "" : source ?? front?.bundleIdentifier ?? ""
        let snapshotItems = items; let files = references; let remoteFiles = transferredFiles
        worker.async { [weak self] in
            guard let self, !runtime.cancelled, let store = self.store else { return }
            do {
                let content: ClipContent
                if remoteFiles.isEmpty {
                    let (decoded, snapshot) = try ClipboardCapture.decode(snapshotItems, fileReferences: files)
                    guard !runtime.cancelled else { return }
                    _ = try store.capture(decoded, snapshot: snapshot, source: name, bundle: bundle)
                    content = decoded
                } else {
                    content = .files(try store.captureTransferredFiles(remoteFiles, source: name))
                }
                let mayContainImage: Bool
                switch content {
                case .image: mayContainImage = true
                case .files(let files): mayContainImage = files.count == 1 && files.first.map(Self.isImageFile) == true
                case .text: mayContainImage = false
                }
                DispatchQueue.main.async {
                    guard !runtime.cancelled else { return }
                    self.capturedChanges += 1
                    self.captureOutcome = "captured"
                    self.status = ""
                    if mayContainImage { self.ocrNeedsScan = true }
                    self.reload()
                }
            } catch {
                DispatchQueue.main.async {
                    guard !runtime.cancelled else { return }
                    self.captureOutcome = "save-failed"
                    self.status = error.localizedDescription
                }
            }
        }
    }
    func universalClipboardArrived(_ generation: Int) {
        guard captureEnabled, savesUniversalClipboardImmediately, runtime != nil,
              board.changeCount == generation, pendingClipboardRead?.generation != generation,
              lastChange != generation || lastIncompleteChange == generation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        pendingClipboardRead = PendingClipboardRead(generation: generation, deadline: now + 15,
                                                     retryAfter: now, expectsRemote: true)
        poll()
    }

    private func deferCapture(of generation: Int, expectsRemote: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = pendingClipboardRead
        pendingClipboardRead = PendingClipboardRead(generation: generation, deadline: previous?.deadline ?? now + 15,
                                                     retryAfter: now + 0.5, expectsRemote: expectsRemote || previous?.expectsRemote == true)
        captureOutcome = "waiting-for-clipboard"
    }

    private func finishCapture(of generation: Int, incomplete: Bool = false) {
        lastChange = generation
        lastIncompleteChange = incomplete ? generation : nil
        pendingClipboardRead = nil
    }

    private func mutate(_ action: @escaping (ClipboardStore) throws -> Void) {
        guard let runtime else { return }
        worker.async { [weak self] in
            guard let self, !runtime.cancelled, let store = self.store else { return }
            do {
                try action(store)
                DispatchQueue.main.async { if !runtime.cancelled { self.reload() } }
            } catch {
                DispatchQueue.main.async { if !runtime.cancelled { self.status = error.localizedDescription } }
            }
        }
    }
    private func updateLimits() { let limits = ClipboardLimits(maxItems: maxItems, retentionDays: retentionDays); mutate { $0.limits = limits; try $0.prune() } }
    func pinSelected() { guard let item = items.first(where: { $0.id == selectedID }) else { return }; mutate { try $0.setPinned(id: item.id, pinned: !item.pinned) } }
    func removeSelected() { guard let id = selectedID else { return }; mutate { try $0.remove(id: id) } }
    func clear(includePinned: Bool) { mutate { try $0.clear(includePinned: includePinned); if includePinned { try $0.removeMigrationBackups() } } }
    var selectedDetail: ClipDetail? { detail.flatMap { $0.item.id == selectedID ? $0 : nil } }

    func files(for detail: ClipDetail) -> ClipboardFiles {
        ClipboardFiles(detail.assetURL.map { [ClipFile(path: $0.path)] } ?? detail.files)
    }

    static func isImageFile(_ file: ClipFile) -> Bool {
        isImagePath(file.path)
    }

    private static func isImagePath(_ path: String) -> Bool {
        UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.conforms(to: .image) == true
    }

    private static func imageRepresentation(_ detail: ClipDetail) -> ClipRepresentation? {
        detail.snapshot?.items.lazy.flatMap(\.representations).first { representation in
            ClipboardCapture.imageFormats.contains { $0.0 == representation.type }
        }
    }

    func editSelectedText() {
        guard let detail = selectedDetail, detail.item.category.canEditText, !detail.text.isEmpty else { return }
        let textFormats: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text"]
        let hasOtherFormats = detail.snapshot.map {
            $0.items.count > 1 || !$0.formats.allSatisfy(textFormats.contains)
        } ?? false
        textDraft = .init(id: detail.item.id, text: detail.text, hasOtherFormats: hasOtherFormats)
    }

    func saveEditedText(id: String, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let runtime else { return }
        worker.async { [weak self] in
            guard let self, !runtime.cancelled else { return }
            let result = Result {
                guard let store = self.store else { throw ClipboardError.database }
                return try store.replaceText(id: id, with: text)
            }
            DispatchQueue.main.async {
                guard !runtime.cancelled else { return }
                if case .success(let newID) = result {
                    if self.selectedID == id, newID != id { self.select(newID) }
                    self.reload()
                }
                completion(result.map { _ in () })
            }
        }
    }
    private var sharingPicker: NSSharingServicePicker?

    func share(_ item: Any) {
        guard let view = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [item])
        sharingPicker = picker
        let anchor = CGRect(x: view.bounds.maxX - 30, y: view.bounds.minY + 30, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
    }

    func export(_ detail: ClipDetail, forAnnotation: Bool = false,
                completion: @escaping (Result<[URL], Error>) -> Void) {
        let files = files(for: detail)
        if detail.item.kind == .files, !files.isAvailable {
            completion(.failure(CocoaError(.fileReadNoSuchFile)))
            return
        }
        let panel: NSSavePanel
        if files.urls.count > 1 {
            let chooser = NSOpenPanel()
            chooser.canChooseDirectories = true
            chooser.canChooseFiles = false
            chooser.canCreateDirectories = true
            chooser.prompt = "保存到此处"
            panel = chooser
        } else {
            panel = NSSavePanel()
            panel.nameFieldStringValue = switch detail.item.kind {
            case .text: "剪贴板.txt"
            case .image: "剪贴板." + (detail.assetURL?.pathExtension ?? "png")
            case .files: files.urls.first?.lastPathComponent ?? "剪贴板文件"
            }
        }
        if forAnnotation {
            panel.title = "保存标注副本"
            panel.message = "选择副本的保存位置，随后会在「预览」中打开。"
        }
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result {
                    try Self.export(detail, files: files.urls, destination: destination)
                }
                DispatchQueue.main.async {
                    withExtendedLifetime(files) { completion(result) }
                }
            }
        }
    }

    private static func export(_ detail: ClipDetail, files: [URL], destination: URL) throws -> [URL] {
        let manager = FileManager.default
        switch detail.item.kind {
        case .text:
            try Data(detail.text.utf8).write(to: destination, options: .atomic)
            return [destination]
        case .image:
            guard let data = files.first.flatMap({ try? Data(contentsOf: $0) }) ?? imageRepresentation(detail)?.data else {
                throw ClipboardError.missingAttachment
            }
            if files.first?.resolvingSymlinksInPath() == destination.resolvingSymlinksInPath() {
                throw CocoaError(.fileWriteFileExists)
            }
            try data.write(to: destination, options: .atomic)
            return [destination]
        case .files:
            let targets = files.count == 1 ? [destination] : files.map { destination.appendingPathComponent($0.lastPathComponent) }
            guard Set(targets).count == targets.count else { throw CocoaError(.fileWriteFileExists) }
            var completed: [URL] = []
            do {
                for (source, target) in zip(files, targets) {
                    if files.count == 1, manager.fileExists(atPath: target.path) {
                        guard source.resolvingSymlinksInPath() != target.resolvingSymlinksInPath() else {
                            throw CocoaError(.fileWriteFileExists)
                        }
                        let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                      appropriateFor: target, create: true)
                        defer { try? manager.removeItem(at: scratch) }
                        let copy = scratch.appendingPathComponent(target.lastPathComponent)
                        try manager.copyItem(at: source, to: copy)
                        _ = try manager.replaceItemAt(target, withItemAt: copy)
                    } else {
                        try manager.copyItem(at: source, to: target)
                    }
                    completed.append(target)
                }
            } catch {
                if files.count > 1 { completed.forEach { try? manager.removeItem(at: $0) } }
                throw error
            }
            return targets
        }
    }

    func renameSelected() {
        guard let item = items.first(where: { $0.id == selectedID }), let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.messageText = "重命名记录"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(string: item.preview)
        field.frame.size.width = 280
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            self?.mutate { try $0.rename(id: item.id, to: name) }
        }
    }

    func confirmHistoryRemoval(recent: Bool) {
        let alert = NSAlert()
        alert.messageText = recent ? "删除过去一小时内未置顶的记录？" : "删除全部剪贴板记录？"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        guard let window = NSApp.keyWindow else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            if recent {
                let cutoff = Date().addingTimeInterval(-3600)
                self?.mutate { try $0.removeRecent(since: cutoff) }
            } else {
                self?.clear(includePinned: true)
            }
        }
    }

    @discardableResult func copySelected(plainText: Bool = false) -> Bool {
        copySelected(format: plainText ? .plainText : .original)
    }

    func replayFormat(_ format: ClipboardReplayFormat, for detail: ClipDetail?) -> ClipboardReplayFormat {
        guard format == .preferred else { return format }
        guard prefersPlainText, let detail, detail.item.kind == .text, !plainText(of: detail).isEmpty else { return .original }
        if let snapshot = detail.snapshot {
            let textTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text", "public.rtf",
                                          "com.apple.flat-rtfd", "public.html", "public.url"]
            guard snapshot.items.count == 1, Set(snapshot.formats).isSubset(of: textTypes) else { return .original }
        }
        return .plainText
    }

    func recordReplay(of id: String?) {
        guard updatesHistoryAfterReplay, let id else { return }
        let date = Date()
        mutate { try $0.recordReplay(id: id, at: date) }
    }

    private func plainText(of detail: ClipDetail) -> String {
        if let text = detail.snapshot?.plainText, !text.isEmpty { return text }
        // Snapshot-backed PDF and RTFD records may use a display label as their stored text.
        if detail.snapshot == nil, !detail.text.isEmpty { return detail.text }
        if !detail.ocrText.isEmpty { return detail.ocrText }
        return detail.files.map(\.path).joined(separator: "\n")
    }

    var availableReplayFormats: [ClipboardReplayFormat] {
        guard let detail = selectedDetail else { return [] }
        var formats: [ClipboardReplayFormat] = plainText(of: detail).isEmpty ? [] : [.plainText]
        if let items = detail.snapshot?.items, let first = items.first {
            let common = items.dropFirst().reduce(Set(first.representations.map(\.type))) { types, item in
                types.intersection(item.representations.map(\.type))
            }
            let types = common.subtracting(["public.utf8-plain-text", "public.utf16-plain-text", "public.file-url"])
            formats += types.sorted().map { .representation($0) }
            if detail.item.kind == .image, common.contains(UTType.tiff.identifier), !common.contains(UTType.png.identifier) {
                formats.append(.pngFromTIFF)
            }
        } else if detail.item.kind == .image, detail.assetURL?.pathExtension.lowercased() == "tiff" {
            formats.append(.pngFromTIFF)
        }
        return formats
    }

    @discardableResult func copySelected(format requested: ClipboardReplayFormat) -> Bool {
        guard runtime != nil else { return false }
        guard !searching, !loadingDetail else { status = "内容正在加载，请稍后重试。"; return false }
        guard let detail = selectedDetail else { status = "请先选择记录并等待内容加载。"; return false }
        let format = replayFormat(requested, for: detail)
        if format == .plainText {
            let text = plainText(of: detail)
            guard !text.isEmpty else { status = "这条记录没有可复制的文字。"; return false }
            return copyText(text)
        }
        if format != .original { return copyRepresentations(format, from: detail) }
        if detail.files.contains(where: { $0.isSystemTransferReference == true }),
           let transfer = currentUniversalFiles, transfer.generation == board.changeCount,
           transfer.paths == detail.files.map(\.path) {
            // Rewriting the URL would drop the system's original file access grant.
            status = ""
            return true
        }
        var accessed: [URL] = []
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let objects: [NSPasteboardWriting]
        if let snapshot = detail.snapshot {
            var resolved: [String:URL] = [:]
            for reference in detail.files {
                var url = URL(fileURLWithPath:reference.path)
                if let bookmark = reference.bookmark { var stale = false; if let fresh = try? URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],bookmarkDataIsStale:&stale) { url = fresh } }
                if url.startAccessingSecurityScopedResource() { accessed.append(url) }
                if reference.isSystemTransferReference == true {
                    do {
                        let input = try FileHandle(forReadingFrom: url)
                        try input.close()
                    } catch {
                        status = "请在原设备重新复制此文件，再粘贴。"
                        return false
                    }
                } else if !FileManager.default.fileExists(atPath: url.path) {
                    status = "原文件已移走或删除，未修改当前剪贴板。"
                    return false
                }
                resolved[reference.path] = url
            }
            objects = snapshot.items.enumerated().map { index, captured -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for representation in captured.representations {
                    if representation.type == "public.file-url", let value = ClipboardCapture.string(representation.data,type:representation.type), let old = URL(string:value), let fresh = resolved[old.path] { item.setString(fresh.absoluteString,forType:.fileURL) }
                    else { item.setData(representation.data,forType:.init(representation.type)) }
                }
                if index == 0 { item.setString("1",forType:.init("org.keylane.clipboard.replay")) }
                return item
            }
        } else { switch detail.item.kind {
        case .text: objects = [detail.text as NSString]
        case .image:
            guard let url = detail.assetURL, let data = try? Data(contentsOf: url), data.count <= 16 * 1024 * 1024 else { status = ClipboardError.missingAttachment.localizedDescription; return false }
            let item = NSPasteboardItem(); let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.png"
            item.setData(data, forType: .init(type)); objects = [item]
        case .files:
            let urls = detail.files.map { reference -> URL in
                if let bookmark = reference.bookmark { var stale = false; if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) { return url } }
                return URL(fileURLWithPath: reference.path)
            }
            accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
            guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { status = "部分原文件已移走或删除，未修改当前剪贴板。"; return false }
            objects = urls.map { $0 as NSURL }
        }
        }
        return writeToPasteboard(objects, markLegacyReplay: detail.snapshot == nil)
    }

    private func copyRepresentations(_ format: ClipboardReplayFormat, from detail: ClipDetail) -> Bool {
        let sourceType: String
        let outputType: String
        switch format {
        case .representation(let type):
            sourceType = type
            outputType = type
        case .pngFromTIFF:
            sourceType = UTType.tiff.identifier
            outputType = UTType.png.identifier
        default:
            return false
        }
        let representations: [Data]
        if let snapshot = detail.snapshot {
            representations = snapshot.items.compactMap { item in
                item.representations.first { $0.type == sourceType }?.data
            }
            guard !representations.isEmpty, representations.count == snapshot.items.count else {
                status = "并非每个项目都提供所选格式。"
                return false
            }
        } else if format == .pngFromTIFF, let url = detail.assetURL, url.pathExtension.lowercased() == "tiff",
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 16 * 1024 * 1024 {
            representations = [data]
        } else {
            status = "此记录没有所选格式。"
            return false
        }
        var totalBytes = 0
        var items: [NSPasteboardItem] = []
        for data in representations {
            let output = format == .pngFromTIFF ? Self.png(fromTIFF: data) : data
            guard let output, output.count <= 16 * 1024 * 1024,
                  totalBytes + output.count <= 32 * 1024 * 1024 else {
                status = "无法转换图片，或转换后的图片超出大小限制。"
                return false
            }
            totalBytes += output.count
            let item = NSPasteboardItem()
            item.setData(output, forType: .init(outputType))
            if items.isEmpty { item.setString("1", forType: .init("org.keylane.clipboard.replay")) }
            items.append(item)
        }
        return writeToPasteboard(items)
    }

    private static func png(fromTIFF data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == UTType.tiff.identifier as CFString,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 24_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    func placeholderHistory(offset: Int, current: String?) -> String? {
        guard captureEnabled, runtime != nil else { return nil }
        return worker.sync { try? store?.recentText(offset: offset, current: current) }
    }

    func copyColor(_ color: ClipboardColor, as format: ClipboardColor.Format) -> Bool {
        copyText(color.formatted(as: format))
    }

    private func copyText(_ text: String) -> Bool {
        guard runtime != nil else { return false }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("1", forType: .init("org.keylane.clipboard.replay"))
        return writeToPasteboard([item])
    }

    private func writeToPasteboard(_ objects: [NSPasteboardWriting], markLegacyReplay: Bool = false) -> Bool {
        board.clearContents()
        guard board.writeObjects(objects) else { status = "无法写入剪贴板，请重试。"; return false }
        if markLegacyReplay { board.setString("1", forType: .init("org.keylane.clipboard.replay")) }
        finishCapture(of: board.changeCount)
        status = ""
        return true
    }

    func copyImageText(_ mode: ImageTextRecognition, from detail: ClipDetail,
                       completion: @escaping (Bool, String) -> Void) {
        if mode == .ocr, !detail.ocrText.isEmpty {
            let copied = copyText(detail.ocrText)
            completion(copied, copied ? "已复制图片文字" : status)
            return
        }
        guard let runtime else { return }
        let changeCount = board.changeCount
        let accurate = accurateOCR
        ocrWorker.async { [weak self] in
            guard let self, !runtime.cancelled else { return }
            let result = Result {
                try self.recognizedText(from: detail, mode: mode, accurate: accurate, runtime: runtime)
            }
            DispatchQueue.main.async {
                guard !runtime.cancelled else { return }
                switch result {
                case .success(let text) where !text.isEmpty:
                    if mode == .ocr {
                        self.mutate { store in
                            try store.setOCR(id: detail.item.id, text: text, fileCopiedAt: detail.item.copiedAt)
                        }
                    }
                    guard self.board.changeCount == changeCount else {
                        completion(false, "剪贴板内容已变化，请重新执行复制。")
                        return
                    }
                    let copied = self.copyText(text)
                    let message = mode == .qr ? "已复制二维码文本" : "已复制图片文字"
                    completion(copied, copied ? message : self.status)
                case .success: completion(false, mode.emptyMessage)
                case .failure(let error): completion(false, error.localizedDescription)
                }
            }
        }
    }

    private static func imageRequest(for detail: ClipDetail, file: URL?) throws -> VNImageRequestHandler {
        if let file, FileManager.default.fileExists(atPath: file.path) { return VNImageRequestHandler(url: file) }
        if let representation = imageRepresentation(detail) { return VNImageRequestHandler(data: representation.data) }
        throw ClipboardError.missingAttachment
    }

    private func recognizedText(from detail: ClipDetail, mode: ImageTextRecognition, accurate: Bool, runtime: ImageTextRecognitionWork) throws -> String {
        let files = files(for: detail)
        return try withExtendedLifetime(files) {
            let handler = try Self.imageRequest(for: detail, file: files.urls.first)
            return try mode.recognize(in: handler, accurate: accurate, work: runtime)
        }
    }

    private func requestOCRScan() {
        ocrNeedsScan = true
        continueOCR()
    }

    private func continueOCR() {
        guard let runtime else { return }
        let searchingImages = presentationActive && ["all", "image", "files"].contains(kind)
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWork = ocrRunning || ocrNeedsScan || !ocrPending.isEmpty
        let showProgress = searchingImages && hasWork
        if indexingImageText != showProgress { indexingImageText = showProgress }
        guard automaticOCR || searchingImages, !ocrRunning, hasWork else { return }
        ocrRunning = true
        if ocrNeedsScan {
            ocrNeedsScan = false
            worker.async { [weak self] in
                guard let self, !runtime.cancelled else { return }
                let result = Result {
                    try (self.store?.pendingOCR() ?? []).filter { $0.filePath.map(Self.isImagePath) ?? true }
                }
                DispatchQueue.main.async {
                    guard !runtime.cancelled else { return }
                    self.ocrRunning = false
                    switch result {
                    case .success(let candidates):
                        let remaining = Set(candidates.map(\.id))
                        self.ocrAttempts = self.ocrAttempts.filter { remaining.contains($0.key) }
                        self.ocrPending = candidates.filter { candidate in
                            self.ocrAttempts[candidate.id] != candidate.copiedAt
                        }[...]
                    case .failure(let error):
                        self.ocrPending = []
                        self.status = error.localizedDescription
                    }
                    self.continueOCR()
                }
            }
        } else {
            let batch = Array(ocrPending.prefix(3))
            ocrPending = ocrPending.dropFirst(batch.count)
            let accurate = accurateOCR
            ocrWorker.async { [weak self] in
                guard let self, !runtime.cancelled else { return }
                var updated = false
                for candidate in batch where !runtime.cancelled {
                    let indexed = autoreleasepool { self.indexImageText(candidate, accurate: accurate, runtime: runtime) }
                    updated = updated || indexed
                }
                let needsReload = updated
                DispatchQueue.main.async {
                    guard !runtime.cancelled else { return }
                    for candidate in batch { self.ocrAttempts[candidate.id] = candidate.copiedAt }
                    self.ocrRunning = false
                    if needsReload && self.presentationActive { self.reload() }
                    else { self.continueOCR() }
                }
            }
        }
    }

    /// Vision stays off the storage queue. Only the bounded read and write run on that queue.
    private func indexImageText(_ candidate: ClipboardOCRCandidate, accurate: Bool, runtime: ImageTextRecognitionWork) -> Bool {
        do {
            guard let detail = try worker.sync(execute: { try store?.detail(id: candidate.id) }),
                  !detail.item.hasOCR, detail.item.copiedAt == candidate.copiedAt else { return false }
            let text = try recognizedText(from: detail, mode: .ocr, accurate: accurate, runtime: runtime)
            guard !text.isEmpty else { return false }
            return try worker.sync {
                guard !runtime.cancelled else { return false }
                return try store?.setOCR(id: candidate.id, text: text, fileCopiedAt: candidate.copiedAt) ?? false
            }
        } catch { return false }
    }

    func addExcludedApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { excludedApps.insert(id) } } }
    }
}
