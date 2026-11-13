import AppKit
import Foundation
import CoreServices
import KeylaneCore

/// Recursive filesystem notifications; all state changes occur on the main queue.
final class ApplicationDiscovery {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var scanRequest: DispatchWorkItem?
    private var generation = 0
    private var roots: [String] = []
    private var watchedRoots: Set<String> = []
    private var watchGeneration = 0
    private var watchPaths: Set<String> = []
    private var mountObservers: [NSObjectProtocol] = []
    private var customDepth: Int?
    private var excluded: Set<String> = []
    var updated: (([CatalogApplication], Double) -> Void)?
    var failed: ((String) -> Void)?
    deinit { stop() }
    func configure(roots: [String], excluded: Set<String>, customDepth: Int? = nil) {
        stop()
        self.roots = roots
        self.excluded = excluded
        self.customDepth = customDepth
        guard !roots.isEmpty else { updated?([], 0); return }
        let notifications = NSWorkspace.shared.notificationCenter
        mountObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.startWatching(force: true)
                self.refresh()
            }
        }
        startWatching()
        refresh()
    }

    private func startWatching(force: Bool = false) {
        guard !roots.isEmpty else { return }
        var directories = Set<String>()
        var relevant = Set<String>()
        for root in roots {
            let original = URL(fileURLWithPath: root).standardizedFileURL
            let originalParent = original.deletingLastPathComponent().resolvingSymlinksInPath()
            let originalPath = originalParent.appendingPathComponent(original.lastPathComponent).path
            let resolved = original.resolvingSymlinksInPath()
            relevant.formUnion([original.path, originalPath, resolved.path].map(Self.normalizedPath))
            directories.insert(Self.existingDirectory(for: resolved))
            if originalPath != resolved.path {
                // Watch the link's parent so removing or replacing the link also refreshes discovery.
                directories.insert(Self.existingDirectory(for: originalParent))
            }
        }
        watchedRoots = relevant
        guard force || directories != watchPaths || stream == nil else { return }
        stopWatching()
        watchPaths = directories

        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let owner = Unmanaged<ApplicationDiscovery>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            owner.directoriesChanged(changed, flags: UnsafeBufferPointer(start: flags, count: count))
        }, &context, Array(directories) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.7, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
                failed?("文件变化监听启动失败，可手动刷新应用列表。")
            }
        } else { failed?("无法监听应用目录，可手动刷新。") }
    }

    private func directoriesChanged(_ paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
        let recovery = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        let rootChanged = flags.contains { $0 & recovery != 0 }
        let changed = paths.map(Self.normalizedPath)
        if rootChanged || changed.contains(where: watchedRoots.contains) {
            // Do not replace the stream from within its callback.
            let version = watchGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.watchGeneration == version else { return }
                self.startWatching(force: rootChanged)
                self.refresh()
            }
        } else if changed.contains(where: isRelevantChange)
                    || flags.contains(where: { $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 }) {
            refresh()
        }
    }

    private static func existingDirectory(for path: URL) -> String {
        var url = path
        while url.path != "/" {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { break }
            url.deleteLastPathComponent()
        }
        return url.resolvingSymlinksInPath().path
    }

    private static func normalizedPath(_ path: String) -> String {
        // Foundation may shorten system temporary paths to /tmp, while
        // FSEvents reports /private/tmp, including for already removed items.
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        if path == "/tmp" || path.hasPrefix("/tmp/") { return "/private" + path }
        return path
    }

    private func isRelevantChange(_ path: String) -> Bool {
        return watchedRoots.contains {
            path == $0 || $0 == "/" || path == "/" || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/")
        }
    }

    private func stopWatching() {
        watchGeneration += 1
        watchPaths = []
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    func refresh() {
        guard !roots.isEmpty else { return }
        generation += 1; let version = generation; pending?.cancel()
        scanRequest?.cancel()
        let request = DispatchWorkItem {}
        scanRequest = request
        let paths = roots; let excluded = excluded; let customDepth = customDepth; let started = Date()
        let task = DispatchWorkItem { [weak self] in
            let apps = ApplicationCatalog.scan(roots: paths, excluded: excluded, customDepth: customDepth, isCancelled: { request.isCancelled })
            DispatchQueue.main.async { guard let self, self.generation == version else { return }; self.updated?(apps, Date().timeIntervalSince(started)) }
        }
        pending = task; DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now()+0.25, execute: task)
    }
    func stop() {
        generation += 1; pending?.cancel(); pending = nil
        scanRequest?.cancel(); scanRequest = nil
        roots = []; excluded = []; watchedRoots = []
        for observer in mountObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        mountObservers.removeAll()
        stopWatching()
    }
}
