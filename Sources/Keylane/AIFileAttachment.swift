import AppKit
import Darwin
import Foundation
import PDFKit

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

    static func read(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("无法读取所选文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 8_388_608 else { throw Failure("请选择不超过 8 MB 的普通文件。") }
        let data = try handle.read(upToCount: 8_388_609) ?? Data()
        guard data.count <= 8_388_608 else { throw Failure("文件超过 8 MB。") }
        let text: String
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount <= 100,
                  let extracted = pdf.string, !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Failure("PDF 需要包含可提取文字，且不超过 100 页。") }
            text = extracted
        } else {
            guard let extracted = String(data: data, encoding: .utf8), !extracted.contains("\0") else {
                throw Failure("目前支持 UTF-8 文本、代码、Markdown、CSV、JSON 和有文字的 PDF。")
            }
            text = extracted
        }
        guard text.utf8.count <= 32_000 else { throw Failure("文件文字超过 32,000 字节，请缩短后重试。") }
        return .init(name: url.lastPathComponent, text: text, byteCount: data.count)
    }

    struct Failure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
}
