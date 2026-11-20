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

    static func read(_ url: URL, maximumFileBytes: Int = 8_388_608, maximumTextBytes: Int = 32_000) throws -> Self {
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
        let data = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
        guard data.count <= maximumFileBytes else { throw Failure("文件超过 8 MB。") }
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
        return .init(name: url.lastPathComponent, text: text, byteCount: data.count)
    }

    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
