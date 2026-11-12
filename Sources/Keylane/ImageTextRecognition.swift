import Vision

enum ImageTextRecognition: Sendable {
    case ocr, qr

    func recognize(in handler: VNImageRequestHandler, accurate: Bool) throws -> String {
        switch self {
        case .ocr:
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accurate ? .accurate : .fast
            request.automaticallyDetectsLanguage = true
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = ["zh-Hans", "en-US"].filter { supported.contains($0) }
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        case .qr:
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try handler.perform([request])
            var seen = Set<String>()
            return (request.results ?? []).compactMap(\.payloadStringValue)
                .filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
        }
    }

    var emptyMessage: String { self == .qr ? "未识别到二维码文本。" : "未识别到图片文字。" }
}
