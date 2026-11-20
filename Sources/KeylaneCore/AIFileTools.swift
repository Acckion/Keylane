import Foundation
import CryptoKit
import Darwin

public struct AIFileToolScope: Codable, Identifiable, Equatable, Sendable {
    public let path: String
    public let bookmark: Data?
    public var id: String { path }
    public init(path: String, bookmark: Data? = nil) { self.path = path; self.bookmark = bookmark }
}

/// Revocation and the final native commit have a single linearization boundary.
/// Once revoke() returns, no later operation can enter a commit or disclosure section.
public final class AIFileAccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    public init() {}
    public func revoke() { lock.lock(); valid = false; lock.unlock() }
    public func withValidAccess<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw CancellationError() }
        try Task.checkCancellation()
        return try operation()
    }
    public func check() throws { try withValidAccess {} }
}

public enum AIFileToolError: LocalizedError, Equatable {
    case outsideScope, unavailable, unsupported, stale, exists, invalidPath, invalidText, tooLarge, restricted, creationScope
    public var errorDescription: String? {
        switch self {
        case .outsideScope: "路径不在本次匹配的 AI 授权目录内。"
        case .unavailable: "目录授权或文件不可用，请重新选择目录。"
        case .unsupported: "本批不支持该操作或文件类型；覆盖与编辑已停用。"
        case .stale: "确认的目标或目录已变化，请重新发起操作。"
        case .exists: "目标已存在，未覆盖。仅支持创建不存在的文件或目录。"
        case .invalidPath: "文件路径或搜索参数无效。"
        case .invalidText: "内容不是有效 UTF-8 文本，或 offset 不在字符边界。"
        case .tooLarge: "超过本次文件操作的数据限制，请缩小范围或分段读取。"
        case .restricted: "该路径属于受保护数据，文件工具不披露其内容、名称或元数据。"
        case .creationScope: "创建仅支持授权根目录内的一级名称。请先将目标父目录单独设为授权根。"
        }
    }
}

/// All file IO, including target preparation and the small final commit, runs on this actor.
public actor AIFileToolService {
    fileprivate final class FD: @unchecked Sendable {
        let raw: Int32
        init(_ raw: Int32) throws { guard raw >= 0 else { throw AIFileToolError.unavailable }; self.raw = raw }
        deinit { Darwin.close(raw) }
    }
    fileprivate final class Root: @unchecked Sendable {
        let path: String, id: String
        let fd: FD
        let access: URL?
        init(path: String, id: String, fd: FD, access: URL?) { self.path = path; self.id = id; self.fd = fd; self.access = access }
        deinit { access?.stopAccessingSecurityScopedResource() }
    }
    fileprivate struct Pin: Sendable { let name: String; let fd: FD }
    public final class Prepared: @unchecked Sendable {
        public let relativePath: String
        public let rootID: String
        /// Local confirmation only. Never put these strings into tool results or model history.
        public let localTarget: String
        public let localRoot: String
        public var localRoots: [String] { roots.map(\.path) }
        public let displayArguments: [String: AIToolValue]
        fileprivate let tool: String, arguments: [String: AIToolValue]
        fileprivate let lease: AIFileAccessLease
        fileprivate let roots: [Root], parents: [Pin], file: FD?, fileRevision: String?
        private let lock = NSLock()
        private var consumed = false
        fileprivate init(tool: String, arguments: [String: AIToolValue], roots: [Root], lease: AIFileAccessLease, parents: [Pin] = [], file: FD? = nil, fileRevision: String? = nil, relative: String = ".") {
            self.tool = tool; self.arguments = arguments; self.roots = roots; self.lease = lease; self.parents = parents; self.file = file; self.fileRevision = fileRevision
            relativePath = relative; rootID = roots.first?.id ?? ""
            localRoot = roots.first?.path ?? ""
            localTarget = relative == "." ? localRoot : (localRoot == "/" ? "" : localRoot) + "/" + relative
            displayArguments = tool == "keylane_file_roots" ? [:] : arguments.merging(["root": .string(rootID), "path": .string(relative)]) { _, normalized in normalized }
        }
        fileprivate func claim() throws {
            lock.lock(); defer { lock.unlock() }
            guard !consumed else { throw AIFileToolError.stale }; consumed = true
        }
    }
    private struct Disclosure { let fd: FD; let relative: String; let revision: String }
    private struct Scan { var visited = 0; var bytes = 0; var truncated = false; var exhausted = false }
    private let beforeCommit: @Sendable () throws -> Void
    public init() { beforeCommit = {} }
    // Deterministic race injection for synthetic tests; not exposed to the application.
    init(beforeCommit: @escaping @Sendable () throws -> Void) { self.beforeCommit = beforeCommit }

    public static func isSensitive(_ path: String) -> Bool {
        path.lowercased().split(separator: "/").contains { component in
            let name = String(component)
            return [".ssh", ".aws", ".gnupg", ".git", ".config", "keychains", ".codex", ".claude", "safari", "chrome", "firefox", "cookies", "login data", "local state", "auth.json", "credentials.json", "secrets.json"].contains(name) ||
                name == ".env" || name.hasPrefix(".env.") || [".pem", ".key", ".p12", ".pfx"].contains { name.hasSuffix($0) }
        }
    }
    private func policy(_ path: String) throws { if Self.isSensitive(path) { throw AIFileToolError.restricted } }

    /// Opens only the selected scope and pins the exact root, parent chain and existing object.
    /// Preparation reads metadata, never file bodies or directory names, and has no write effects.
    public func prepare(_ tool: String, arguments: [String: AIToolValue], scopes: [AIFileToolScope], lease: AIFileAccessLease) throws -> Prepared {
        try lease.check()
        guard ["keylane_file_roots", "keylane_read_file", "keylane_file_info", "keylane_glob", "keylane_grep", "keylane_write_file", "keylane_create_directory"].contains(tool) else { throw AIFileToolError.unsupported }
        if tool == "keylane_write_file", !["", "create"].contains(string(arguments, "mode")) { throw AIFileToolError.unsupported }
        guard !scopes.isEmpty, scopes.count <= 17 else { throw AIFileToolError.outsideScope }
        if tool == "keylane_file_roots" {
            let roots = try scopes.enumerated().map { try openRoot($0.element, id: "root_" + String($0.offset + 1)) }
            try lease.check()
            return Prepared(tool: tool, arguments: [:], roots: roots, lease: lease)
        }
        let requestedRoot = string(arguments, "root")
        let candidates = scopes.enumerated().filter { requestedRoot.isEmpty || requestedRoot == "root_" + String($0.offset + 1) }
        guard let defaultScope = candidates.first else { throw AIFileToolError.outsideScope }
        let path = try normalized(string(arguments, "path"), defaultRoot: Self.systemPath(defaultScope.element.path))
        guard let match = candidates.filter({ contains(Self.systemPath($0.element.path), path) }).max(by: { Self.systemPath($0.element.path).count < Self.systemPath($1.element.path).count }) else { throw AIFileToolError.outsideScope }
        try policy(path)
        let root = try openRoot(match.element, id: "root_" + String(match.offset + 1))
        let relative = path == root.path ? "." : String(path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
        let parts = relative == "." ? [] : relative.split(separator: "/").map(String.init)
        if ["keylane_write_file", "keylane_create_directory"].contains(tool), parts.count != 1 {
            throw AIFileToolError.creationScope
        }
        var parents: [Pin] = []
        var parent = root.fd
        for name in parts.dropLast() {
            try lease.check()
            let child = try FD(openat(parent.raw, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
            parents.append(Pin(name: name, fd: child)); parent = child
        }
        let name = parts.last ?? "."
        var file: FD?, fileRevision: String?
        if ["keylane_write_file", "keylane_create_directory"].contains(tool) {
            guard relative != "." else { throw AIFileToolError.exists }
            try absent(parent, name)
        } else {
            let object = try openChild(parent, name)
            let info = try status(object.raw)
            guard isDirectory(info) || isRegular(info) && info.st_nlink == 1 else { throw AIFileToolError.unsupported }
            if ["keylane_glob", "keylane_grep"].contains(tool), !isDirectory(info) { throw AIFileToolError.unsupported }
            file = object
            if isRegular(info) { fileRevision = revision(info) }
        }
        let plan = Prepared(tool: tool, arguments: arguments, roots: [root], lease: lease, parents: parents, file: file, fileRevision: fileRevision, relative: relative)
        try validate(plan); try lease.check()
        return plan
    }

    public func execute(_ plan: Prepared, lease: AIFileAccessLease, cancellation: AIFileAccessLease) throws -> AIToolResult {
        try plan.claim()
        guard plan.lease === lease else { throw AIFileToolError.stale }
        func check() throws { try lease.check(); try cancellation.check() }
        try check(); try validate(plan)
        var values: [String: AIToolValue]
        var disclosed: [Disclosure] = []
        let arguments = plan.arguments, path = plan.relativePath
        switch plan.tool {
        case "keylane_file_roots":
            values = ["directories": .array(plan.roots.map { .object(["root": .string($0.id), "path": .string(".")]) }), "default_root": .string(plan.rootID)]
        case "keylane_read_file":
            guard let fd = plan.file else { throw AIFileToolError.unavailable }
            let info = try status(fd.raw)
            if isDirectory(info) { values = try directory(fd, plan: plan, disclosed: &disclosed, check: check) }
            else {
                let offset = integer(arguments, "offset", default: 0), limit = integer(arguments, "limit", default: 4096)
                guard offset >= 0, (1...4096).contains(limit) else { throw AIFileToolError.invalidPath }
                var data = try read(fd.raw, offset: offset, count: limit, check: check)
                var text = String(data: data, encoding: .utf8)
                for _ in 0..<3 where text == nil && !data.isEmpty { data.removeLast(); text = String(data: data, encoding: .utf8) }
                guard let text, !hasBinaryControls(text), data.count > 0 || offset >= info.st_size else { throw AIFileToolError.invalidText }
                let next = offset + data.count
                values = ["path": .string(path), "type": .string("file"), "text": .string(text), "revision": .string(revision(info)), "offset": .number(Double(offset)), "next_offset": next < info.st_size ? .number(Double(next)) : .null, "truncated": .bool(next < info.st_size)]
            }
        case "keylane_file_info":
            guard let fd = plan.file else { throw AIFileToolError.unavailable }
            values = metadata(try status(fd.raw), path: path)
        case "keylane_glob", "keylane_grep":
            guard let fd = plan.file else { throw AIFileToolError.unavailable }
            let pattern = string(arguments, "pattern"), limit = integer(arguments, "limit", default: 50), depth = integer(arguments, "depth", default: 6)
            guard !pattern.isEmpty, pattern.utf8.count <= 256, !pattern.split(separator: "/").contains(".."), !pattern.hasPrefix("/"), (1...100).contains(limit), (1...12).contains(depth) else { throw AIFileToolError.invalidPath }
            let query = string(arguments, "query"), grep = plan.tool == "keylane_grep"
            guard !grep || !query.isEmpty && query.utf8.count <= 512 else { throw AIFileToolError.invalidPath }
            var scan = Scan(), rows: [AIToolValue] = []
            try walk(fd, plan: plan, relative: path, patternRelative: "", pattern: pattern, needle: query, grep: grep, depth: depth, limit: limit, hidden: boolean(arguments, "include_hidden"), scan: &scan, rows: &rows, disclosed: &disclosed, check: check)
            values = ["path": .string(path), "matches": .array(rows), "truncated": .bool(scan.truncated)]
        case "keylane_write_file":
            let content = string(arguments, "content")
            guard content.utf8.count <= 12_000, !hasBinaryControls(content) else { throw AIFileToolError.tooLarge }
            guard plan.parents.isEmpty else { throw AIFileToolError.creationScope }
            let parent = plan.roots[0].fd
            let fd = try lease.withValidAccess { try cancellation.withValidAccess {
                try validate(plan)
                return try anonymousStage()
            } }
            let data = Data(content.utf8)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = try lease.withValidAccess { try cancellation.withValidAccess {
                        Darwin.write(fd.raw, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    } }
                    guard count > 0 else { throw AIFileToolError.unavailable }; offset += count
                }
            }
            guard fsync(fd.raw) == 0 else { throw AIFileToolError.unavailable }
            try beforeCommit()
            // Revocation cannot return between validation and exclusive FD-based publication.
            // fclonefileat never reopens a staging name and refuses an existing destination.
            // Unsupported/cross-volume filesystems fail closed; there is no rename fallback.
            try lease.withValidAccess { try cancellation.withValidAccess {
                try validate(plan)
                let name = (path as NSString).lastPathComponent
                let code = fclonefileat(fd.raw, parent.raw, name, 0)
                guard code == 0 else { throw errno == EEXIST ? AIFileToolError.exists : AIFileToolError.unavailable }
            } }
            values = ["path": .string(path), "written": .bool(true)]
        case "keylane_create_directory":
            try beforeCommit()
            try lease.withValidAccess { try cancellation.withValidAccess {
                try validate(plan)
                guard plan.parents.isEmpty else { throw AIFileToolError.creationScope }
                let parent = plan.roots[0].fd
                guard mkdirat(parent.raw, (path as NSString).lastPathComponent, 0o700) == 0 else { throw errno == EEXIST ? AIFileToolError.exists : AIFileToolError.unavailable }
            } }
            values = ["path": .string(path), "created": .bool(true)]
        default: throw AIFileToolError.unsupported
        }
        // Results carry root handles and relative paths, never the host's root path.
        values["root"] = .string(plan.rootID)
        return try lease.withValidAccess { try cancellation.withValidAccess {
            // For creates the absent target is now present; parent/root identity still must match.
            try validate(plan, checkTarget: !["keylane_write_file", "keylane_create_directory"].contains(plan.tool))
            for entry in disclosed { try validateDisclosure(entry, root: plan.roots[0]) }
            return try output(values)
        } }
    }

    public static func systemPath(_ path: String) -> String {
        let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
        for alias in ["/var", "/tmp", "/etc"] where lexical == alias || lexical.hasPrefix(alias + "/") {
            guard let pointer = realpath(alias, nil) else { return lexical }; defer { free(pointer) }
            return String(cString: pointer) + lexical.dropFirst(alias.count)
        }
        return lexical
    }
    private func normalized(_ path: String, defaultRoot: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0") else { throw AIFileToolError.invalidPath }
        let expanded = path == "~" || path.hasPrefix("~/") ? (path as NSString).expandingTildeInPath : path.hasPrefix("/") ? path : defaultRoot + "/" + path
        return Self.systemPath(expanded)
    }
    private func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    private func openDirectory(_ path: String) throws -> FD {
        var fd = try FD(Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC))
        for name in path.split(separator: "/") { fd = try FD(openat(fd.raw, String(name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) }
        return fd
    }
    private func openRoot(_ scope: AIFileToolScope, id: String) throws -> Root {
        guard scope.path.hasPrefix("/"), !scope.path.contains("\0") else { throw AIFileToolError.invalidPath }
        let path = Self.systemPath(scope.path)
        try policy(path)
        var accessed: URL?
        if let bookmark = scope.bookmark {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), !stale, Self.systemPath(url.path) == path else { throw AIFileToolError.unavailable }
            if url.startAccessingSecurityScopedResource() { accessed = url }
        }
        do { return Root(path: path, id: id, fd: try openDirectory(path), access: accessed) }
        catch { accessed?.stopAccessingSecurityScopedResource(); throw error }
    }
    private func openChild(_ parent: FD, _ name: String) throws -> FD {
        try FD(openat(parent.raw, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
    }
    private func same(_ first: FD, _ second: FD) throws -> Bool {
        let a = try status(first.raw), b = try status(second.raw)
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode & S_IFMT == b.st_mode & S_IFMT
    }
    private func pathOf(_ fd: FD) throws -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd.raw, F_GETPATH, &bytes) == 0 else { throw AIFileToolError.stale }
        return Self.systemPath(String(cString: bytes))
    }
    private func anonymousStage() throws -> FD {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneAIStage-" + UUID().uuidString).path
        let fd = try FD(Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        guard unlink(path) == 0 else { throw AIFileToolError.unavailable }
        return fd
    }
    private func absent(_ parent: FD, _ name: String) throws {
        var info = stat()
        guard fstatat(parent.raw, name, &info, AT_SYMLINK_NOFOLLOW) != 0 else { throw AIFileToolError.exists }
        guard errno == ENOENT else { throw AIFileToolError.unavailable }
    }
    private func validate(_ plan: Prepared, checkTarget: Bool = true) throws {
        for root in plan.roots {
            try policy(root.path)
            guard try pathOf(root.fd) == root.path, try same(openDirectory(root.path), root.fd) else { throw AIFileToolError.stale }
        }
        guard let root = plan.roots.first, plan.tool != "keylane_file_roots" else { return }
        var parent = root.fd, full = root.path
        for pin in plan.parents {
            full = (full == "/" ? "" : full) + "/" + pin.name; try policy(full)
            guard try pathOf(pin.fd) == full, try same(openChild(parent, pin.name), pin.fd) else { throw AIFileToolError.stale }
            parent = pin.fd
        }
        try policy(plan.localTarget)
        guard checkTarget else { return }
        let name = plan.relativePath == "." ? "." : (plan.relativePath as NSString).lastPathComponent
        if let file = plan.file {
            guard try pathOf(file) == plan.localTarget, try same(openChild(parent, name), file) else { throw AIFileToolError.stale }
            let info = try status(file.raw)
            guard !isRegular(info) || info.st_nlink == 1 else { throw AIFileToolError.unsupported }
            if let expected = plan.fileRevision, revision(info) != expected { throw AIFileToolError.stale }
        } else { try absent(parent, name) }
    }
    private func status(_ fd: Int32) throws -> stat { var info = stat(); guard fstat(fd, &info) == 0 else { throw AIFileToolError.unavailable }; return info }
    private func isDirectory(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFDIR }
    private func isRegular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }
    private func revision(_ info: stat) -> String {
        let value = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_mode)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func metadata(_ info: stat, path: String) -> [String: AIToolValue] {
        ["path": .string(path), "type": .string(isDirectory(info) ? "directory" : "file"), "size": .number(Double(info.st_size)), "modified": .string(Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)).ISO8601Format()), "revision": .string(revision(info))]
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
    private func inspect(_ parent: FD, name: String, plan: Prepared, relative: String) throws -> (FD, stat)? {
        let full = (plan.roots[0].path == "/" ? "" : plan.roots[0].path) + "/" + relative
        guard !Self.isSensitive(full) else { return nil }
        guard let fd = try? openChild(parent, name), let info = try? status(fd.raw),
              isDirectory(info) || isRegular(info) && info.st_nlink == 1 else { return nil }
        guard try pathOf(fd) == full, try contains(plan.roots[0].path, pathOf(fd)) else { throw AIFileToolError.stale }
        return (fd, info)
    }
    private func validateDisclosure(_ entry: Disclosure, root: Root) throws {
        let full = (root.path == "/" ? "" : root.path) + "/" + entry.relative
        try policy(full)
        var current = root.fd
        for name in entry.relative.split(separator: "/") { current = try openChild(current, String(name)) }
        guard try pathOf(entry.fd) == full, try same(current, entry.fd), try revision(status(entry.fd.raw)) == entry.revision else { throw AIFileToolError.stale }
        let info = try status(entry.fd.raw)
        guard !isRegular(info) || info.st_nlink == 1 else { throw AIFileToolError.unsupported }
    }
    private func joined(_ parent: String, _ name: String) -> String { parent == "." ? name : parent + "/" + name }
    private func directory(_ fd: FD, plan: Prepared, disclosed: inout [Disclosure], check: () throws -> Void) throws -> [String: AIToolValue] {
        let offset = integer(plan.arguments, "offset", default: 0), limit = integer(plan.arguments, "limit", default: 50)
        guard offset >= 0, (1...100).contains(limit) else { throw AIFileToolError.invalidPath }
        var scan = Scan()
        let all = try names(fd.raw, scan: &scan, check: check).filter {
            (boolean(plan.arguments, "include_hidden") || !$0.hasPrefix(".")) && !Self.isSensitive(plan.roots[0].path + "/" + joined(plan.relativePath, $0))
        }
        var rows: [AIToolValue] = [], next = offset
        for name in all.dropFirst(offset).prefix(limit) {
            try check()
            let relative = joined(plan.relativePath, name)
            guard let (child, info) = try inspect(fd, name: name, plan: plan, relative: relative) else { next += 1; continue }
            let row = AIToolValue.object(metadata(info, path: relative))
            if try JSONEncoder().encode(rows + [row]).count > 24_000 { break }
            rows.append(row); disclosed.append(.init(fd: child, relative: relative, revision: revision(info))); next += 1
        }
        return ["path": .string(plan.relativePath), "type": .string("directory"), "entries": .array(rows), "next_offset": next < all.count ? .number(Double(next)) : .null, "truncated": .bool(scan.truncated || next < all.count)]
    }
    private func walk(_ fd: FD, plan: Prepared, relative: String, patternRelative: String, pattern: String, needle: String, grep: Bool, depth: Int, limit: Int, hidden: Bool, scan: inout Scan, rows: inout [AIToolValue], disclosed: inout [Disclosure], check: () throws -> Void) throws {
        if scan.exhausted || rows.count >= limit { scan.truncated = true; return }
        for name in try names(fd.raw, scan: &scan, check: check) {
            try check()
            if (!hidden && name.hasPrefix(".")) || [".git", "node_modules"].contains(name) { continue }
            let rel = joined(relative, name), patternPath = joined(patternRelative.isEmpty ? "." : patternRelative, name)
            guard let (child, info) = try inspect(fd, name: name, plan: plan, relative: rel) else { continue }
            if matches(pattern, patternPath) {
                if !grep {
                    rows.append(.object(metadata(info, path: rel)))
                    disclosed.append(.init(fd: child, relative: rel, revision: revision(info)))
                }
                else if isRegular(info), info.st_size <= 1_048_576 {
                    guard scan.bytes + Int(info.st_size) <= 8_388_608 else { scan.truncated = true; scan.exhausted = true; return }
                    scan.bytes += Int(info.st_size)
                    if let text = String(data: try read(child.raw, offset: 0, count: Int(info.st_size), check: check), encoding: .utf8), !hasBinaryControls(text) {
                        guard revision(try status(child.raw)) == revision(info) else { throw AIFileToolError.stale }
                        var cursor = text.startIndex, number = 1
                        while cursor < text.endIndex {
                            try check()
                            let end = text[cursor...].firstIndex(of: "\n") ?? text.endIndex
                            let line = text[cursor..<end]
                            if String(line).localizedCaseInsensitiveContains(needle) {
                                let row = AIToolValue.object(["path": .string(rel), "line": .number(Double(number)), "text": .string(String(line.prefix(240)))])
                                if try JSONEncoder().encode(rows + [row]).count > 24_000 { scan.truncated = true; scan.exhausted = true; return }
                                rows.append(row)
                                disclosed.append(.init(fd: child, relative: rel, revision: revision(info)))
                                if rows.count >= limit { scan.truncated = true; scan.exhausted = true; return }
                            }
                            if end == text.endIndex { break }; cursor = text.index(after: end); number += 1
                        }
                    }
                }
                if try JSONEncoder().encode(rows).count > 24_000 { rows.removeLast(); scan.truncated = true; scan.exhausted = true; return }
                if rows.count >= limit { scan.truncated = true; scan.exhausted = true; return }
            }
            if isDirectory(info) {
                if scan.exhausted { continue }
                if depth == 1 { scan.truncated = true; continue }
                try walk(child, plan: plan, relative: rel, patternRelative: patternPath, pattern: pattern, needle: needle, grep: grep, depth: depth - 1, limit: limit, hidden: hidden, scan: &scan, rows: &rows, disclosed: &disclosed, check: check)
                if scan.exhausted { return }
            }
        }
    }
    private func output(_ values: [String: AIToolValue]) throws -> AIToolResult { try .init(text: String(decoding: JSONEncoder().encode(values), as: UTF8.self)) }
    private func hasBinaryControls(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) } }
    private func string(_ args: [String: AIToolValue], _ key: String) -> String { if case .string(let text) = args[key] { return text }; return "" }
    private func integer(_ args: [String: AIToolValue], _ key: String, default value: Int) -> Int { if case .number(let n) = args[key], n.isFinite, n.rounded() == n, n >= 0, n <= 1_073_741_824 { return Int(n) }; return value }
    private func boolean(_ args: [String: AIToolValue], _ key: String) -> Bool { if case .bool(let value) = args[key] { return value }; return false }
}
