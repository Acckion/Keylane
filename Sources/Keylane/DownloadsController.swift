import AppKit
import Combine
import KeylaneCore

final class DownloadsController: ObservableObject {
    @Published private(set) var files: [IncomingFile] = []
    @Published var selectedID: String?
    @Published var query = "" { didSet { reconcileSelection() } }
    @Published private(set) var operationError = ""
    @Published private(set) var scanError = ""
    var error: String { [operationError, scanError].filter { !$0.isEmpty }.joined(separator: "\n") }
    @Published private(set) var folder: ScreenshotScope?
    @Published var autoShelf: Bool { didSet { defaults.set(autoShelf, forKey: "downloads.autoShelf"); tracker.reset(); refresh() } }
    private let defaults: UserDefaults
    private let watcher = FolderChangeWatcher()
    private var enabled = false
    private var task: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var needsRefresh = false
    private var tracker = IncomingFileTracker()
    private var revision = 0
    private var access: URL?
    var addToShelf: (([URL]) -> Bool)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folder = defaults.data(forKey: "downloads.folder").flatMap { try? JSONDecoder().decode(ScreenshotScope.self, from: $0) }
        autoShelf = defaults.bool(forKey: "downloads.autoShelf")
    }
    var authorized: Bool { folder?.accessibleURL != nil }
    var results: [IncomingFile] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        return files.filter { file in words.allSatisfy { file.url.lastPathComponent.lowercased().contains($0) } }
    }
    var selected: IncomingFile? { results.first { $0.id == selectedID } }
    func move(_ offset: Int) {
        let values = results
        guard !values.isEmpty else { selectedID = nil; return }
        let index = values.firstIndex { $0.id == selectedID } ?? 0
        selectedID = values[min(max(0, index + offset), values.count - 1)].id
    }
    private func reconcileSelection() { if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id } }
    func chooseFolder(_ finish: @escaping (Bool) -> Void = { _ in }) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = folder?.accessibleURL ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "选择下载文件夹。Keylane 只管理此文件夹第一层的文件，不读取浏览器下载记录。"
        panel.prompt = "授权此文件夹"
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { finish(false); return }
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            do {
                _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                let scope = ScreenshotScope(path: url.path, bookmark: bookmark)
                self.defaults.set(try JSONEncoder().encode(scope), forKey: "downloads.folder")
                self.folder = scope; self.tracker.reset(); self.operationError = ""
                if self.enabled { self.configure() }
                finish(true)
            } catch { self.operationError = error.localizedDescription; finish(false) }
        }
        if let window = NSApp.keyWindow {
            guard window.attachedSheet == nil else { finish(false); return }
            panel.beginSheetModal(for: window, completionHandler: complete)
        } else { panel.begin(completionHandler: complete) }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; configure()
    }
    private func configure() {
        revision += 1; task?.cancel(); task = nil; needsRefresh = false
        retry?.cancel(); retry = nil; watcher.stop(); tracker.reset()
        if let access { access.stopAccessingSecurityScopedResource(); self.access = nil }
        files = []; selectedID = nil
        guard enabled, let url = folder?.accessibleURL else { return }
        if url.startAccessingSecurityScopedResource() { access = url }
        watcher.changed = { [weak self] _ in self?.refresh() }
        watcher.start(roots: [url.path]); refresh()
    }
    func refresh() {
        guard enabled, let url = folder?.accessibleURL else { return }
        guard task == nil else { needsRefresh = true; return }
        retry?.cancel(); retry = nil
        let ticket = revision
        task = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .utility) { () -> Result<[IncomingFile], Error> in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return Result { try IncomingFiles.scan(url) }
            }.value
            guard let self, !Task.isCancelled, self.revision == ticket, self.enabled else { return }
            self.task = nil
            switch outcome {
            case .success(let snapshot):
                self.scanError = ""; self.files = snapshot; self.reconcileSelection()
                let ready = self.tracker.update(snapshot)
                if self.autoShelf, !ready.isEmpty {
                    // Directories are browsable but their recursive contents may still be downloading.
                    let urls = ready.filter { !$0.directory }.map(\.url)
                    if !urls.isEmpty, self.addToShelf?(urls) != true { self.scanError = "自动加入失败，请先启用暂存架。文件仍保留在下载目录。" }
                }
                if self.tracker.needsRescan {
                    self.retry = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .milliseconds(2100)) } catch { return }
                        self?.refresh()
                    }
                }
            case .failure(let error): self.scanError = "无法读取下载文件夹：" + error.localizedDescription
            }
            if self.needsRefresh { self.needsRefresh = false; self.refresh() }
        }
    }
    func withSelected(_ action: (URL) throws -> Void) {
        guard let file = selected, let root = folder?.accessibleURL else { return }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        do {
            guard file.url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                  try file.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: file.url.path) else { throw CocoaError(.fileNoSuchFile) }
            try action(file.url)
        } catch { self.operationError = error.localizedDescription; refresh() }
    }
    func prepareFileDrag(id: String, completion: @escaping (ResultFileDragPayload?) -> Void) {
        guard enabled, let file = results.first(where: { $0.id == id }), let root = folder?.accessibleURL else { completion(nil); return }
        do {
            guard file.url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                  try file.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            completion(try ResultFileDragPayload(urls: [file.url], scopes: [root]))
        } catch { operationError = error.localizedDescription; completion(nil) }
    }
    func dismissOperationError() { operationError = "" }
    func sendSelectedToShelf() { withSelected { url in
        guard addToShelf?([url]) == true else { throw NSError(domain: "Keylane.Downloads", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先启用暂存架。下载文件未改动。"]) }
    } }
    func openSelected() { withSelected { url in
        guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
        (NSApp.delegate as? Delegate)?.hideLauncher()
    } }
}
