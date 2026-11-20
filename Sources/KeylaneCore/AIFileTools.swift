import Foundation
import CryptoKit
import Darwin

public struct AIFileToolScope: Codable, Identifiable, Equatable, Sendable {
    public let path: String
    public let bookmark: Data?
    public var id: String { path }
    public init(path: String, bookmark: Data? = nil) { self.path = path; self.bookmark = bookmark }
}

/// Revoking an access generation also invalidates already-advertised and in-flight tools.
public final class AIFileAccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public func revoke() { lock.lock(); valid = false; lock.unlock() }
    public func check() throws {
        lock.lock(); let allowed = valid; lock.unlock()
        guard allowed else { throw CancellationError() }
        try Task.checkCancellation()
    }
}

public enum AIFileToolError: LocalizedError {
    case outsideScope, unavailable, unsupported, stale, exists, invalidPath, invalidText, ambiguousEdit, tooLarge
    public var errorDescription: String? {
        switch self {
        case .outsideScope: "路径不在 AI 已授权目录内。请在 AI 设置中添加目录，或选择已授权的项目工作目录。"
        case .unavailable: "目录授权已失效或文件不可访问，请重新选择目录。"
        case .unsupported: "仅支持普通 UTF-8 文本文件与目录；不跟随符号链接，不读取设备、管道或二进制文件。"
        case .stale: "文件已变化。请重新读取，使用新的 revision 后再修改。"
        case .exists: "目标已存在，未覆盖。替换文件需要明确的 replace 模式及当前 revision。"
        case .invalidPath: "文件路径或搜索参数无效。"
        case .invalidText: "内容不是有效 UTF-8 文本，或 offset 不在字符边界；请使用上次返回的 next_offset。"
        case .ambiguousEdit: "待替换文本不存在或匹配多处；请提供唯一文本，或明确指定 replace_all。"
        case .tooLarge: "超过本次文件操作的数据限制，请缩小范围或分段读取。"
        }
    }
}

/// All filesystem IO runs on this actor, never the main actor. No shell or index is started.
public actor AIFileToolService {
    public init() {}
    private final class FD {
        let raw: Int32
        init(_ raw: Int32) throws { guard raw >= 0 else { throw AIFileToolError.unavailable }; self.raw = raw }
        deinit { Darwin.close(raw) }
    }
    private struct Target { let parent: FD; let name: String; let path: String }
    private struct Scan { var visited = 0; var bytes = 0; var truncated = false; var exhausted = false }

    public static func isSensitive(_ path: String) -> Bool {
        let components = path.lowercased().split(separator: "/").map(String.init)
        return components.contains { name in
            [".ssh", ".aws", ".gnupg", ".git", ".config", "keychains", ".codex", ".claude", "safari", "chrome", "firefox", "cookies", "login data", "local state", "auth.json", "credentials.json", "secrets.json"].contains(name) ||
            name == ".env" || name.hasPrefix(".env.") || [".pem", ".key", ".p12", ".pfx"].contains { name.hasSuffix($0) }
        }
    }

    public func execute(_ tool: String, arguments: [String: AIToolValue], scopes: [AIFileToolScope],
                        check: @Sendable () throws -> Void = { try Task.checkCancellation() }) throws -> AIToolResult {
        try check()
        var accessed: [URL] = []
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let roots = scopes.map { Self.systemPath($0.path) }
        guard let defaultRoot = roots.first else { throw AIFileToolError.outsideScope }
        let path = try normalized(string(arguments, "path"), defaultRoot: defaultRoot)
        let matches = scopes.filter { scope in
            let root = Self.systemPath(scope.path)
            return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
        }
        guard let scope = matches.max(by: { $0.path.count < $1.path.count }) else { throw AIFileToolError.outsideScope }
        let original = URL(fileURLWithPath: Self.systemPath(scope.path))
        var url = original
        if let bookmark = scope.bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
                Self.systemPath(resolved.path) == original.path else { throw AIFileToolError.unavailable }
            url = resolved
        }
        if url.startAccessingSecurityScopedResource() { accessed.append(url) }
        let target = try target(path, roots: roots, check: check)
        switch tool {
        case "keylane_read_file":
            let fd = try openFile(target)
            let info = try status(fd.raw)
            if isDirectory(info) { return try directory(fd, path: path, arguments: arguments, check: check) }
            guard isRegular(info) else { throw AIFileToolError.unsupported }
            let offset = integer(arguments, "offset", default: 0)
            let limit = integer(arguments, "limit", default: 4096)
            guard offset >= 0, (1...4096).contains(limit) else { throw AIFileToolError.invalidPath }
            var data = try read(fd.raw, offset: offset, count: limit, check: check)
            var text = String(data: data, encoding: .utf8)
            for _ in 0..<3 where text == nil && !data.isEmpty { data.removeLast(); text = String(data: data, encoding: .utf8) }
            guard let text, !hasBinaryControls(text), data.count > 0 || offset >= info.st_size else { throw AIFileToolError.invalidText }
            guard revision(try status(fd.raw)) == revision(info) else { throw AIFileToolError.stale }
            let next = offset + data.count
            return try output(["path": .string(path), "type": .string("file"), "text": .string(text),
                "revision": .string(revision(info)), "offset": .number(Double(offset)),
                "next_offset": next < info.st_size ? .number(Double(next)) : .null, "truncated": .bool(next < info.st_size)])
        case "keylane_file_info":
            var info = stat()
            guard fstatat(target.parent.raw, target.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw AIFileToolError.unavailable }
            return try output(metadata(info, path: path))
        case "keylane_glob", "keylane_grep":
            let fd = try openFile(target)
            guard isDirectory(try status(fd.raw)) else { throw AIFileToolError.unsupported }
            let pattern = string(arguments, "pattern")
            guard !pattern.isEmpty, pattern.utf8.count <= 256,
                  !pattern.split(separator: "/").contains(".."), !pattern.hasPrefix("/") else { throw AIFileToolError.invalidPath }
            let limit = integer(arguments, "limit", default: 50)
            let depth = integer(arguments, "depth", default: 6)
            guard (1...100).contains(limit), (1...12).contains(depth) else { throw AIFileToolError.invalidPath }
            if tool == "keylane_grep" && string(arguments, "query").isEmpty { throw AIFileToolError.invalidPath }
            var scan = Scan(), rows: [AIToolValue] = []
            try walk(fd, path: path, relative: "", pattern: pattern, needle: string(arguments, "query"),
                grep: tool == "keylane_grep", depth: depth, limit: limit,
                hidden: boolean(arguments, "include_hidden"), scan: &scan, rows: &rows, check: check)
            return try output(["path": .string(path), "matches": .array(rows), "visited": .number(Double(scan.visited)), "truncated": .bool(scan.truncated)])
        case "keylane_write_file", "keylane_edit_file":
            guard target.name != "." else { throw AIFileToolError.invalidPath }
            var contents = string(arguments, "content")
            let replacing = tool == "keylane_edit_file" || string(arguments, "mode") == "replace"
            let expected = string(arguments, "expected_revision")
            if tool == "keylane_edit_file" {
                let fd = try openFile(target); let info = try status(fd.raw)
                guard isRegular(info), info.st_size <= 1_048_576 else { throw AIFileToolError.tooLarge }
                guard expected == revision(info) else { throw AIFileToolError.stale }
                let data = try read(fd.raw, offset: 0, count: Int(info.st_size), check: check)
                guard let original = String(data: data, encoding: .utf8), !hasBinaryControls(original) else { throw AIFileToolError.invalidText }
                let old = string(arguments, "old_text"), new = string(arguments, "new_text")
                guard !old.isEmpty else { throw AIFileToolError.ambiguousEdit }
                let occurrences = original.components(separatedBy: old).count - 1
                guard occurrences > 0, occurrences == 1 || boolean(arguments, "replace_all") else { throw AIFileToolError.ambiguousEdit }
                contents = original.replacingOccurrences(of: old, with: new)
            }
            guard contents.utf8.count <= 1_048_576, !hasBinaryControls(contents) else { throw AIFileToolError.tooLarge }
            let info = try write(Data(contents.utf8), target: target, replacing: replacing, expected: expected, check: check)
            return try output(metadata(info, path: path).merging(["written": .bool(true)]) { _, new in new })
        case "keylane_create_directory":
            guard target.name != "." else { throw AIFileToolError.exists }
            try check()
            guard mkdirat(target.parent.raw, target.name, 0o700) == 0 else {
                if errno == EEXIST { throw AIFileToolError.exists }; throw AIFileToolError.unavailable
            }
            return try output(["path": .string(path), "created": .bool(true)])
        default: throw AIToolContractError.unavailable
        }
    }

    // Foundation standardization shortens /private/var to /var on macOS. Resolve only
    // these OS aliases; never resolve user-controlled links inside an approved scope.
    public static func systemPath(_ path: String) -> String {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where lexical == alias || lexical.hasPrefix(alias + "/") {
            guard let pointer = realpath(alias, nil) else { return lexical }
            defer { free(pointer) }
            return String(cString: pointer) + lexical.dropFirst(alias.count)
        }
        return lexical
    }

    private func normalized(_ path: String, defaultRoot: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0") else { throw AIFileToolError.invalidPath }
        let expanded: String
        if path == "~" || path.hasPrefix("~/") { expanded = (path as NSString).expandingTildeInPath }
        else if path.hasPrefix("/") { expanded = path }
        else { expanded = defaultRoot + "/" + path }
        return Self.systemPath(expanded)
    }
    private func target(_ path: String, roots: [String], check: () throws -> Void) throws -> Target {
        guard let root = roots.filter({ path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }).max(by: { $0.count < $1.count }) else { throw AIFileToolError.outsideScope }
        var fd = try FD(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        let relative = path == root ? [] : path.dropFirst(root == "/" ? 1 : root.count + 1).split(separator: "/").map(String.init)
        for component in root.split(separator: "/").map(String.init) + relative.dropLast() {
            try check()
            fd = try FD(openat(fd.raw, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        }
        return Target(parent: fd, name: relative.last ?? ".", path: path)
    }
    private func openFile(_ target: Target) throws -> FD {
        let raw = openat(target.parent.raw, target.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard raw >= 0 else { throw AIFileToolError.unsupported }
        return try FD(raw)
    }
    private func status(_ fd: Int32) throws -> stat {
        var info = stat(); guard fstat(fd, &info) == 0 else { throw AIFileToolError.unavailable }; return info
    }
    private func isDirectory(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFDIR }
    private func isRegular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }
    private func revision(_ info: stat) -> String {
        let value = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_mode)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func metadata(_ info: stat, path: String) -> [String: AIToolValue] {
        ["path": .string(path), "type": .string(isDirectory(info) ? "directory" : isRegular(info) ? "file" : "other"),
         "size": .number(Double(info.st_size)), "modified": .string(Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)).ISO8601Format()),
         "revision": .string(revision(info))]
    }
    private func read(_ fd: Int32, offset: Int, count: Int, check: () throws -> Void) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 16_384))
        while data.count < count {
            try check()
            let size = min(buffer.count, count - data.count)
            let n = pread(fd, &buffer, size, off_t(offset + data.count))
            guard n >= 0 else { throw AIFileToolError.unavailable }
            if n == 0 { break }; data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
    private func names(_ fd: Int32, scan: inout Scan, check: () throws -> Void) throws -> [String] {
        // A fresh directory stream avoids sharing offsets with the held descriptor.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard copy >= 0 else { throw AIFileToolError.unavailable }
        guard let stream = fdopendir(copy) else { Darwin.close(copy); throw AIFileToolError.unavailable }
        defer { closedir(stream) }
        var values: [String] = []
        while let entry = readdir(stream) {
            try check()
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard scan.visited < 10_000 else { scan.truncated = true; scan.exhausted = true; break }
            scan.visited += 1; values.append(name)
        }
        return values.sorted()
    }
    private func directory(_ fd: FD, path: String, arguments: [String: AIToolValue], check: () throws -> Void) throws -> AIToolResult {
        let offset = integer(arguments, "offset", default: 0), limit = integer(arguments, "limit", default: 50)
        guard offset >= 0, (1...100).contains(limit) else { throw AIFileToolError.invalidPath }
        var scan = Scan()
        let all = try names(fd.raw, scan: &scan, check: check).filter { boolean(arguments, "include_hidden") || !$0.hasPrefix(".") }
        var rows: [AIToolValue] = [], next = offset
        for name in all.dropFirst(offset).prefix(limit) {
            try check()
            var info = stat()
            guard fstatat(fd.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { next += 1; continue }
            let row = AIToolValue.object(metadata(info, path: path + "/" + name))
            if try JSONEncoder().encode(rows + [row]).count > 24_000 { break }
            rows.append(row); next += 1
        }
        return try output(["path": .string(path), "type": .string("directory"), "entries": .array(rows),
            "next_offset": next < all.count ? .number(Double(next)) : .null, "truncated": .bool(scan.truncated || next < all.count)])
    }
    private func matches(_ pattern: String, _ path: String) -> Bool {
        let pattern = pattern.split(separator: "/").map(String.init), path = path.split(separator: "/").map(String.init)
        guard pattern.count <= 32 else { return false }
        var memo: [String: Bool] = [:]
        func match(_ p: Int, _ n: Int) -> Bool {
            let key = "\(p):\(n)"; if let result = memo[key] { return result }
            let result: Bool
            if p == pattern.count { result = n == path.count }
            else if pattern[p] == "**" { result = match(p + 1, n) || (n < path.count && match(p, n + 1)) }
            else { result = n < path.count && fnmatch(pattern[p], path[n], 0) == 0 && match(p + 1, n + 1) }
            memo[key] = result; return result
        }
        return match(0, 0)
    }
    private func walk(_ fd: FD, path: String, relative: String, pattern: String, needle: String, grep: Bool,
                      depth: Int, limit: Int, hidden: Bool, scan: inout Scan, rows: inout [AIToolValue], check: () throws -> Void) throws {
        if scan.exhausted || rows.count >= limit { scan.truncated = true; return }
        for name in try names(fd.raw, scan: &scan, check: check) {
            try check()
            if (!hidden && name.hasPrefix(".")) || [".git", "node_modules"].contains(name) { continue }
            let rel = relative.isEmpty ? name : relative + "/" + name
            var info = stat(); guard fstatat(fd.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let full = path + "/" + name
            if matches(pattern, rel) {
                if !grep { rows.append(.object(metadata(info, path: full))) }
                else if isRegular(info), !Self.isSensitive(full), info.st_size <= 1_048_576 {
                    guard !needle.isEmpty, needle.utf8.count <= 512 else { throw AIFileToolError.invalidPath }
                    guard scan.bytes + Int(info.st_size) <= 8_388_608 else { scan.truncated = true; return }
                    scan.bytes += Int(info.st_size)
                    if let child = try? openFile(Target(parent: fd, name: name, path: full)),
                       let text = String(data: try read(child.raw, offset: 0, count: Int(info.st_size), check: check), encoding: .utf8), !hasBinaryControls(text) {
                        var cursor = text.startIndex, number = 1
                        while cursor < text.endIndex {
                            try check()
                            let end = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
                            let line = text[cursor..<end]
                            if String(line).localizedCaseInsensitiveContains(needle) {
                                let row = AIToolValue.object(["path": .string(full), "line": .number(Double(number)), "text": .string(String(line.prefix(240)))])
                                if try JSONEncoder().encode(rows + [row]).count > 24_000 { scan.truncated = true; scan.exhausted = true; return }
                                rows.append(row)
                                if rows.count >= limit { scan.truncated = true; scan.exhausted = true; return }
                            }
                            if end == text.endIndex { break }
                            cursor = text.index(after: end); number += 1
                        }
                    }
                }
                if try JSONEncoder().encode(rows).count > 24_000 { rows.removeLast(); scan.truncated = true; return }
                if rows.count >= limit { scan.truncated = true; return }
            }
            if isDirectory(info) {
                if scan.exhausted { continue }
                if depth == 1 { scan.truncated = true; continue }
                if let child = try? FD(openat(fd.raw, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) {
                    try walk(child, path: full, relative: rel, pattern: pattern, needle: needle, grep: grep,
                        depth: depth - 1, limit: limit, hidden: hidden, scan: &scan, rows: &rows, check: check)
                    if scan.exhausted || rows.count >= limit { return }
                }
            }
        }
    }
    private func write(_ data: Data, target: Target, replacing: Bool, expected: String, check: () throws -> Void) throws -> stat {
        var original: stat?
        var originalFile: FD?
        if replacing {
            let fd = try openFile(target); let info = try status(fd.raw)
            guard isRegular(info), !expected.isEmpty, expected == revision(info) else { throw AIFileToolError.stale }
            original = info; originalFile = fd
        }
        let temporary = ".keylane-ai-" + UUID().uuidString + ".tmp"
        let fd = try FD(openat(target.parent.raw, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        defer { unlinkat(target.parent.raw, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try check()
                let count = Darwin.write(fd.raw, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw AIFileToolError.unavailable }; offset += count
            }
        }
        if let originalFile {
            // Keep Finder tags, quarantine and access metadata when atomically replacing text.
            guard fcopyfile(originalFile.raw, fd.raw, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw AIFileToolError.unavailable }
        }
        guard fsync(fd.raw) == 0 else { throw AIFileToolError.unavailable }
        try check()
        if let original {
            var current = stat()
            guard fstatat(target.parent.raw, target.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  revision(current) == revision(original) else { throw AIFileToolError.stale }
        }
        let code = replacing ? renameat(target.parent.raw, temporary, target.parent.raw, target.name) :
            renameatx_np(target.parent.raw, temporary, target.parent.raw, target.name, UInt32(RENAME_EXCL))
        guard code == 0 else {
            if errno == EEXIST { throw AIFileToolError.exists }; throw AIFileToolError.unavailable
        }
        return try status(fd.raw)
    }
    private func output(_ values: [String: AIToolValue]) throws -> AIToolResult {
        let data = try JSONEncoder().encode(values)
        return try AIToolResult(text: String(decoding: data, as: UTF8.self))
    }
    private func hasBinaryControls(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) } }
    private func string(_ args: [String: AIToolValue], _ key: String) -> String { if case .string(let text) = args[key] { return text }; return "" }
    private func integer(_ args: [String: AIToolValue], _ key: String, default value: Int) -> Int { if case .number(let n) = args[key], n.isFinite, n.rounded() == n, n >= 0, n <= 1_073_741_824 { return Int(n) }; return value }
    private func boolean(_ args: [String: AIToolValue], _ key: String) -> Bool { if case .bool(let value) = args[key] { return value }; return false }
}
