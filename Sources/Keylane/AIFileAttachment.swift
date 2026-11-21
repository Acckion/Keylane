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
        guard fd >= 0 else { throw Failure("无法读取所选文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
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
        } else {
            guard let extracted = String(data: data, encoding: .utf8), !extracted.contains("\0") else {
                throw Failure("目前支持 UTF-8 文本、代码、Markdown、CSV、JSON 和有文字的 PDF。")
            }
            text = extracted
        }
        guard text.utf8.count <= maximumTextBytes else { throw Failure("文件文字超过当前处理额度，请缩小范围后重试。") }
        try Task.checkCancellation()
        var after = stat()
        guard fstat(fd, &after) == 0, AIFileReadVersion(info) == AIFileReadVersion(after),
              try AIFileReadVersion(url) == AIFileReadVersion(after) else { throw Failure("读取期间文件已变化。") }
        return .init(name: url.lastPathComponent, text: text, byteCount: data.count)
    }

    static func resourceReader(_ url: URL) -> AIResourceReader {
        let module = ModuleID(rawValue: "keylane.files")
        let identity = url.standardizedFileURL.absoluteString
        let source = AIActionSource(moduleID: module, load: {
            let work = Task.detached(priority: .userInitiated) {
                let version = try AIFileReadVersion(url)
                let file = try read(url, expectedVersion: version)
                return AIActionContext(sourceID: identity, title: file.name, text: file.text, fingerprint: version.fingerprint)
            }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }, isCurrent: { context in
            try await Task.detached(priority: .userInitiated) { try AIFileReadVersion(url).fingerprint == context.fingerprint }.value
        })
        return .init(source: source, symbol: "doc")
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
