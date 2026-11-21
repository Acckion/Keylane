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
    case outsideScope, unavailable, unsupported, stale, exists, invalidPath, invalidText, tooLarge, restricted, creationScope, creationUnsupported, creationUnconfirmed, mutationUnsupported, mutationUnconfirmed, editMismatch, invalidPattern, regexBudget
    public var errorDescription: String? {
        switch self {
        case .outsideScope: "路径不在本次匹配的 AI 授权目录内。"
        case .unavailable: "目录授权或文件不可用，请重新选择目录。"
        case .unsupported: "该操作或文件类型不支持。"
        case .stale: "确认的目标或目录已变化，请重新发起操作。"
        case .exists: "目标已存在；新建、复制、移动和恢复不会覆盖其他文件。"
        case .invalidPath: "文件路径或搜索参数无效。"
        case .invalidText: "内容不是有效 UTF-8 文本，或 offset 不在字符边界。"
        case .tooLarge: "超过本次文件操作的数据限制，请缩小范围或分段读取。"
        case .restricted: "该路径属于受保护数据，文件工具不披露其内容、名称或元数据。"
        case .mutationUnsupported: "此文件系统不支持本次原子文件操作，未使用复制后删除等回退。"
        case .mutationUnconfirmed: "文件操作结果无法确认，可能已经发生改动。请核对文件和恢复记录；勿自动重试或回滚。"
        case .editMismatch: "原文匹配次数不符合要求，或文件版本已变化；未编辑。"
        case .invalidPattern: "正则表达式无效或超过长度限制；使用行级 ICU 正则语法。"
        case .regexBudget: "正则搜索超过时间或引擎额度，请简化表达式或缩小范围。未返回不完整匹配页。"
        case .creationUnsupported: "当前文件系统不支持此安全创建操作；未启用覆盖、复制或改名回退。"
        case .creationUnconfirmed: "创建结果无法确认：文件或文件夹可能已在原授权目录对象中创建，该目录也可能已移动。请人工核对，勿直接重试；未执行自动回滚。"
        case .creationScope: "有副作用的文件操作仅支持授权根目录内的一级名称。请先将目标父目录单独设为授权根。"
        }
    }
}

/// All file IO, including target preparation and the small final commit, runs on this actor.
public actor AIFileToolService {
    final class FD: @unchecked Sendable {
        let raw: Int32
        init(_ raw: Int32) throws { guard raw >= 0 else { throw AIFileToolError.unavailable }; self.raw = raw }
        deinit { Darwin.close(raw) }
    }
    final class Root: @unchecked Sendable {
        let path: String, id: String
        let fd: FD
        let access: URL?
        let scope: AIFileToolScope
        init(path: String, id: String, fd: FD, access: URL?, scope: AIFileToolScope) { self.path = path; self.id = id; self.fd = fd; self.access = access; self.scope = scope }
        deinit { access?.stopAccessingSecurityScopedResource() }
    }
    struct Pin: Sendable { let name: String; let fd: FD }
    public final class Prepared: @unchecked Sendable {
        public let relativePath: String
        public let rootID: String
        /// Local confirmation only. Never put these strings into tool results or model history.
        public let localTarget: String
        public let localRoot: String
        public var localRoots: [String] { Array(Set(roots.map(\.path) + (mutation?.destination?.localRoots ?? []))).sorted() }
        public var localMutationSummary: String? { mutation?.localSummary }
        private let normalizedArguments: [String: AIToolValue]
        public var displayArguments: [String: AIToolValue] { mutation?.displayArguments ?? normalizedArguments }
        let mutation: MutationPlan?
        public var sourceTool: String { mutation?.tool ?? continuation?.plan.sourceTool ?? tool }
        let tool: String, arguments: [String: AIToolValue]
        fileprivate let continuation: ReadReference?
        let lease: AIFileAccessLease
        let roots: [Root], parents: [Pin], file: FD?, fileRevision: String?
        private let lock = NSLock()
        private var consumed = false
        fileprivate init(tool: String, arguments: [String: AIToolValue], roots: [Root], lease: AIFileAccessLease, parents: [Pin] = [], file: FD? = nil, fileRevision: String? = nil, relative: String = ".", continuation: ReadReference? = nil, mutation: MutationPlan? = nil) {
            self.mutation = mutation
            self.tool = tool; self.arguments = arguments; self.continuation = continuation; self.roots = roots; self.lease = lease; self.parents = parents; self.file = file; self.fileRevision = fileRevision
            relativePath = relative; rootID = roots.first?.id ?? ""
            localRoot = roots.first?.path ?? ""
            localTarget = relative == "." ? localRoot : (localRoot == "/" ? "" : localRoot) + "/" + relative
            normalizedArguments = tool == "keylane_file_roots" ? [:] : arguments.merging(["root": .string(rootID), "path": .string(relative)]) { _, normalized in normalized }
        }
        fileprivate func claim() throws {
            lock.lock(); defer { lock.unlock() }
            guard !consumed else { throw AIFileToolError.stale }; consumed = true
        }
    }
    fileprivate enum ReadPayload {
        case text(offset: Int)
        case document(AITemporaryReadResult, offset: Int, pages: Int, format: String, ocr: Bool)
        case rows(AITemporaryReadResult, key: String, offset: Int, sourceTruncated: Bool)
        var bytes: Int { switch self { case .text: 0; case .document(let file, _, _, _, _), .rows(let file, _, _, _): file.count } }
    }
    fileprivate final class ReadReference: @unchecked Sendable {
        let plan: Prepared, payload: ReadPayload
        var pinCost: Int { plan.roots.count + plan.parents.count + (plan.file == nil ? 0 : 1) + (payload.bytes == 0 ? 0 : 1) }
        init(plan: Prepared, payload: ReadPayload) { self.plan = plan; self.payload = payload }
    }
    /// One request's opaque continuation capabilities. Construction does no IO.
    public final class ReadSession: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: AIFileAccessLease?
        private var requestID: UUID?
        private var entries: [String: ReadReference] = [:]
        public init() {}
        public func bind(to request: UUID) throws {
            lock.lock(); defer { lock.unlock() }
            guard requestID == nil || requestID == request else { throw AIFileToolError.stale }
            requestID = request
        }
        fileprivate func lookup(_ token: String, lease: AIFileAccessLease) throws -> ReadReference {
            lock.lock(); defer { lock.unlock() }
            guard owner === lease, let value = entries[token] else { throw AIFileToolError.stale }; return value
        }
        /// Publish and rotate under one lock. Failed generation/encoding keeps the old cursor usable.
        fileprivate func publish(consuming token: String?, expected: ReadReference?, next: ReadReference?,
                                 lease: AIFileAccessLease, result: (String?) throws -> AIToolResult) throws -> AIToolResult {
            lock.lock(); defer { lock.unlock() }
            guard owner == nil || owner === lease else { throw AIFileToolError.stale }
            if let token {
                guard let expected, entries[token] === expected else { throw AIFileToolError.stale }
            }
            if let next {
                let retained = entries.filter { $0.key != token }.map(\.value)
                guard retained.count < 32, retained.reduce(0, { $0 + $1.payload.bytes }) + next.payload.bytes <= 8_388_608,
                      retained.reduce(0, { $0 + $1.pinCost }) + next.pinCost <= 64 else { throw AIFileToolError.tooLarge }
            }
            let nextToken = next.map { _ in UUID().uuidString }
            let value = try result(nextToken)
            if let token { entries.removeValue(forKey: token) }
            if let nextToken, let next { owner = lease; entries[nextToken] = next }
            return value
        }
    }
    private struct Disclosure { let fd: FD; let relative: String; let revision: String }
    private struct Scan { var visited = 0; var bytes = 0; var truncated = false; var exhausted = false; var outputBytes = 0 }
    /// Internal syscall seam for deterministic synthetic races/failures, never configurable by tools.
    struct CreationSyscalls: Sendable {
        struct Result: Sendable { let code: Int32; let error: Int32 }
        var cloneFile: @Sendable (Int32, Int32, String) -> Result
        var createDirectory: @Sendable (Int32, String) -> Result
        static let live = Self(cloneFile: { source, parent, name in
            let code = fclonefileat(source, parent, name, 0)
            return .init(code: code, error: code == 0 ? 0 : errno)
        }, createDirectory: { parent, name in
            let code = mkdirat(parent, name, 0o700)
            return .init(code: code, error: code == 0 ? 0 : errno)
        })
    }
    let beforeCommit: @Sendable () throws -> Void
    let creationSyscalls: CreationSyscalls
    var mutationConfiguration = MutationConfiguration.live
    public init() { beforeCommit = {}; creationSyscalls = .live }
    public init(recoveryDirectory: URL) {
        beforeCommit = {}; creationSyscalls = .live
        mutationConfiguration.recoveryDirectory = recoveryDirectory
    }
    init(mutations: MutationConfiguration, beforeCommit: @escaping @Sendable () throws -> Void = {}, creationSyscalls: CreationSyscalls = .live) {
        mutationConfiguration = mutations; self.beforeCommit = beforeCommit; self.creationSyscalls = creationSyscalls
    }
    func wrapping(_ source: Prepared, mutation: MutationPlan) -> Prepared {
        Prepared(tool: source.tool, arguments: source.arguments, roots: source.roots, lease: source.lease, parents: source.parents, file: source.file, fileRevision: source.fileRevision, relative: source.relativePath, mutation: mutation)
    }
    init(beforeCommit: @escaping @Sendable () throws -> Void = {}, creationSyscalls: CreationSyscalls) {
        self.beforeCommit = beforeCommit; self.creationSyscalls = creationSyscalls
    }
    init(beforeCommit: @escaping @Sendable () throws -> Void) {
        self.beforeCommit = beforeCommit; creationSyscalls = .live
    }
    private func creationError(_ code: Int32) -> AIFileToolError {
        if code == EEXIST { return .exists }
        if [ENOTSUP, EOPNOTSUPP, EXDEV, ENOSYS].contains(code) { return .creationUnsupported }
        return .creationUnconfirmed
    }

    public static func isRecoveryStorage(_ path: String) -> Bool { path.lowercased().split(separator: "/").contains(".keylane-ai-recovery") }
    public static func isSensitive(_ path: String) -> Bool {
        path.lowercased().split(separator: "/").contains { component in
            let name = String(component)
            return [".ssh", ".aws", ".gnupg", ".git", ".config", "keychains", ".keylane-ai-recovery", ".codex", ".claude", "safari", "chrome", "firefox", "cookies", "login data", "local state", "auth.json", "credentials.json", "secrets.json"].contains(name) ||
                name == ".env" || name.hasPrefix(".env.") || [".pem", ".key", ".p12", ".pfx"].contains { name.hasSuffix($0) }
        }
    }
    func policy(_ path: String) throws { if Self.isSensitive(path) { throw AIFileToolError.restricted } }

    /// Opens only the selected scope and pins the exact root, parent chain and existing object.
    /// Preparation reads metadata, never file bodies or directory names, and has no write effects.
    public func prepare(_ tool: String, arguments: [String: AIToolValue], scopes: [AIFileToolScope], lease: AIFileAccessLease, session: ReadSession? = nil) throws -> Prepared {
        try lease.check()
        if Self.mutationTools.contains(tool) { return try prepareMutation(tool, arguments: arguments, scopes: scopes, lease: lease) }
        if tool == "keylane_read_result" {
            guard let session else { throw AIFileToolError.stale }
            let reference = try session.lookup(string(arguments, "cursor"), lease: lease)
            let original = reference.plan
            guard let root = original.roots.first, scopes.enumerated().contains(where: {
                "root_" + String($0.offset + 1) == root.id && $0.element == root.scope
            }) else { throw AIFileToolError.stale }
            try validate(original)
            return Prepared(tool: tool, arguments: arguments, roots: original.roots, lease: lease,
                parents: original.parents, file: original.file, fileRevision: original.fileRevision,
                relative: original.relativePath, continuation: reference)
        }
        guard ["keylane_file_roots", "keylane_read_file", "keylane_file_info", "keylane_glob", "keylane_grep", "keylane_search_indexed_files", "keylane_write_file", "keylane_create_directory"].contains(tool) else { throw AIFileToolError.unsupported }
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
        guard parts.count <= 33 else { throw AIFileToolError.tooLarge }
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
            if ["keylane_glob", "keylane_grep", "keylane_search_indexed_files"].contains(tool), !isDirectory(info) { throw AIFileToolError.unsupported }
            file = object
            if isRegular(info) { fileRevision = revision(info) }
        }
        let plan = Prepared(tool: tool, arguments: arguments, roots: [root], lease: lease, parents: parents, file: file, fileRevision: fileRevision, relative: relative)
        try validate(plan); try lease.check()
        return plan
    }

    public func execute(_ plan: Prepared, lease: AIFileAccessLease, cancellation: AIFileAccessLease, session: ReadSession? = nil, indexedPaths: [String] = [], documentWork: ImageTextRecognitionWork = .init()) throws -> AIToolResult {
        try plan.claim()
        if plan.mutation != nil {
            do { return try executeMutation(plan, lease: lease, cancellation: cancellation) }
            catch is CancellationError { throw CancellationError() }
            catch let error as AIFileToolError { throw error }
            catch { throw AIFileToolError.unavailable } // Native errors must not disclose local paths.
        }
        guard plan.lease === lease else { throw AIFileToolError.stale }
        func check() throws { try lease.check(); try cancellation.check() }
        try check(); try validate(plan)
        var values: [String: AIToolValue]
        var disclosed: [Disclosure] = []
        var continuation: ReadReference?
        let arguments = plan.arguments, path = plan.relativePath
        var creationCompleted = false
        switch plan.tool {
        case "keylane_file_roots":
            values = ["directories": .array(plan.roots.map { .object(["root": .string($0.id), "path": .string(".")]) }), "default_root": .string(plan.rootID)]
        case "keylane_read_file":
            guard let fd = plan.file else { throw AIFileToolError.unavailable }
            let info = try status(fd.raw)
            let format = (path as NSString).pathExtension.lowercased()
            guard !boolean(arguments, "ocr") || format == "pdf" && !isDirectory(info) else { throw AIFileToolError.unsupported }
            if isDirectory(info), session != nil {
                var scan = Scan(), rows: [AIToolValue] = [], bytes = 0
                for name in try names(fd.raw, scan: &scan, check: check) {
                    try check()
                    if !boolean(arguments, "include_hidden") && name.hasPrefix(".") { continue }
                    let relative = joined(path, name)
                    guard let (_, info) = try inspect(fd, name: name, plan: plan, relative: relative) else { continue }
                    let row = AIToolValue.object(metadata(info, path: relative))
                    bytes += try JSONEncoder().encode(row).count + 1
                    if bytes > 2_000_000 { scan.truncated = true; break }
                    rows.append(row)
                }
                (values, continuation) = try rowsPage(rows, plan: plan, key: "entries", sourceTruncated: scan.truncated,
                    offset: integer(arguments, "offset", default: 0), limit: integer(arguments, "limit", default: 50), disclosed: &disclosed, check: check)
            } else if isDirectory(info) { values = try directory(fd, plan: plan, disclosed: &disclosed, check: check) }
            else if path.lowercased().hasSuffix(".pdf") {
                guard info.st_size <= 8_388_608, arguments["page"] == nil || arguments["offset"] == nil else { throw AIFileToolError.tooLarge }
                let data = try read(fd.raw, offset: 0, count: Int(info.st_size), check: check)
                try validate(plan)
                let pages: [String]
                do { pages = try AIFileDocumentText.pdfPages(data, ocr: boolean(arguments, "ocr"), work: documentWork, check: check) }
                catch { try validate(plan); throw error }
                let page = integer(arguments, "page", default: 1)
                guard (1...pages.count).contains(page) else { throw AIFileToolError.invalidPath }
                var offsets: [Int] = [], text = ""
                for (index, body) in pages.enumerated() {
                    offsets.append(text.utf8.count); text += "[Page " + String(index + 1) + "]\n" + body + "\n\n"
                }
                let blob = try AITemporaryReadResult(Data(text.utf8))
                let offset = arguments["page"] == nil ? integer(arguments, "offset", default: 0) : offsets[page - 1]
                (values, continuation) = try documentPage(blob, pages: pages.count, plan: plan, offset: offset,
                    limit: integer(arguments, "limit", default: 4096), ocr: boolean(arguments, "ocr"), check: check)
            } else if AIFileOfficeText.extensions.contains(format) {
                guard info.st_size <= 8_388_608 else { throw AIFileToolError.tooLarge }
                guard arguments["page"] == nil else { throw AIFileToolError.invalidPath }
                let data = try read(fd.raw, offset: 0, count: Int(info.st_size), check: check)
                try validate(plan)
                let sections: [String]
                do { sections = try AIFileOfficeText.sections(data, extension: format, check: check) }
                catch { try validate(plan); throw error }
                let blob = try AITemporaryReadResult(Data(sections.joined(separator: "\n\n").utf8))
                (values, continuation) = try documentPage(blob, pages: sections.count, plan: plan,
                    offset: integer(arguments, "offset", default: 0), limit: integer(arguments, "limit", default: 4096), format: format, check: check)
            } else {
                guard arguments["page"] == nil else { throw AIFileToolError.invalidPath }
                (values, continuation) = try textPage(plan, offset: integer(arguments, "offset", default: 0),
                    limit: integer(arguments, "limit", default: 4096), check: check)
            }
        case "keylane_read_result":
            guard let session, let reference = plan.continuation else { throw AIFileToolError.stale }
            guard try session.lookup(string(arguments, "cursor"), lease: lease) === reference else { throw AIFileToolError.stale }
            switch reference.payload {
            case .text(let offset):
                (values, continuation) = try textPage(reference.plan, offset: offset,
                    limit: integer(arguments, "limit", default: 4096), check: check)
            case .document(let blob, let offset, let pages, let format, let ocr):
                (values, continuation) = try documentPage(blob, pages: pages, plan: reference.plan, offset: offset,
                    limit: integer(arguments, "limit", default: 4096), format: format, ocr: ocr, check: check)
            case .rows(let blob, let key, let offset, let sourceTruncated):
                let rows = try JSONDecoder().decode([AIToolValue].self, from: blob.read(check: check))
                (values, continuation) = try rowsPage(rows, plan: reference.plan, key: key, sourceTruncated: sourceTruncated,
                    offset: offset, limit: integer(arguments, "limit", default: 50), blob: blob, disclosed: &disclosed, check: check)
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
            let matcher = try AIFileTextMatcher(query: query, regex: boolean(arguments, "regex"), caseSensitive: boolean(arguments, "case_sensitive"))
            var scan = Scan(), rows: [AIToolValue] = []
            try walk(fd, plan: plan, relative: path, patternRelative: "", pattern: pattern, matcher: matcher, grep: grep, depth: depth, limit: session == nil ? limit : 1000, hidden: boolean(arguments, "include_hidden"), captureHandles: session == nil, scan: &scan, rows: &rows, disclosed: &disclosed, check: check)
            if session != nil {
                (values, continuation) = try rowsPage(rows, plan: plan, key: "matches", sourceTruncated: scan.truncated,
                    offset: 0, limit: limit, disclosed: &disclosed, check: check)
            } else { values = ["path": .string(path), "matches": .array(rows), "truncated": .bool(scan.truncated)] }
        case "keylane_search_indexed_files":
            guard indexedPaths.count <= 200 else { throw AIFileToolError.tooLarge }
            var rows: [AIToolValue] = [], seen = Set<String>()
            for candidate in indexedPaths {
                try check()
                let full = Self.systemPath(candidate)
                guard seen.insert(full).inserted, contains(plan.localTarget, full), contains(plan.roots[0].path, full), !Self.isSensitive(full) else { continue }
                let relative = full == plan.roots[0].path ? "." : String(full.dropFirst(plan.roots[0].path == "/" ? 1 : plan.roots[0].path.count + 1))
                guard let entry = try? openDisclosure(relative: relative, plan: plan) else { continue }
                rows.append(.object(metadata(try status(entry.fd.raw), path: relative)))
            }
            (values, continuation) = try rowsPage(rows, plan: plan, key: "matches", sourceTruncated: indexedPaths.count == 200,
                offset: 0, limit: integer(arguments, "limit", default: 50), disclosed: &disclosed, check: check)
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
                let result = creationSyscalls.cloneFile(fd.raw, parent.raw, name)
                guard result.code == 0 else { throw creationError(result.error) }
                creationCompleted = true
            } }
            values = ["path": .string(path), "written": .bool(true)]
        case "keylane_create_directory":
            try beforeCommit()
            try lease.withValidAccess { try cancellation.withValidAccess {
                try validate(plan)
                guard plan.parents.isEmpty else { throw AIFileToolError.creationScope }
                let parent = plan.roots[0].fd
                let result = creationSyscalls.createDirectory(parent.raw, (path as NSString).lastPathComponent)
                guard result.code == 0 else { throw creationError(result.error) }
                creationCompleted = true
            } }
            values = ["path": .string(path), "created": .bool(true)]
        default: throw AIFileToolError.unsupported
        }
        // Results carry root handles and relative paths, never the host's root path.
        values["root"] = .string(plan.rootID)
        do {
            return try lease.withValidAccess { try cancellation.withValidAccess {
                // For creates the absent target is now present; parent/root identity still must match.
                try validate(plan, checkTarget: !["keylane_write_file", "keylane_create_directory"].contains(plan.tool))
                for entry in disclosed { try validateDisclosure(entry, root: plan.roots[0]) }
                guard let session else { return try output(values) }
                return try session.publish(consuming: plan.continuation == nil ? nil : string(arguments, "cursor"),
                                           expected: plan.continuation, next: continuation, lease: lease) { token in
                    if let token { values["cursor"] = .string(token) }
                    return try output(values)
                }
            } }
        } catch {
            // A post-publication check/cancellation cannot roll back a filesystem effect.
            if creationCompleted { throw AIFileToolError.creationUnconfirmed }
            throw error
        }
    }

    public static func systemPath(_ path: String) -> String { LocalFilePath.systemCanonical(path) }
    private func normalized(_ path: String, defaultRoot: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\0") else { throw AIFileToolError.invalidPath }
        let expanded = path == "~" || path.hasPrefix("~/") ? (path as NSString).expandingTildeInPath : path.hasPrefix("/") ? path : defaultRoot + "/" + path
        return Self.systemPath(expanded)
    }
    private func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
    func openDirectory(_ path: String) throws -> FD {
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
        do { return Root(path: path, id: id, fd: try openDirectory(path), access: accessed, scope: scope) }
        catch { accessed?.stopAccessingSecurityScopedResource(); throw error }
    }
    static func isLocallyMaterialized(_ info: stat) -> Bool { info.st_flags & UInt32(SF_DATALESS) == 0 }
    func openChild(_ parent: FD, _ name: String) throws -> FD {
        var before = stat()
        guard fstatat(parent.raw, name, &before, AT_SYMLINK_NOFOLLOW) == 0, Self.isLocallyMaterialized(before) else { throw AIFileToolError.unavailable }
        let fd = try FD(openat(parent.raw, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC))
        guard Self.isLocallyMaterialized(try status(fd.raw)) else { throw AIFileToolError.unavailable }
        return fd
    }
    func same(_ first: FD, _ second: FD) throws -> Bool {
        let a = try status(first.raw), b = try status(second.raw)
        return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode & S_IFMT == b.st_mode & S_IFMT
    }
    func pathOf(_ fd: FD) throws -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd.raw, F_GETPATH, &bytes) == 0 else { throw AIFileToolError.stale }
        return Self.systemPath(String(cString: bytes))
    }
    func anonymousStage() throws -> FD {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneAIStage-" + UUID().uuidString).path
        let fd = try FD(Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        guard unlink(path) == 0 else { throw AIFileToolError.unavailable }
        return fd
    }
    func absent(_ parent: FD, _ name: String) throws {
        var info = stat()
        guard fstatat(parent.raw, name, &info, AT_SYMLINK_NOFOLLOW) != 0 else { throw AIFileToolError.exists }
        guard errno == ENOENT else { throw AIFileToolError.unavailable }
    }
    func validate(_ plan: Prepared, checkTarget: Bool = true) throws {
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
    func status(_ file: FD) throws -> stat { try withExtendedLifetime(file) { try status(file.raw) } }
    func status(_ fd: Int32) throws -> stat { var info = stat(); guard fstat(fd, &info) == 0 else { throw AIFileToolError.unavailable }; return info }
    private func isDirectory(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFDIR }
    func isRegular(_ info: stat) -> Bool { info.st_mode & S_IFMT == S_IFREG }
    func revision(_ info: stat) -> String {
        let value = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec):\(info.st_mode):\(info.st_flags)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func metadata(_ info: stat, path: String) -> [String: AIToolValue] {
        ["path": .string(path), "type": .string(isDirectory(info) ? "directory" : "file"), "size": .number(Double(info.st_size)), "modified": .string(Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)).ISO8601Format()), "revision": .string(revision(info))]
    }
    func read(_ fd: Int32, offset: Int, count: Int, check: () throws -> Void) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 16_384))
        while data.count < count {
            try check()
            let size = min(buffer.count, count - data.count)
            guard Self.isLocallyMaterialized(try status(fd)) else { throw AIFileToolError.unavailable }
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
        let full = entry.relative == "." ? root.path : (root.path == "/" ? "" : root.path) + "/" + entry.relative
        try policy(full)
        var current = root.fd
        for name in entry.relative.split(separator: "/") where name != "." { current = try openChild(current, String(name)) }
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
    private func walk(_ fd: FD, plan: Prepared, relative: String, patternRelative: String, pattern: String, matcher: AIFileTextMatcher, grep: Bool, depth: Int, limit: Int, hidden: Bool, captureHandles: Bool, scan: inout Scan, rows: inout [AIToolValue], disclosed: inout [Disclosure], check: () throws -> Void) throws {
        if scan.exhausted || rows.count >= limit { scan.truncated = true; return }
        for name in try names(fd.raw, scan: &scan, check: check) {
            try check()
            if (!hidden && name.hasPrefix(".")) || [".git", "node_modules"].contains(name) { continue }
            let rel = joined(relative, name), patternPath = joined(patternRelative.isEmpty ? "." : patternRelative, name)
            guard let (child, info) = try inspect(fd, name: name, plan: plan, relative: rel) else { continue }
            if matches(pattern, patternPath) {
                if !grep {
                    rows.append(.object(metadata(info, path: rel)))
                    if captureHandles { disclosed.append(.init(fd: child, relative: rel, revision: revision(info))) }
                }
                else if isRegular(info), info.st_size <= 1_048_576 {
                    guard scan.bytes + Int(info.st_size) <= 8_388_608 else { scan.truncated = true; scan.exhausted = true; return }
                    scan.bytes += Int(info.st_size)
                    if let text = String(data: try read(child.raw, offset: 0, count: Int(info.st_size), check: check), encoding: .utf8), !hasBinaryControls(text) {
                        guard revision(try status(child.raw)) == revision(info) else { throw AIFileToolError.stale }
                        var cursor = text.startIndex, number = 1
                        while cursor < text.endIndex {
                            try check()
                            // CRLF is one Swift Character; recognize the complete newline boundary.
                            let end = text[cursor...].firstIndex(where: { $0.isNewline }) ?? text.endIndex
                            let line = text[cursor..<end]
                            if try matcher.contains(String(line), check: check) {
                                let row = AIToolValue.object(["path": .string(rel), "line": .number(Double(number)), "text": .string(String(line.unicodeScalars.prefix(240))), "revision": .string(revision(info))])
                                if scan.outputBytes + (try JSONEncoder().encode(row).count) > (captureHandles ? 24_000 : 2_000_000) { scan.truncated = true; scan.exhausted = true; return }
                                scan.outputBytes += try JSONEncoder().encode(row).count
                                rows.append(row)
                                if captureHandles { disclosed.append(.init(fd: child, relative: rel, revision: revision(info))) }
                                if rows.count >= limit { scan.truncated = true; scan.exhausted = true; return }
                            }
                            if end == text.endIndex { break }; cursor = text.index(after: end); number += 1
                        }
                    }
                }
                if !grep { scan.outputBytes += try JSONEncoder().encode(rows.last!).count }
                if scan.outputBytes > (captureHandles ? 24_000 : 2_000_000) { rows.removeLast(); scan.truncated = true; scan.exhausted = true; return }
                if rows.count >= limit { scan.truncated = true; scan.exhausted = true; return }
            }
            if isDirectory(info) {
                if scan.exhausted { continue }
                if depth == 1 { scan.truncated = true; continue }
                try walk(child, plan: plan, relative: rel, patternRelative: patternPath, pattern: pattern, matcher: matcher, grep: grep, depth: depth - 1, limit: limit, hidden: hidden, captureHandles: captureHandles, scan: &scan, rows: &rows, disclosed: &disclosed, check: check)
                if scan.exhausted { return }
            }
        }
    }
    private func openDisclosure(relative: String, plan: Prepared) throws -> Disclosure {
        let full = relative == "." ? plan.roots[0].path : (plan.roots[0].path == "/" ? "" : plan.roots[0].path) + "/" + relative
        try policy(full)
        guard contains(plan.localTarget, full) else { throw AIFileToolError.outsideScope }
        var fd = plan.roots[0].fd
        for name in relative.split(separator: "/") where name != "." { fd = try openChild(fd, String(name)) }
        let info = try status(fd.raw)
        guard isDirectory(info) || isRegular(info) && info.st_nlink == 1, try pathOf(fd) == full else { throw AIFileToolError.stale }
        return .init(fd: fd, relative: relative, revision: revision(info))
    }
    private func utf8Chunk(_ input: Data, offset: Int, end: Int) throws -> (String, Int) {
        var data = input, text = String(data: input, encoding: .utf8)
        for _ in 0..<3 where text == nil && !data.isEmpty { data.removeLast(); text = String(data: data, encoding: .utf8) }
        guard let text, !hasBinaryControls(text), !data.isEmpty || offset >= end else { throw AIFileToolError.invalidText }
        return (text, offset + data.count)
    }
    private func textPage(_ plan: Prepared, offset: Int, limit: Int, check: () throws -> Void) throws -> ([String: AIToolValue], ReadReference?) {
        guard let fd = plan.file, offset >= 0, (1...4096).contains(limit) else { throw AIFileToolError.invalidPath }
        let info = try status(fd.raw)
        let (text, next) = try utf8Chunk(read(fd.raw, offset: offset, count: limit, check: check), offset: offset, end: Int(info.st_size))
        return (["path": .string(plan.relativePath), "type": .string("file"), "text": .string(text), "revision": .string(revision(info)),
            "offset": .number(Double(offset)), "next_offset": next < info.st_size ? .number(Double(next)) : .null, "truncated": .bool(next < info.st_size)],
            next < info.st_size ? ReadReference(plan: plan, payload: .text(offset: next)) : nil)
    }
    private func documentPage(_ blob: AITemporaryReadResult, pages: Int, plan: Prepared, offset: Int, limit: Int, format: String = "pdf", ocr: Bool = false, check: () throws -> Void) throws -> ([String: AIToolValue], ReadReference?) {
        guard (1...4096).contains(limit) else { throw AIFileToolError.invalidPath }
        let (text, next) = try utf8Chunk(blob.read(offset: offset, limit: limit, check: check), offset: offset, end: blob.count)
        return (["path": .string(plan.relativePath), "type": .string("document"), "format": .string(format), format == "pdf" ? "page_count" : "section_count": .number(Double(pages)), "ocr": .bool(ocr),
            "text": .string(text), "offset": .number(Double(offset)), "next_offset": next < blob.count ? .number(Double(next)) : .null, "truncated": .bool(next < blob.count)],
            next < blob.count ? ReadReference(plan: plan, payload: .document(blob, offset: next, pages: pages, format: format, ocr: ocr)) : nil)
    }
    private func rowsPage(_ rows: [AIToolValue], plan: Prepared, key: String, sourceTruncated: Bool, offset: Int, limit: Int,
                          blob: AITemporaryReadResult? = nil, disclosed: inout [Disclosure], check: () throws -> Void) throws -> ([String: AIToolValue], ReadReference?) {
        guard (0...rows.count).contains(offset), (1...100).contains(limit) else { throw AIFileToolError.invalidPath }
        var page: [AIToolValue] = [], next = offset, bytes = 0
        for row in rows.dropFirst(offset).prefix(limit) {
            try check()
            guard case .object(let fields) = row, case .string(let relative) = fields["path"], case .string(let expected) = fields["revision"] else { throw AIFileToolError.stale }
            let size = try JSONEncoder().encode(row).count
            if bytes + size > 24_000 { if page.isEmpty { throw AIFileToolError.tooLarge }; break }
            let entry = try openDisclosure(relative: relative, plan: plan)
            guard entry.revision == expected else { throw AIFileToolError.stale }
            disclosed.append(entry); page.append(row); next += 1; bytes += size
        }
        let more = next < rows.count
        let reference: ReadReference?
        if more {
            let file = try blob ?? AITemporaryReadResult(JSONEncoder().encode(rows))
            reference = ReadReference(plan: plan, payload: .rows(file, key: key, offset: next, sourceTruncated: sourceTruncated))
        } else { reference = nil }
        return (["path": .string(plan.relativePath), "type": .string(key == "entries" ? "directory" : "search_results"), key: .array(page), "next_offset": more ? .number(Double(next)) : .null,
            "truncated": .bool(sourceTruncated || more), "source_truncated": .bool(sourceTruncated)], reference)
    }
    func output(_ values: [String: AIToolValue]) throws -> AIToolResult { try .init(text: String(decoding: JSONEncoder().encode(values), as: UTF8.self)) }
    private func hasBinaryControls(_ text: String) -> Bool { text.unicodeScalars.contains { $0.value < 32 && ![9, 10, 13].contains($0.value) } }
    func string(_ args: [String: AIToolValue], _ key: String) -> String { if case .string(let text) = args[key] { return text }; return "" }
    func integer(_ args: [String: AIToolValue], _ key: String, default value: Int) -> Int { if case .number(let n) = args[key], n.isFinite, n.rounded() == n, n >= 0, n <= 1_073_741_824 { return Int(n) }; return value }
    private func boolean(_ args: [String: AIToolValue], _ key: String) -> Bool { if case .bool(let value) = args[key] { return value }; return false }
}
