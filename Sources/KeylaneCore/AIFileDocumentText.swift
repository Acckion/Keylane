import Foundation
import PDFKit
import Vision
import CoreGraphics

/// One bounded PDF parser shared by explicit attachments and consent-scoped file tools.
/// Input must already have been read from the caller's verified file descriptor.
public enum AIFileDocumentText {
    public enum Failure: LocalizedError {
        case unsupported, tooLarge, empty, ocrFailed
        public var errorDescription: String? {
            switch self {
            case .unsupported: "文档无法解析、格式不支持或需要密码；不自动下载文件或请求密码。"
            case .tooLarge: "文档超过本次文件、页数、提取文字或识别预算。"
            case .ocrFailed: "本机 OCR 无法识别此页；没有向云端 OCR 服务发送图片。"
            case .empty: "文档没有可提取文字；扫描 PDF 可显式启用本机 OCR。"
            }
        }
    }
    public static func pdfPages(_ data: Data, ocr: Bool = false, work: ImageTextRecognitionWork = .init(), maximumPages: Int = 100, maximumTextBytes: Int = 2_097_152,
                                check: () throws -> Void = { try Task.checkCancellation() }) throws -> [String] {
        try check()
        guard (1...100).contains(maximumPages), (1...2_097_152).contains(maximumTextBytes), data.count <= 8_388_608 else { throw Failure.tooLarge }
        guard data.prefix(5) == Data("%PDF-".utf8), let document = PDFDocument(data: data), !document.isLocked else { throw Failure.unsupported }
        guard document.pageCount > 0, document.pageCount <= maximumPages else { throw Failure.tooLarge }
        var pages: [String] = [], size = 0, hasText = false, recognized = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        for index in 0..<document.pageCount {
            try check()
            guard let page = document.page(at: index) else { throw Failure.unsupported }
            var text = page.string ?? ""
            if ocr && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recognized += 1
                guard recognized <= 10, ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.tooLarge }
                try check()
                do {
                    text = try autoreleasepool {
                        let image = try raster(page)
                        return try LocalImageTextRecognition.ocr.recognize(in: VNImageRequestHandler(cgImage: image), accurate: true,
                            work: work, maximumDuration: min(5, deadline - ProcessInfo.processInfo.systemUptime))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch LocalImageTextRecognition.Failure.timeLimit { throw Failure.tooLarge }
                catch { throw Failure.ocrFailed }
                try check()
            }
            size += text.utf8.count + (index == 0 ? 0 : 2)
            guard size <= maximumTextBytes else { throw Failure.tooLarge }
            hasText = hasText || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            pages.append(text)
        }
        guard hasText else { throw Failure.empty }
        try check()
        return pages
    }
    private static func raster(_ page: PDFPage) throws -> CGImage {
        guard let reference = page.pageRef else { throw Failure.unsupported }
        let box = reference.getBoxRect(.cropBox)
        guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else { throw Failure.unsupported }
        let rotated = abs(reference.rotationAngle % 180) == 90
        let w = rotated ? box.height : box.width, h = rotated ? box.width : box.height
        let scale = min(2.5, 2000 / max(w, h))
        let width = max(1, Int((w * scale).rounded(.up))), height = max(1, Int((h * scale).rounded(.up)))
        guard width * height <= 4_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.tooLarge }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard let image = context.makeImage() else { throw Failure.ocrFailed }
        return image
    }
}
