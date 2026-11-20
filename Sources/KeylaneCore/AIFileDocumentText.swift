import Foundation
import PDFKit

/// One bounded PDF parser shared by explicit attachments and consent-scoped file tools.
/// Input must already have been read from the caller's verified file descriptor.
public enum AIFileDocumentText {
    public enum Failure: LocalizedError {
        case unsupported, tooLarge, empty
        public var errorDescription: String? {
            switch self {
            case .unsupported: "PDF 无法解析或已加密；不自动下载文件或请求密码。"
            case .tooLarge: "PDF 超过本次文件、页数或提取文字额度。"
            case .empty: "PDF 没有可提取文字；扫描件 OCR 尚未接入。"
            }
        }
    }
    public static func pdfPages(_ data: Data, maximumPages: Int = 100, maximumTextBytes: Int = 2_097_152,
                                check: () throws -> Void = { try Task.checkCancellation() }) throws -> [String] {
        try check()
        guard (1...100).contains(maximumPages), (1...2_097_152).contains(maximumTextBytes), data.count <= 8_388_608 else { throw Failure.tooLarge }
        guard data.prefix(5) == Data("%PDF-".utf8), let document = PDFDocument(data: data), !document.isLocked else { throw Failure.unsupported }
        guard document.pageCount > 0, document.pageCount <= maximumPages else { throw Failure.tooLarge }
        var pages: [String] = [], size = 0, hasText = false
        for index in 0..<document.pageCount {
            try check()
            let text = document.page(at: index)?.string ?? ""
            size += text.utf8.count + (index == 0 ? 0 : 2)
            guard size <= maximumTextBytes else { throw Failure.tooLarge }
            hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            pages.append(text)
        }
        guard hasText else { throw Failure.empty }
        try check()
        return pages
    }
}
