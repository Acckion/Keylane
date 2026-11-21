import Foundation

public enum AITranscriptionError: LocalizedError, Equatable {
    case configuration, missingKey, invalidAudio, audioTooLarge, emptyTranscript, invalidResponse, responseTooLarge
    case http(Int)
    public var errorDescription: String? {
        switch self {
        case .configuration: "请在 AI 设置中添加语音转写模型，并在听写中选择。"
        case .missingKey: "请在 AI 设置中为此模型保存 API Key。"
        case .invalidAudio: "没有录到可用的声音，请检查麦克风后重试。"
        case .audioTooLarge: "录音超过云端接口的 25 MB 上传限制，请缩短录音。"
        case .emptyTranscript: "没有识别到文字。录音可从听写历史中重试。"
        case .invalidResponse: "云端未返回可用的转写结果。"
        case .responseTooLarge: "云端响应过大，已停止读取。"
        case .http(let status):
            switch status {
            case 401, 403: "云端拒绝访问，请检查 API Key 和模型权限（\(status)）。"
            case 429: "云端额度不足或请求过于频繁，请稍后重试（429）。"
            default: "云端转写失败（HTTP \(status)），可从听写历史中重试。"
            }
        }
    }
}

public enum AITranscriptionRequest {
    public static let maximumAudioBytes = 25_000_000
    public static let maximumResponseBytes = 1_048_576

    public static func make(options: AITranscriptionOptions, key: String, audio: Data, boundary: String = "Keylane-" + UUID().uuidString) throws -> URLRequest {
        guard options.isConfigured, let url = options.transcriptionURL else { throw AITranscriptionError.configuration }
        guard !key.isEmpty, key.utf8.count <= 8192, key.rangeOfCharacter(from: .controlCharacters) == nil else { throw AITranscriptionError.missingKey }
        guard !audio.isEmpty else { throw AITranscriptionError.invalidAudio }
        guard audio.count <= maximumAudioBytes else { throw AITranscriptionError.audioTooLarge }
        guard boundary.rangeOfCharacter(from: .controlCharacters) == nil else { throw AITranscriptionError.configuration }
        if options.provider == .openRouter {
            // Keylane records m4a AAC. OpenRouter's STT API accepts raw audio as base64 JSON.
            var payload: [String: Any] = ["model": options.model,
                "input_audio": ["data": audio.base64EncodedString(), "format": "m4a"]]
            if options.language != "auto", !options.language.isEmpty { payload["language"] = options.language }
            if !options.validVocabulary.isEmpty { payload["prompt"] = options.validVocabulary.joined(separator: ", ") }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 180
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request
        }
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field(options.provider == .elevenLabs ? "model_id" : "model", options.model)
        if options.language != "auto", !options.language.isEmpty {
            field(options.provider == .elevenLabs ? "language_code" : "language", options.language)
        }
        if options.provider == .elevenLabs {
            field("tag_audio_events", "false")
            field("diarize", "false")
            field("timestamps_granularity", "none")
            for term in options.validVocabulary where options.model.hasPrefix("scribe_v2") || options.model.hasPrefix("scribe_v3") {
                if term.rangeOfCharacter(from: CharacterSet(charactersIn: "<>{}[]\\")) == nil,
                   term.split(whereSeparator: \.isWhitespace).count <= 5 { field("keyterms", term) }
            }
        } else {
            field("response_format", "json")
            if !options.validVocabulary.isEmpty { field("prompt", options.validVocabulary.joined(separator: ", ")) }
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(options.provider == .elevenLabs ? key : "Bearer " + key,
                         forHTTPHeaderField: options.provider == .elevenLabs ? "xi-api-key" : "Authorization")
        request.httpBody = body
        return request
    }

    public static func text(from data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw AITranscriptionError.http(status) }
        guard data.count <= maximumResponseBytes else { throw AITranscriptionError.responseTooLarge }
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw AITranscriptionError.invalidResponse }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AITranscriptionError.emptyTranscript }
        return text
    }
}
