import Foundation
import Vision

enum ImageTextRecognition: Sendable {
    case ocr, qr

    func recognize(in handler: VNImageRequestHandler, accurate: Bool, work: ImageTextRecognitionWork = .init()) throws -> String {
        switch self {
        case .ocr:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accurate ? .accurate : .fast
            request.automaticallyDetectsLanguage = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
            try work.perform(request, in: handler)
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        case .qr:
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try work.perform(request, in: handler)
            var seen = Set<String>()
            return (request.results ?? []).compactMap(\.payloadStringValue)
                .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
        }
    }

    var emptyMessage: String { self == .qr ? "未识别到二维码文本。" : "未识别到图片文字。" }
}

final class ImageTextRecognitionWork: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var visionRequest: VNRequest?
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    func cancel() {
        lock.lock()
        stopped = true
        let request = visionRequest
        lock.unlock()
        request?.cancel()
    }

    func perform(_ request: VNRequest, in handler: VNImageRequestHandler) throws {
        lock.lock()
        guard !stopped else { lock.unlock(); throw CancellationError() }
        visionRequest = request
        lock.unlock()
        defer { lock.lock(); visionRequest = nil; lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try handler.perform([request])
    }
}
