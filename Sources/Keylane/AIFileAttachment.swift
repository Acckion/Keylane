import AppKit
import Darwin
import Foundation
import KeylaneCore

struct AIFileAttachment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    let name: String
    let text: String
    let byteCount: Int

    var attachment: AIConversationAttachment {
        var result = AIConversationAttachment(title: name, text: text, symbol: "doc")
        result.id = id
        return result
    }

    static func read(_ url: URL, maximumFileBytes: Int = 8_388_608, maximumTextBytes: Int = 32_000, expectedVersion: AIFileReadVersion? = nil) throws -> Self {
        guard (0...8_388_608).contains(maximumFileBytes), (0...40_000).contains(maximumTextBytes) else { throw Failure("读取额度无效。") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        return try readOpened(fd, url: url, maximumFileBytes: maximumFileBytes, maximumTextBytes: maximumTextBytes,
                              expectedVersion: expectedVersion) { try AIFileReadVersion(url) }.file
    }

    private static func readOpened(_ fd: Int32, url: URL, maximumFileBytes: Int, maximumTextBytes: Int,
                                   expectedVersion: AIFileReadVersion? = nil,
                                   validateOpened: (Int32) throws -> Void = { _ in },
                                   currentVersion: () throws -> AIFileReadVersion) throws -> (file: Self, version: AIFileReadVersion) {
        guard fd >= 0 else { throw Failure("无法读取所选文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try validateOpened(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumFileBytes else { throw Failure("请选择未超出当前大小上限的普通文件。") }
        if let expectedVersion, AIFileReadVersion(info) != expectedVersion { throw Failure("文件已变化，请重新搜索。") }
        try Task.checkCancellation()
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw Failure("文件超过当前大小上限。") }
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            text = try AIFileDocumentText.pdfPages(data, maximumTextBytes: max(1, maximumTextBytes)).joined(separator: "\n\n")
        } else if AIFileOfficeText.extensions.contains(url.pathExtension.lowercased()) {
            text = try AIFileOfficeText.sections(data, extension: url.pathExtension.lowercased(), maximumTextBytes: max(1, maximumTextBytes)).joined(separator: "\n\n")
        } else {
            guard let extracted = String(data: data, encoding: .utf8), !extracted.contains("\0") else {
                throw Failure("目前支持 UTF-8 文本、代码、Markdown、CSV、JSON、DOCX/XLSX/PPTX 和有文字的 PDF。")
            }
            text = extracted
        }
        guard text.utf8.count <= maximumTextBytes else { throw Failure("文件文字超过当前处理额度，请缩小范围后重试。") }
        try Task.checkCancellation()
        var after = stat()
        guard fstat(fd, &after) == 0, AIFileReadVersion(info) == AIFileReadVersion(after),
              try currentVersion() == AIFileReadVersion(after) else { throw Failure("读取期间文件已变化。") }
        return (.init(name: url.lastPathComponent, text: text, byteCount: data.count), .init(after))
    }

    static func resourceReader(_ url: URL, bind: (URL) throws -> ApprovedPickerRoute = ApprovedPickerRoute.init) -> AIResourceReader {
        let module = ModuleID(rawValue: "keylane.files")
        let identity = url.standardizedFileURL.absoluteString
        // Capture the approved route at picker selection; never acquire a fresh
        // approval from whatever occupies the lexical path on refresh.
        let selection = Result<PickerSelection, Error> {
            do { return .refreshable(try bind(url)) }
            catch let PickerBindingFailure.parentAccess(path) { return .initialOnly(path) }
        }
        let allowsRefresh: Bool
        if case .success(.refreshable) = selection { allowsRefresh = true } else { allowsRefresh = false }
        let source = AIActionSource(moduleID: module, load: {
            let work = Task.detached(priority: .userInitiated) {
                let (file, version) = try selection.get().read(url)
                return AIActionContext(sourceID: identity, title: file.name, text: file.text, fingerprint: version.fingerprint)
            }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }, isCurrent: { context in
            let work = Task.detached(priority: .userInitiated) { try selection.get().version(url).fingerprint == context.fingerprint }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        })
        return .init(source: source, symbol: "doc", allowsRefresh: allowsRefresh)
    }

    enum PickerBindingFailure: Error { case parentAccess(String) }

    private enum PickerSelection: Sendable {
        case refreshable(ApprovedPickerRoute)
        case initialOnly(String)

        func read(_ url: URL) throws -> (AIFileAttachment, AIFileReadVersion) {
            switch self {
            case let .refreshable(route): return try route.read(url)
            case let .initialOnly(path):
                // The explicit picker can grant the file without granting its
                // directory. Use that one selection, never vend a refresh reader.
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let expected = try initialVersion(of: url, path: path)
                try Task.checkCancellation()
                let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                return try AIFileAttachment.readOpened(fd, url: url, maximumFileBytes: 8_388_608, maximumTextBytes: 32_000,
                                                       expectedVersion: expected, validateOpened: { fd in
                    guard try ApprovedPickerRoute.descriptorPath(fd) == path,
                          try ApprovedPickerRoute.selectionPath(url) == path else { throw AIActionError.staleSource }
                }) { try initialVersion(of: url, path: path) }
            }
        }

        func version(_ url: URL) throws -> AIFileReadVersion {
            switch self {
            case let .refreshable(route): return try route.version(url)
            case let .initialOnly(path):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try initialVersion(of: url, path: path)
            }
        }

        private func initialVersion(of url: URL, path: String) throws -> AIFileReadVersion {
            guard try ApprovedPickerRoute.selectionPath(url) == path else { throw AIActionError.staleSource }
            return try AIFileReadVersion(URL(fileURLWithPath: path))
        }
    }

    /// The picker approves a name in one canonical directory, not a perpetual
    /// grant to follow the same lexical route to a different directory.
    struct ApprovedPickerRoute: Sendable {
        private let parentPath: String
        private let name: String
        private let device: Int32
        private let inode: UInt64
        private let requiresSecurityScope: Bool

        init(_ url: URL) throws {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let (parent, name) = try Self.route(url)
            let fd = open(parent, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                // A moved or missing previously selected route is not a fallback.
                guard errno == EACCES || errno == EPERM else { throw AIActionError.staleSource }
                throw PickerBindingFailure.parentAccess(URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(name).path)
            }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw AIActionError.staleSource }
            parentPath = parent; self.name = name; device = info.st_dev; inode = info.st_ino
            requiresSecurityScope = access
            try validate(fd, url: url)
        }

        func read(_ url: URL) throws -> (AIFileAttachment, AIFileReadVersion) {
            try withValidatedParent(of: url) { fd in
                let expected = try version(in: fd)
                try validate(fd, url: url)
                let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                return try AIFileAttachment.readOpened(file, url: url, maximumFileBytes: 8_388_608, maximumTextBytes: 32_000,
                                                       expectedVersion: expected) { try version(in: fd) }
            }
        }

        func version(_ url: URL) throws -> AIFileReadVersion {
            try withValidatedParent(of: url) { try version(in: $0) }
        }

        func withValidatedParent<T>(of url: URL, _ body: (Int32) throws -> T) throws -> T {
            try Self.withPickerScope(required: requiresSecurityScope,
                                     start: { url.startAccessingSecurityScopedResource() },
                                     stop: { url.stopAccessingSecurityScopedResource() }) {
                let fd = open(parentPath, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw AIActionError.staleSource }
                defer { close(fd) }
                try validate(fd, url: url)
                try Task.checkCancellation()
                let result = try body(fd)
                try validate(fd, url: url)
                return result
            }
        }

        static func withPickerScope<T>(required: Bool, start: () -> Bool, stop: () -> Void, _ body: () throws -> T) throws -> T {
            let access = start()
            defer { if access { stop() } }
            // If permission came from a scoped URL, never substitute ambient access.
            // Plain file URLs do not carry a scope and still use normal file permissions.
            guard !required || access else { throw AIActionError.staleSource }
            return try body()
        }

        private static func route(_ url: URL) throws -> (parent: String, name: String) {
            let name = url.lastPathComponent
            guard url.isFileURL, !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0"),
                  !AIFileToolService.isRecoveryStorage(url.path) else { throw AIActionError.staleSource }
            let parent = AIFileToolService.systemPath(url.deletingLastPathComponent().resolvingSymlinksInPath().path)
            guard !AIFileToolService.isRecoveryStorage(parent) else { throw AIActionError.staleSource }
            return (parent, name)
        }

        static func selectionPath(_ url: URL) throws -> String {
            let (parent, name) = try route(url)
            return URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(name).path
        }

        static func descriptorPath(_ fd: Int32) throws -> String {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &path) == 0 else { throw AIActionError.staleSource }
            return AIFileToolService.systemPath(String(cString: path))
        }

        private func validate(_ fd: Int32, url: URL) throws {
            let (parent, selectedName) = try Self.route(url)
            var opened = stat(), current = stat()
            guard parent == parentPath, selectedName == name,
                  fstat(fd, &opened) == 0, opened.st_dev == device, opened.st_ino == inode,
                  try Self.descriptorPath(fd) == parentPath,
                  lstat(parentPath, &current) == 0, current.st_mode & S_IFMT == S_IFDIR,
                  current.st_dev == device, current.st_ino == inode else { throw AIActionError.staleSource }
        }

        private func version(in fd: Int32) throws -> AIFileReadVersion {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG else {
                throw AIActionError.staleSource
            }
            return .init(info)
        }
    }

    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}

/// Descriptor and pathname must refer to the same unchanged regular file.
struct AIFileReadVersion: Equatable, Sendable {
    private let device: Int32
    private let inode: UInt64
    private let size: Int64
    private let seconds: Int
    private let nanos: Int
    private let changeSeconds: Int
    private let changeNanos: Int
    private let mode: UInt16
    private let flags: UInt32
    var fingerprint: String {
        AIActionContext.digest("\(device):\(inode):\(size):\(seconds):\(nanos):\(changeSeconds):\(changeNanos):\(mode):\(flags)")
    }
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        seconds = info.st_mtimespec.tv_sec; nanos = info.st_mtimespec.tv_nsec
        changeSeconds = info.st_ctimespec.tv_sec; changeNanos = info.st_ctimespec.tv_nsec
        mode = info.st_mode; flags = info.st_flags
    }
    init(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw AIFileAttachment.Failure("请选择普通文件。") }
        self.init(info)
    }
}
