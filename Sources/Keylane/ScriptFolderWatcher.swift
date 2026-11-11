import CoreServices
import Darwin
import Foundation
import KeylaneCore

/// Delivers recursive changes on the main queue, including replacement of a configured root.
final class ScriptFolderWatcher {
    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    var changed: ((_ rebuildWatch: Bool) -> Void)?
    var isWatching: Bool { stream != nil }

    deinit { stop() }

    func start(roots: [String]) {
        stop()
        guard !roots.isEmpty else { return }
        // FSEvents reports physical paths such as /private/tmp, even when
        // Foundation uses /tmp for the configured folder and its command IDs.
        let locations = roots.map { path -> (watch: String, root: String) in
            var directory = URL(fileURLWithPath: path, isDirectory: true)
            var suffix: [String] = []
            var isDirectory: ObjCBool = false
            while directory.path != "/",
                  !FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                suffix.append(directory.lastPathComponent)
                directory.deleteLastPathComponent()
            }
            let physicalPath: String
            if let resolved = realpath(directory.path, nil) {
                physicalPath = String(cString: resolved)
                free(resolved)
            } else {
                physicalPath = directory.path
            }
            let root = suffix.reversed().reduce(URL(fileURLWithPath: physicalPath, isDirectory: true)) {
                $0.appendingPathComponent($1, isDirectory: true)
            }
            return (physicalPath, root.path)
        }
        self.roots = locations.map(\.root)
        let watchPaths = Set(locations.map(\.watch))
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ScriptFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            watcher.handle(paths: paths, flags: UnsafeBufferPointer(start: flags, count: count))
        }, &context, Array(watchPaths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
           0.7, FSEventStreamCreateFlags(flags)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func handle(paths: [String], flags: UnsafeBufferPointer<FSEventStreamEventFlags>) {
        let recovery = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                                               kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        if flags.contains(where: { $0 & recovery != 0 }) {
            changed?(true)
            return
        }
        let replacement = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated |
                                                  kFSEventStreamEventFlagItemRemoved |
                                                  kFSEventStreamEventFlagItemRenamed)
        var shouldScan = false
        for (path, event) in zip(paths, flags) {
            let eventPrefix = path == "/" ? "/" : path + "/"
            if event & replacement != 0, roots.contains(where: { $0 == path || $0.hasPrefix(eventPrefix) }) {
                changed?(true)
                return
            }
            let isDirectory = event & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            if !shouldScan, roots.contains(where: { includes(path, in: $0, isDirectory: isDirectory) }) {
                shouldScan = true
            }
        }
        if shouldScan { changed?(false) }
    }

    private func includes(_ path: String, in root: String, isDirectory: Bool) -> Bool {
        if path == root { return true }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return false }
        let components = path.dropFirst(prefix.count).split(separator: "/")
        let directories = isDirectory ? components[...] : components.dropLast()
        return components.last?.hasPrefix(".") != true
            && !directories.contains { ScriptCommand.ignoresDiscoveryDirectory(named: String($0)) }
    }
}
