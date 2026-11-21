import Foundation
import Vision

public enum LocalImageTextRecognition: Sendable {
    case ocr, qr

    public enum Failure: LocalizedError { case timeLimit
        public var errorDescription: String? { "本机文字识别超过时间预算。" }
    }
    public func recognize(in handler: VNImageRequestHandler, accurate: Bool, work: ImageTextRecognitionWork = .init(), maximumDuration: TimeInterval? = nil) throws -> String {
        if work.cancelled { throw CancellationError() }
        if let maximumDuration, maximumDuration <= 0 { throw Failure.timeLimit }
        switch self {
        case .ocr:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accurate ? .accurate : .fast
            request.automaticallyDetectsLanguage = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
            let deadline = maximumDuration.map { ProcessInfo.processInfo.systemUptime + max(0, min($0, 60)) }
            request.progressHandler = { current, _, _ in
                if work.cancelled || deadline.map({ ProcessInfo.processInfo.systemUptime >= $0 }) == true { current.cancel() }
            }
            do { try work.perform(request, in: handler) }
            catch {
                if work.cancelled { throw CancellationError() }
                if deadline.map({ ProcessInfo.processInfo.systemUptime >= $0 }) == true { throw Failure.timeLimit }
                throw error
            }
            if work.cancelled { throw CancellationError() }
            if deadline.map({ ProcessInfo.processInfo.systemUptime >= $0 }) == true { throw Failure.timeLimit }
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

    public var emptyMessage: String { self == .qr ? "未识别到二维码文本。" : "未识别到图片文字。" }
}

public final class ImageTextRecognitionWork: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var visionRequest: VNRequest?
    public var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    public init() {}

    public func cancel() {
        lock.lock()
        stopped = true
        let request = visionRequest
        lock.unlock()
        request?.cancel()
    }

    public func perform(_ request: VNRequest, in handler: VNImageRequestHandler) throws {
        lock.lock()
        guard !stopped else { lock.unlock(); throw CancellationError() }
        visionRequest = request
        lock.unlock()
        defer { lock.lock(); visionRequest = nil; lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try handler.perform([request])
    }
}
