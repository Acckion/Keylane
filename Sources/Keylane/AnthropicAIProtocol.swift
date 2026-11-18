import Foundation
import KeylaneCore

enum AnthropicAIProtocol {
    static func body(connection: AIConnection, messages: [AIMessage]) throws -> Data {
        var payload: [String: Any] = [
            "model": connection.model, "max_tokens": 4096, "stream": connection.mode == .streaming,
            "messages": messages.filter { $0.role != .system }.map {
                ["role": $0.role.rawValue, "content": $0.content]
            }
        ]
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        if !system.isEmpty { payload["system"] = system }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    static func receive(_ bytes: URLSession.AsyncBytes, streaming: Bool,
                        emit: @Sendable (String) async throws -> Void) async throws -> Int? {
        if !streaming {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 1_048_576 else { throw AIResponseError.tooLarge }
                data.append(byte)
            }
            let event = try object(data)
            guard event["type"] as? String == "message", event["stop_reason"] as? String == "end_turn" else {
                throw AIResponseError.incomplete
            }
            let content = event["content"] as? [[String: Any]] ?? []
            let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw AIResponseError.invalidResponse }
            try await emit(text)
            let usage = event["usage"] as? [String: Int]
            return usage.map { ($0["input_tokens"] ?? 0) + ($0["output_tokens"] ?? 0) }
        }
        var line = Data()
        var dataLines = [String]()
        var count = 0
        var ended = false
        var stopReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var pending = ""
        var receivedText = false
        let clock = ContinuousClock()
        var nextUpdate = clock.now
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= 1_048_576 else { throw AIResponseError.tooLarge }
            if byte != 10 { line.append(byte); continue }
            guard let text = String(data: line, encoding: .utf8) else { throw AIResponseError.invalidResponse }
            line.removeAll(keepingCapacity: true)
            let clean = text.hasSuffix("\r") ? String(text.dropLast()) : text
            if clean.hasPrefix("data:") {
                dataLines.append(String(clean.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
            guard clean.isEmpty, !dataLines.isEmpty else { continue }
            let event = try object(Data(dataLines.joined(separator: "\n").utf8))
            dataLines.removeAll(keepingCapacity: true)
            switch event["type"] as? String {
            case "error": throw AIResponseError.serviceError
            case "message_start":
                let message = event["message"] as? [String: Any]
                let usage = message?["usage"] as? [String: Int]
                inputTokens = usage?["input_tokens"]
                outputTokens = usage?["output_tokens"]
            case "content_block_start":
                let block = event["content_block"] as? [String: Any]
                if block?["type"] as? String == "text", let text = block?["text"] as? String { pending += text }
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { pending += text }
            case "message_delta":
                stopReason = (event["delta"] as? [String: Any])?["stop_reason"] as? String
                outputTokens = (event["usage"] as? [String: Int])?["output_tokens"] ?? outputTokens
            case "message_stop": ended = true
            default: break
            }
            if !pending.isEmpty, ended || clock.now >= nextUpdate {
                receivedText = true
                try await emit(pending)
                pending = ""
                nextUpdate = clock.now + .milliseconds(40)
            }
            if ended { break }
        }
        if !pending.isEmpty { receivedText = true; try await emit(pending) }
        guard ended, stopReason == "end_turn" else { throw AIResponseError.incomplete }
        guard receivedText else { throw AIResponseError.invalidResponse }
        return inputTokens.flatMap { input in outputTokens.map { input + $0 } }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIResponseError.invalidResponse
        }
        return result
    }
}
