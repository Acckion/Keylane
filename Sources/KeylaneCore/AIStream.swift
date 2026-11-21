import Foundation

public enum AIResponseError: Error, LocalizedError, Equatable {
    case invalidImage, visionUnavailable, visualSourceRevoked
    case invalidResponse, incomplete, requestTooLarge, tooLarge, serviceError, toolsUnavailable, http(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "图像格式、尺寸或大小无效，请重新添加。"
        case .visionUnavailable: "所选模型尚未确认支持图像输入，或该连接暂不支持图像传输。请选择支持视觉的 HTTP 模型；图像不会被降级为 OCR 后发送。"
        case .visualSourceRevoked: "屏幕或辅助功能权限已撤销，未发送窗口上下文。请重新授权并采集，或移除相关附件。"
        case .invalidResponse: "无法解析模型响应。"
        case .incomplete: "模型连接提前中断，回复可能不完整。"
        case .requestTooLarge: "要发送的内容超过大小限制。"
        case .tooLarge: "模型响应超过大小限制。"
        case .serviceError: "模型服务返回了错误。"
        case .toolsUnavailable: "当前模型或会话未启用工具调用，工具没有执行。请开启工具或选择支持工具的模型。"
        case .http(let code): "请求失败（HTTP \(code)）。请检查地址、模型、密钥或服务额度。"
        }
    }
}

public struct AICompletionEnvelope: Decodable, Sendable {
    public struct Choice: Decodable, Sendable {
        public struct Text: Decodable, Sendable {
            public struct Tool: Decodable, Sendable {
                public struct Function: Decodable, Sendable { public let name: String?; public let arguments: String? }
                public let index: Int?
                public let id: String?
                public let function: Function?
            }
            public let content: String?
            public let reasoning: String?
            public let toolCalls: [Tool]?
            enum CodingKeys: String, CodingKey { case content, reasoning, reasoningContent = "reasoning_content", reasoningSummary = "reasoning_summary", toolCalls = "tool_calls" }
            public init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                content = try values.decodeIfPresent(String.self, forKey: .content)
                reasoning = (try? values.decode(String.self, forKey: .reasoningSummary))
                    ?? (try? values.decode(String.self, forKey: .reasoningContent))
                    ?? (try? values.decode(String.self, forKey: .reasoning))
                toolCalls = try values.decodeIfPresent([Tool].self, forKey: .toolCalls)
            }
        }
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
    private var events = AISSEEventDecoder()
    public private(set) var isDone = false
    public private(set) var hasFinishReason = false

    public init() {}

    public mutating func consume(_ byte: UInt8) throws -> AICompletionEnvelope? {
        guard let event = try events.consume(byte) else { return nil }
        if event == Data("[DONE]".utf8) { isDone = true; return nil }
        let value = try JSONDecoder().decode(AICompletionEnvelope.self, from: event)
        guard !value.failed else { throw AIResponseError.serviceError }
        if value.choices?.first?.finishReason != nil { hasFinishReason = true }
        return value
    }

    public func validateEnd() throws {
        guard isDone || (hasFinishReason && !events.hasPendingData) else {
            throw AIResponseError.incomplete
        }
    }
}
