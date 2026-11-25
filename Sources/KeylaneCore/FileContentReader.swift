import Foundation
import Darwin
import PDFKit

/// Bounded, serial-worker extraction. Opens each path component without following
/// user symlinks and reads from one descriptor; skips dataless file bodies.
public enum FileContentReader {
    public enum Failure: Error { case unavailable, changed, unproved, cancelled }
    private static let extensions: Set<String> = ["pdf", "txt", "md", "csv", "tsv", "json", "swift", "js", "ts", "py", "html", "css", "xml", "yaml", "yml", "log"]
    public static func supports(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
    public static func read(_ job: FileSearchIndex.ContentJob, cancelled: () -> Bool = { false }) throws -> String {
        try Session().read(job, cancelled: cancelled)
    }

    struct Proof: Codable, Equatable, Sendable {
        let root: Identity
        let file: Identity
        let bytes, modifiedSeconds, modifiedNanos, changedSeconds, changedNanos: Int64

        init(root: Identity, file: stat) {
            self.root = root
            self.file = Identity(file)
            bytes = Int64(file.st_size)
            modifiedSeconds = Int64(file.st_mtimespec.tv_sec); modifiedNanos = Int64(file.st_mtimespec.tv_nsec)
            changedSeconds = Int64(file.st_ctimespec.tv_sec); changedNanos = Int64(file.st_ctimespec.tv_nsec)
        }
    }

    struct Identity: Codable, Equatable, Sendable {
        let device, bornSeconds, bornNanos: Int64
        let inode: UInt64
        var isKnown: Bool { inode > 0 && bornSeconds > 0 }
        init(_ info: stat) {
            device = Int64(info.st_dev); inode = UInt64(info.st_ino)
            bornSeconds = Int64(info.st_birthtimespec.tv_sec); bornNanos = Int64(info.st_birthtimespec.tv_nsec)
        }
    }

    /// Confined to one worker batch. Pins at most eight roots and releases all
    /// descriptors when the batch ends; no global directory cache is retained.
    public final class Session {
        private final class Root {
            let path: String
            let fd: Int32
            let identity: Identity
            init(path: String, fd: Int32, identity: Identity) { self.path = path; self.fd = fd; self.identity = identity }
            deinit { close(fd) }
        }
        private var roots: [String: Root] = [:]
        public init() {}

        private static func matchesPath(_ fd: Int32, _ path: String) -> Bool {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            return fcntl(fd, F_GETPATH, &buffer) == 0 && LocalFilePath.systemCanonical(String(cString: buffer)) == path
        }

        private func root(_ configured: String, cancelled: () -> Bool) throws -> Root {
            if let root = roots[configured] {
                guard Self.matchesPath(root.fd, root.path) else { throw Failure.changed }
                return root
            }
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
                var info = stat()
                guard fstat(fd, &info) == 0, Self.matchesPath(fd, path),
                      info.st_flags & UInt32(SF_DATALESS) == 0 else { throw Failure.unavailable }
                let identity = Identity(info)
                guard identity.isKnown else { throw Failure.unproved }
                let root = Root(path: path, fd: fd, identity: identity)
                if roots.count == 8, let key = roots.keys.first { roots.removeValue(forKey: key) }
                roots[configured] = root
                return root
            } catch { close(fd); throw error }
        }

        /// Pin the scanner's authorized directory before enumerating its metadata.
        @discardableResult public func pinScope(_ path: String, cancelled: () -> Bool = { false }) -> Bool {
            guard Self.valid(path) else { return false }
            return (try? root(path, cancelled: cancelled)) != nil
        }

        private static func valid(_ path: String) -> Bool {
            path.hasPrefix("/") && !path.contains("\0") &&
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }

        private func withEntry<T>(path: String, owner: String, expectedRoot: Identity? = nil, cancelled: () -> Bool,
                                  _ visit: (Root, Int32, String, String, stat) throws -> T) throws -> T {
            guard !cancelled(), Self.valid(path), Self.valid(owner), supports(path) else { throw Failure.unavailable }
            let root = try root(owner, cancelled: cancelled)
            guard expectedRoot.map({ $0 == root.identity }) != false else { throw Failure.changed }
            let path = LocalFilePath.systemCanonical(path)
            guard FileSearchLocation.contains(path, in: root.path), path != root.path else { throw Failure.changed }
            let suffix = path.dropFirst(root.path == "/" ? 0 : root.path.count).split(separator: "/")
            guard let leaf = suffix.last.map(String.init) else { throw Failure.unavailable }
            var fd = fcntl(root.fd, F_DUPFD_CLOEXEC, 0)
            guard fd >= 0 else { throw Failure.unavailable }
            defer { close(fd) }
            for name in suffix.dropLast() {
                if cancelled() { throw Failure.cancelled }
                var info = stat()
                guard fstatat(fd, String(name), &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR,
                      Int64(info.st_dev) == root.identity.device, info.st_flags & UInt32(SF_DATALESS) == 0
                      else { throw Failure.unavailable }
                let next = openat(fd, String(name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard next >= 0 else { throw Failure.unavailable }
                var current = stat()
                guard fstat(next, &current) == 0, Identity(current) == Identity(info) else { close(next); throw Failure.changed }
                close(fd); fd = next
            }
            var info = stat()
            guard !cancelled(), fstatat(fd, leaf, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
                  Int64(info.st_dev) == root.identity.device, Self.matchesPath(root.fd, root.path),
                  Self.matchesPath(fd, (path as NSString).deletingLastPathComponent)
                  else { throw Failure.changed }
            return try visit(root, fd, leaf, path, info)
        }

        func certify(path: String, owner: String, modified: Double, cancelled: () -> Bool) -> Proof? {
            try? withEntry(path: path, owner: owner, cancelled: cancelled) { root, _, _, _, info in
                let proof = Proof(root: root.identity, file: info)
                guard proof.file.isKnown, abs(Double(proof.modifiedSeconds) + Double(proof.modifiedNanos) / 1e9 - modified) < 0.001
                    else { throw Failure.changed }
                return proof
            }
        }

        /// Only exact current scope policy can authorize the initial byte read and
        /// the final result; a stopped generation never uses ambient access.
        public func read(_ job: FileSearchIndex.ContentJob, cancelled: () -> Bool = { false },
                         allows: () -> Bool = { true }, externalVolumes: Bool = true,
                         extraction: (() throws -> String)? = nil) throws -> String {
            func check() throws { if cancelled() { throw Failure.cancelled } }
            let proof = job.proof
            guard let proof, proof.file.isKnown, proof.root.isKnown else { throw Failure.unproved }
            return try withEntry(path: job.path, owner: job.root, expectedRoot: proof.root, cancelled: cancelled) { root, parent, leaf, path, entry in
                guard Proof(root: root.identity, file: entry) == proof else { throw Failure.changed }
                try check()
                guard allows() else { throw Failure.unproved }
                try check()
                // For ordinary local files Foundation may omit the iCloud
                // key. Require positively known local regular-file metadata
                // and no provider signal; a failed/unknown classification
                // never falls back to opening the file.
                if entry.st_flags & UInt32(SF_DATALESS) != 0 || entry.st_size > 2_097_152 { return "" }
                let url = URL(fileURLWithPath: path, isDirectory: false)
                var keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .volumeIsLocalKey, .isRegularFileKey]
                if !externalVolumes { keys.formUnion([.volumeIsInternalKey, .volumeIsRemovableKey]) }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.volumeIsLocal == true, values.isRegularFile == true,
                      externalVolumes || (values.volumeIsInternal == true && values.volumeIsRemovable == false)
                    else { throw Failure.unproved }
                let components = url.pathComponents
                let managedPath = zip(components, components.dropFirst()).contains {
                    $0 == "Library" && ($1 == "Mobile Documents" || $1 == "CloudStorage")
                }
                if values.isUbiquitousItem == true || values.ubiquitousItemDownloadingStatus != nil ||
                    managedPath || FileManager.default.isUbiquitousItem(at: url) { return "" }
                var current = stat()
                guard fstatat(parent, leaf, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      current.st_flags & UInt32(SF_DATALESS) == 0, Proof(root: root.identity, file: current) == proof,
                      Self.matchesPath(root.fd, root.path) else { throw Failure.changed }
                try check()
                let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw Failure.unavailable }
                defer { close(fd) }
                var before = stat()
                guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                      before.st_flags & UInt32(SF_DATALESS) == 0, Proof(root: root.identity, file: before) == proof,
                      Self.matchesPath(fd, path), Self.matchesPath(root.fd, root.path)
                      else { throw Failure.changed }
                let text: String
                if let extraction { text = try extraction() }
                else { text = try Self.body(fd: fd, path: path, check: check) }
                try check()
                guard allows() else { throw Failure.unproved }
                try check()
                var after = stat(), named = stat()
                guard fstat(fd, &after) == 0, after.st_flags & UInt32(SF_DATALESS) == 0,
                      fstatat(parent, leaf, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      Proof(root: root.identity, file: after) == proof, Proof(root: root.identity, file: named) == proof,
                      Self.matchesPath(fd, path), Self.matchesPath(root.fd, root.path) else { throw Failure.changed }
                return text
            }
        }

        private static func body(fd: Int32, path: String, check: () throws -> Void) throws -> String {
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
            return text
        }
    }
}
