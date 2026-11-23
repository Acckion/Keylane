import Foundation
import Darwin
import PDFKit

/// Bounded, serial-worker extraction. Opens each path component without following
/// user symlinks and reads from one descriptor; skips dataless file bodies.
public enum FileContentReader {
    public enum Failure: Error { case unavailable, changed, cancelled }
    private static let extensions: Set<String> = ["pdf", "txt", "md", "csv", "tsv", "json", "swift", "js", "ts", "py", "html", "css", "xml", "yaml", "yml", "log"]
    public static func supports(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
    public static func read(_ job: FileSearchIndex.ContentJob, cancelled: () -> Bool = { false }) throws -> String {
        try Session().read(job, cancelled: cancelled)
    }

    /// Confined to one worker batch. Pins at most eight roots and releases all
    /// descriptors when the batch ends; no global directory cache is retained.
    public final class Session {
        private final class Root {
            let path: String
            let fd: Int32
            init(path: String, fd: Int32) { self.path = path; self.fd = fd }
            deinit { close(fd) }
        }
        private var roots: [String: Root] = [:]
        public init() {}
        private func root(_ configured: String, cancelled: () -> Bool) throws -> Root {
            if let root = roots[configured] { return root }
            let path = LocalFilePath.systemCanonical(configured)
            var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { throw Failure.unavailable }
            do {
                for name in path.split(separator: "/") {
                    if cancelled() { throw Failure.cancelled }
                    let next = openat(fd, String(name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                    guard next >= 0 else { throw Failure.unavailable }
                    close(fd); fd = next
                }
            } catch { close(fd); throw error }
            let root = Root(path: path, fd: fd)
            if roots.count == 8, let key = roots.keys.first { roots.removeValue(forKey: key) }
            roots[configured] = root
            return root
        }
        public func read(_ job: FileSearchIndex.ContentJob, cancelled: () -> Bool = { false }) throws -> String {
            func check() throws { if cancelled() { throw Failure.cancelled } }
            try check()
            guard job.path.hasPrefix("/"), job.root.hasPrefix("/"), !job.path.contains("\0"), !job.root.contains("\0"), supports(job.path) else { return "" }
            let root = try root(job.root, cancelled: cancelled)
            let path = LocalFilePath.systemCanonical(job.path)
            guard FileSearchLocation.contains(path, in: root.path), supports(path) else { return "" }
            var rootPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(root.fd, F_GETPATH, &rootPath) == 0, String(cString: rootPath) == root.path else { throw Failure.changed }
            var fd = fcntl(root.fd, F_DUPFD_CLOEXEC, 0)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { close(fd) }
            let names = path.dropFirst(root.path == "/" ? 0 : root.path.count).split(separator: "/")
            guard !names.isEmpty else { throw Failure.unavailable }
            for (offset, name) in names.enumerated() {
                try check()
                var info = stat()
                guard fstatat(fd, String(name), &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unavailable }
                if info.st_flags & UInt32(SF_DATALESS) != 0 { return "" }
                let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (offset == names.count - 1 ? 0 : O_DIRECTORY)
                let next = openat(fd, String(name), flags)
                guard next >= 0 else { throw Failure.unavailable }
                close(fd); fd = next
            }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw Failure.unavailable }
            guard abs(Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1e9 - job.modified) < 0.001 else { throw Failure.changed }
            guard before.st_size <= 2_097_152, before.st_flags & UInt32(SF_DATALESS) == 0 else { return "" }
            // Retain the previous policy of excluding iCloud-managed bodies.
            if (try? URL(fileURLWithPath: path, isDirectory: false).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true { return "" }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try check()
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 { if errno == EINTR { continue }; throw Failure.unavailable }
                if count == 0 { break }
                guard data.count + count <= 2_097_152 else { return "" }
                data.append(contentsOf: buffer.prefix(count))
            }
            let text: String
            if (path as NSString).pathExtension.lowercased() == "pdf" {
                var collected = ""
                var characters = 0
                if let document = PDFDocument(data: data) {
                    for index in 0..<document.pageCount {
                        try check()
                        guard characters < 100_000 else { break }
                        if index > 0 { collected += "\n"; characters += 1 }
                        let fragment = String((document.page(at: index)?.string ?? "").prefix(100_000 - characters))
                        collected += fragment; characters += fragment.count
                    }
                }
                text = collected
            } else { text = String((String(data: data, encoding: .utf8) ?? "").prefix(100_000)) }
            try check()
            var after = stat()
            guard fstat(fd, &after) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.changed }
            var currentPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &currentPath) == 0, LocalFilePath.systemCanonical(String(cString: currentPath)) == path else { throw Failure.changed }
            return text
        }
    }
}
