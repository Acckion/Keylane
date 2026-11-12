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
                self.configure(roots: self.roots, excluded: self.excluded, customDepth: self.customDepth)
            }
        }
        // Watch the nearest existing ancestor so a newly created user Applications folder is discovered.
        let watchPaths = Set(roots.map { path -> String in
            var url = URL(fileURLWithPath: path)
            while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
            return url.path
        })
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
            guard let info else { return }
            let owner = Unmanaged<ApplicationDiscovery>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            if changed.contains(where: { path in owner.roots.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") } }) { owner.refresh() }
        }, &context, Array(watchPaths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.7, FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { failed?("文件变化监听启动失败，可手动刷新应用列表。") }
        } else { failed?("无法监听应用目录，可手动刷新。") }
        refresh()
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
        roots = []; excluded = []
        for observer in mountObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        mountObservers.removeAll()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }
}
