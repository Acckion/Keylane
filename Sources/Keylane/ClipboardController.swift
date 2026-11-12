import AppKit
import Combine
import ImageIO
import Vision
import UniformTypeIdentifiers
import KeylaneCore

private final class ClipboardPreviewRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

/// Pasteboard reads and published state belong to the main thread. SQLite belongs
/// exclusively to worker; OCR never blocks that queue or resurrects deleted rows.
final class ClipboardController: ObservableObject {
    @Published var captureEnabled: Bool {
        didSet {
            preferences.set(captureEnabled, forKey: "clipboardPersistentCapture")
            lastChange = board.changeCount
            updateCaptureTimer()
        }
    }
    @Published var primaryAction: String { didSet { preferences.set(primaryAction,forKey:"clipboardPrimaryAction") } }
    @Published var automaticOCR: Bool { didSet { preferences.set(automaticOCR, forKey: "clipboardAutomaticOCR") } }
    @Published var accurateOCR: Bool { didSet { preferences.set(accurateOCR, forKey: "clipboardAccurateOCR") } }
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
    @Published private(set) var accessMessage = ""
    @Published var kind: String = "all" { didSet { reload() } }
    @Published var pinnedOnly = false { didSet { reload() } }
    private let board: NSPasteboard
    private let preferences: UserDefaults
    private let worker = DispatchQueue(label: "org.keylane.clipboard.storage", qos: .utility)
    private let previewWorker = DispatchQueue(label: "org.keylane.clipboard.preview", qos: .userInitiated)
    private let listPreviewWorker = DispatchQueue(label: "org.keylane.clipboard.list-preview", qos: .utility)
    private let ocrWorker = DispatchQueue(label: "org.keylane.clipboard.ocr", qos: .utility)
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
    private var query = ""
    private var generation = 0
    private var pendingSearch: DispatchWorkItem?
    private var pendingReload: DispatchWorkItem?
    private var detailRequest: ClipboardPreviewRequest?
    private var presentationActive: Bool
    private var lastMaintenance = Date()
    private var recognizing: Set<String> = []
    init(directory: URL? = nil, board: NSPasteboard = .general, preferences: UserDefaults = .standard, startTimer: Bool = true, presentationActive: Bool = true) {
        self.presentationActive = presentationActive
        self.board = board; self.preferences = preferences; lastChange = board.changeCount
        // The old memory-only opt-in does not silently become permission to persist.
        captureEnabled = preferences.bool(forKey: "clipboardPersistentCapture")
        primaryAction = preferences.string(forKey:"clipboardPrimaryAction") ?? "copy"
        automaticOCR = preferences.bool(forKey: "clipboardAutomaticOCR")
        accurateOCR = preferences.object(forKey: "clipboardAccurateOCR") as? Bool ?? true
        historyCommandEnabled = preferences.object(forKey: "clipboardHistoryCommandEnabled") as? Bool ?? true
        retentionDays = preferences.object(forKey: "clipboardRetentionDays") as? Int ?? 30
        maxItems = preferences.object(forKey: "clipboardMaxItems") as? Int ?? 500
        excludedApps = Set(preferences.stringArray(forKey: "clipboardExcludedApps") ?? []).union(ClipboardPolicy.defaultExcluded)
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Keylane/Clipboard", isDirectory: true)
        let limits = ClipboardLimits(maxItems: maxItems, retentionDays: retentionDays)
        worker.async { [weak self] in
            guard let self else { return }
            do { self.store = try ClipboardStore(directory: root, limits: limits); try self.store?.prune(); DispatchQueue.main.async { self.reload() } }
            catch { self.report(error) }
        }
        if startTimer { startMonitoring() }
        recordMonitorHealth()
    }

    func startMonitoring() {
        monitoringRequested = true
        updateCaptureTimer()
    }

    func stopMonitoring() {
        monitoringRequested = false
        updateCaptureTimer()
    }

    private func updateCaptureTimer() {
        guard monitoringRequested && captureEnabled else {
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
    deinit { timer?.invalidate(); detailRequest?.cancel(); pendingReload?.cancel() }
    private func report(_ error: Error) { DispatchQueue.main.async { self.status = error.localizedDescription } }
    func feedback(_ text: String) { status = text }
    func search(_ value: String) {
        presentationActive = true
        query = value; searching = true; pendingSearch?.cancel(); pendingReload?.cancel(); generation += 1
        let work = DispatchWorkItem { [weak self] in self?.reload() }; pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.06,execute:work)
    }
    /// Closing the page ends preview work; capture and storage remain independent.
    func endPresentation() {
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
        generation += 1; let ticket = generation; let value = query; let filter = ClipKind(rawValue: kind); let pins = pinnedOnly
        let includeRecords = presentationActive
        pendingReload?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let records = includeRecords ? try store.list(query: value, kind: filter, pinnedOnly: pins) : []; let count = try store.count(); let backups = (try? store.migrationBackups().count) ?? self.migrationBackupCount
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
        let request = ClipboardPreviewRequest()
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
                let record = try self.store?.detail(id: id)
                guard !request.cancelled else { return }
                let asset = record?.assetURL
                let data = record?.snapshot?.items.lazy.flatMap(\.representations)
                    .first(where: { representation in ClipboardCapture.imageFormats.contains { $0.0 == representation.type } })?.data
                guard asset != nil || data != nil else { finish(record, nil); return }
                self.previewWorker.async {
                    guard !request.cancelled else { return }
                    let source = asset.flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
                        ?? data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
                    let image = source.flatMap {
                        CGImageSourceCreateThumbnailAtIndex($0, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 640,
                            kCGImageSourceCreateThumbnailWithTransform: true
                        ] as CFDictionary)
                    }.map { NSImage(cgImage: $0, size: .zero) }
                    if !request.cancelled { finish(record, image) }
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
        let request = ClipboardPreviewRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                loadListThumbnail(for: item, request: request) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            request.cancel()
        }
    }

    func loadListThumbnail(for item: ClipItem, completion: @escaping (NSImage?) -> Void) {
        loadListThumbnail(for: item, request: ClipboardPreviewRequest(), completion: completion)
    }

    /// SQLite supplies the image reference; thumbnail decoding never occupies the storage queue.
    private func loadListThumbnail(for item: ClipItem, request: ClipboardPreviewRequest,
                                   completion: @escaping (NSImage?) -> Void) {
        guard item.kind != .text, !request.cancelled else { completion(nil); return }
        let finish: (NSImage?) -> Void = { image in
            DispatchQueue.main.async { completion(request.cancelled ? nil : image) }
        }
        let key = (item.id + (item.kind == .files ? ":" + String(item.copiedAt.timeIntervalSince1970) : "")) as NSString
        if let image = listThumbnailCache.object(forKey: key) { finish(image); return }
        worker.async { [weak self] in
            guard let self, let store = self.store, !request.cancelled else { finish(nil); return }
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
                guard !request.cancelled else { finish(nil); return }
                if let cached = self.listThumbnailCache.object(forKey: key) { finish(cached); return }
                let cg = file.flatMap(Self.makeFileListThumbnail) ?? imageSource.flatMap(Self.makeListThumbnail)
                guard let cg, !request.cancelled else { finish(nil); return }
                let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.listThumbnailCache.setObject(image, forKey: key, cost: cg.bytesPerRow * cg.height)
                finish(image)
            }
        }
    }

    private static func makeFileListThumbnail(_ file: ClipFile) -> CGImage? {
        var url = URL(fileURLWithPath: file.path)
        if let bookmark = file.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                       relativeTo: nil, bookmarkDataIsStale: &stale) { url = resolved }
        }
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(makeListThumbnail)
    }

    private static func makeListThumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
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
        pollTicks += 1
        defer { if pollTicks % 4 == 0 { recordMonitorHealth() } }
        if Date().timeIntervalSince(lastMaintenance) > 3600 { lastMaintenance = Date(); mutate { try $0.prune() } }
        guard captureEnabled, board.changeCount != lastChange else { return }
        let observation = board.changeCount
        if board.name == NSPasteboard.general.name, board.accessBehavior != .alwaysAllow {
            captureOutcome = "access-denied"; accessMessage = "后台采集需要持续访问剪贴板。请在系统设置中选择始终允许。"; lastChange = observation; return
        }
        guard let pasteboardItems = board.pasteboardItems else { captureOutcome = "read-unavailable"; accessMessage = "无法读取剪贴板，请检查系统授权。"; lastChange = observation; return }
        let types = pasteboardItems.flatMap { $0.types.map(\.rawValue) }
        let front = NSWorkspace.shared.frontmostApplication
        let source = board.string(forType:.init("org.nspasteboard.source"))
        guard !ClipboardPolicy.shouldSkip(types:types,source:source,frontmost:front?.bundleIdentifier,excluded:excludedApps) else { captureOutcome = "excluded"; lastChange = observation; return }
        guard pasteboardItems.count <= 128 else { lastChange = observation; status = ClipboardError.oversized.localizedDescription; return }
        var items: [ClipSnapshotItem] = []; var size = 0
        for item in pasteboardItems {
            var representations: [ClipRepresentation] = []
            for type in item.types where ClipSnapshot.allowedTypes.contains(type.rawValue) {
                if let data = item.data(forType:type), !data.isEmpty {
                    size += data.count
                    guard data.count <= 16 * 1024 * 1024, size <= 32 * 1024 * 1024 else { lastChange = observation; status = ClipboardError.oversized.localizedDescription; return }
                    representations.append(ClipRepresentation(type:type.rawValue,data:data))
                }
            }
            if !representations.isEmpty { items.append(ClipSnapshotItem(representations)) }
        }
        var references: [ClipFile]?
        if types.contains("public.file-url"), let urls = board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] {
            references = urls.map { ClipFile(path:$0.path,bookmark:try? $0.bookmarkData(options:[.withSecurityScope,.securityScopeAllowOnlyReadAccess],includingResourceValuesForKeys:nil,relativeTo:nil)) }
        }
        guard board.changeCount == observation else { return }
        lastChange = observation; accessMessage = ""
        guard !items.isEmpty else { captureOutcome = "unsupported"; status = "此内容没有可保存的文字、图片或文件格式。"; return }
        captureOutcome = "saving"
        let name = source.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0) }.map { FileManager.default.displayName(atPath:$0.path) } ?? front?.localizedName ?? "未知来源"
        let bundle = source ?? front?.bundleIdentifier ?? ""; let ocr = automaticOCR
        let snapshotItems = items; let files = references
        worker.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let (content,snapshot) = try ClipboardCapture.decode(snapshotItems,fileReferences:files)
                let id = try store.capture(content,snapshot:snapshot,source:name,bundle:bundle)
                DispatchQueue.main.async { self.capturedChanges += 1; self.captureOutcome = "captured"; self.status = ""; self.reload(); if ocr && content.kind == .image { self.recognize(id) } }
            } catch { DispatchQueue.main.async { self.captureOutcome = "save-failed" }; self.report(error) }
        }
    }
    private func mutate(_ action: @escaping (ClipboardStore) throws -> Void) {
        worker.async { [weak self] in
            guard let self, let store = self.store else { return }
            do { try action(store); DispatchQueue.main.async { self.reload() } } catch { self.report(error) }
        }
    }
    private func updateLimits() { let limits = ClipboardLimits(maxItems: maxItems, retentionDays: retentionDays); mutate { $0.limits = limits; try $0.prune() } }
    func pinSelected() { guard let item = items.first(where: { $0.id == selectedID }) else { return }; mutate { try $0.setPinned(id: item.id, pinned: !item.pinned) } }
    func removeSelected() { guard let id = selectedID else { return }; mutate { try $0.remove(id: id) } }
    func clear(includePinned: Bool) { mutate { try $0.clear(includePinned: includePinned); if includePinned { try $0.removeMigrationBackups() } } }
    @discardableResult func copySelected(plainText: Bool = false) -> Bool {
        guard !searching, !loadingDetail else { status = "内容正在加载，请稍后重试。"; return false }
        guard let detail, detail.item.id == selectedID else { status = "请先选择记录并等待内容加载。"; return false }
        var accessed: [URL] = []
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let objects: [NSPasteboardWriting]
        if plainText {
            let text = detail.snapshot.map { !$0.plainText.isEmpty ? $0.plainText : (!detail.ocrText.isEmpty ? detail.ocrText : detail.files.map(\.path).joined(separator:"\n")) } ?? (!detail.text.isEmpty ? detail.text : (!detail.ocrText.isEmpty ? detail.ocrText : detail.files.map(\.path).joined(separator:"\n")))
            guard !text.isEmpty else { status = "这条记录没有可复制的文字；可先识别图片文字。"; return false }
            let item = NSPasteboardItem(); item.setString(text,forType:.string); item.setString("1",forType:.init("org.keylane.clipboard.replay")); objects = [item]
        } else if let snapshot = detail.snapshot {
            var resolved: [String:URL] = [:]
            for reference in detail.files {
                var url = URL(fileURLWithPath:reference.path)
                if let bookmark = reference.bookmark { var stale = false; if let fresh = try? URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],bookmarkDataIsStale:&stale) { url = fresh } }
                if url.startAccessingSecurityScopedResource() { accessed.append(url) }
                guard FileManager.default.fileExists(atPath:url.path) else { status = "原文件已移走或删除，未修改当前剪贴板。"; return false }
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
        board.clearContents()
        guard board.writeObjects(objects) else { status = "无法写入剪贴板，请重试。"; return false }
        if detail.snapshot == nil && !plainText { board.setString("1",forType:.init("org.keylane.clipboard.replay")) }; lastChange = board.changeCount
        status = ""
        return true
    }
    func recognizeSelected() { if let id = selectedID { recognize(id) } }
    private func recognize(_ id: String) {
        guard recognizing.count < 5, recognizing.insert(id).inserted else { return }
        let level: VNRequestTextRecognitionLevel = accurateOCR ? .accurate : .fast
        status = "正在识别图片文字…"
        worker.async { [weak self] in
            guard let self else { return }
            do {
                guard let detail = try self.store?.detail(id: id), let url = detail.assetURL else { DispatchQueue.main.async { self.recognizing.remove(id); self.status = "图片记录已删除。" }; return }
                self.ocrWorker.async {
                    defer { DispatchQueue.main.async { self.recognizing.remove(id) } }
                    do {
                        let request = VNRecognizeTextRequest(); request.recognitionLevel = level; request.automaticallyDetectsLanguage = true
                        let supported = try request.supportedRecognitionLanguages()
                        request.recognitionLanguages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
                        try VNImageRequestHandler(url: url).perform([request])
                        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                        self.mutate { try $0.setOCR(id: id, text: text) }
                        DispatchQueue.main.async { self.status = text.isEmpty ? "未识别到文字" : "图片文字已加入搜索"; if self.selectedID == id { self.select(id,force:true) } }
                    } catch { self.report(error) }
                }
            } catch { DispatchQueue.main.async { self.recognizing.remove(id) }; self.report(error) }
        }
    }
    func addExcludedApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { for url in panel.urls { if let id = Bundle(url: url)?.bundleIdentifier { excludedApps.insert(id) } } }
    }
}
