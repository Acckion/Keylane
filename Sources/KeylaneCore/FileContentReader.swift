import Foundation
import Darwin
import PDFKit

/// Bounded, serial-worker extraction. Opens each path component without following
/// user symlinks and reads from one descriptor; never hydrates a dataless file.
public enum FileContentReader {
    public enum Failure: Error { case unavailable, changed, cancelled }
    private static let extensions: Set<String> = ["pdf", "txt", "md", "csv", "tsv", "json", "swift", "js", "ts", "py", "html", "css", "xml", "yaml", "yml", "log"]
    public static func supports(_ path: String) -> Bool {
        extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
    public static func read(_ job: FileSearchIndex.ContentJob, cancelled: () -> Bool = { false }) throws -> String {
        func check() throws { if cancelled() { throw Failure.cancelled } }
        try check()
        let path = LocalFilePath.systemCanonical(job.path)
        guard FileSearchLocation.contains(path, in: LocalFilePath.systemCanonical(job.root)), supports(path) else { return "" }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { close(fd) }
        let names = path.split(separator: "/")
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
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true { return "" }
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
        if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" {
            var collected = ""
            if let document = PDFDocument(data: data) {
                for index in 0..<document.pageCount {
                    try check()
                    guard collected.count < 100_000 else { break }
                    if index > 0 { collected += "\n" }
                    collected += String((document.page(at: index)?.string ?? "").prefix(100_000 - collected.count))
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
