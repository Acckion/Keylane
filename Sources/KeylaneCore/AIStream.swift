import Foundation

public enum AIResponseError: Error, LocalizedError, Equatable {
    case invalidResponse, incomplete, requestTooLarge, tooLarge, serviceError, http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "无法解析模型响应。"
        case .incomplete: "模型连接提前中断，回复可能不完整。"
        case .requestTooLarge: "要发送的内容超过大小限制。"
        case .tooLarge: "模型响应超过大小限制。"
        case .serviceError: "模型服务返回了错误。"
        case .http(let code): "请求失败（HTTP \(code)）。请检查地址、模型、密钥或服务额度。"
        }
    }
}

public struct AICompletionEnvelope: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public struct Text: Decodable, Sendable { public let content: String? }
        public let message: Text?
        public let delta: Text?
        public let finishReason: String?
        enum CodingKeys: String, CodingKey {
            case message, delta
            case finishReason = "finish_reason"
        }
    }

    public struct Usage: Decodable, Sendable {
        public let totalTokens: Int?
        enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens" }
    }

    public let choices: [Choice]?
    public let usage: Usage?
    public let failed: Bool

    enum CodingKeys: String, CodingKey { case choices, usage, error }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        failed = try values.contains(.error) && !values.decodeNil(forKey: .error)
        choices = try values.decodeIfPresent([Choice].self, forKey: .choices)
        usage = try values.decodeIfPresent(Usage.self, forKey: .usage)
    }
}

/// Parses SSE as bytes so a split UTF-8 scalar cannot corrupt text.
public struct AIStreamDecoder {
    private var line = Data()
    private var event = Data()
    private var skipLineFeed = false
    public private(set) var isDone = false
    public private(set) var hasFinishReason = false
    private let limit = 262_144

    public init() {}

    public mutating func consume(_ byte: UInt8) throws -> AICompletionEnvelope? {
        if skipLineFeed {
            skipLineFeed = false
            if byte == 10 { return nil }
        }
        guard byte == 10 || byte == 13 else {
            guard line.count < limit else { throw AIResponseError.tooLarge }
            line.append(byte)
            return nil
        }
        skipLineFeed = byte == 13
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !event.isEmpty else { return nil }
            defer { event.removeAll(keepingCapacity: true) }
            if event == Data("[DONE]".utf8) { isDone = true; return nil }
            let value = try JSONDecoder().decode(AICompletionEnvelope.self, from: event)
            guard !value.failed else { throw AIResponseError.serviceError }
            if value.choices?.first?.finishReason != nil { hasFinishReason = true }
            return value
        }
        if line.starts(with: "data:".utf8) {
            var payload = line.dropFirst(5)
            if payload.first == 32 { payload = payload.dropFirst() }
            guard event.count + payload.count + 1 <= limit else { throw AIResponseError.tooLarge }
            if !event.isEmpty { event.append(10) }
            event.append(contentsOf: payload)
        }
        return nil
    }

    public func validateEnd() throws {
        guard isDone || (hasFinishReason && line.isEmpty && event.isEmpty) else {
            throw AIResponseError.incomplete
        }
    }
}
