import Foundation
import KeylaneCore

/// Owns the protocol transcript for a single generation. No transcript is shared across accounts.
enum AIToolHTTPTransport {
    struct Reply {
        var text = ""
        var thinking = ""
        var calls: [AIToolCall] = []
        var assistant: [String: Any] = [:]
        var tokens: Int?
    }

    static func generate(session: URLSession, connection: AIConnection, key: String?, messages: [AIMessage],
                         tools: AIToolRun, progress: @Sendable (AIResponseEvent) async -> Void,
                         emit: @Sendable (String) async throws -> Void) async throws -> Int? {
        guard let url = connection.completionURL else { throw AIResponseError.invalidResponse }
        let anthropic = connection.protocolKind == .anthropic
        var transcript: [[String: Any]] = messages.filter { !anthropic || $0.role != .system }.map {
            ["role": $0.role.rawValue, "content": $0.content]
        }
        var total = 0
        var hasUsage = false
        while true {
            try await tools.nextRound()
            var body: [String: Any] = ["model": connection.model, "stream": connection.mode == .streaming, "messages": transcript]
            body["tools"] = try tools.catalog.definitions.map { definition -> [String: Any] in
                let function: [String: Any] = ["name": definition.name, "description": definition.description,
                    anthropic ? "input_schema" : "parameters": try AIToolWire.object(definition.inputSchema)]
                return anthropic ? function : ["type": "function", "function": function]
            }
            if anthropic {
                body["max_tokens"] = 4096
                let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
                if !system.isEmpty { body["system"] = system }
            } else { body["tool_choice"] = "auto" }
            if let extraJSON = connection.additionalParametersJSON, let data = extraJSON.data(using: .utf8) {
                guard let extra = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(extra.keys).isDisjoint(with: ["model", "stream", "messages", "tools", "tool_choice", "system"]) else {
                    throw AIResponseError.invalidResponse
                }
                body.merge(extra) { _, new in new }
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(connection.mode == .streaming ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
            if anthropic {
                request.setValue(key, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else if let key, !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
            let data = try JSONSerialization.data(withJSONObject: body)
            guard data.count <= 1_048_576 else { throw AIResponseError.requestTooLarge }
            request.httpBody = data
            try await tools.validateCurrent()
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AIResponseError.invalidResponse }
            guard (200..<300).contains(response.statusCode) else { throw AIResponseError.http(response.statusCode) }
            let reply: Reply
            if connection.mode == .streaming {
                reply = try await stream(bytes, anthropic: anthropic, progress: progress, emit: emit)
            } else {
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < 1_048_576 else { throw AIResponseError.tooLarge }
                    data.append(byte)
                }
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AIResponseError.invalidResponse }
                reply = try decode(object, anthropic: anthropic)
                if !reply.thinking.isEmpty { await progress(.thinking(id: UUID().uuidString, delta: reply.thinking)) }
                if !reply.text.isEmpty { try await emit(reply.text) }
            }
            try await tools.validateCurrent()
            if let usage = reply.tokens, usage >= 0 {
                let (sum, overflow) = total.addingReportingOverflow(usage)
                guard !overflow else { throw AIResponseError.invalidResponse }
                total = sum; hasUsage = true
            }
            guard !reply.calls.isEmpty else {
                guard !reply.text.isEmpty else { throw AIResponseError.invalidResponse }
                return hasUsage ? total : nil
            }
            transcript.append(reply.assistant)
            var results = [[String: Any]]()
            for call in reply.calls {
                let result = try await tools.execute(call, scope: "http", progress: progress)
                if anthropic { results.append(["type": "tool_result", "tool_use_id": call.id, "content": result.text, "is_error": result.isError]) }
                else { transcript.append(["role": "tool", "tool_call_id": call.id, "content": result.text]) }
            }
            if anthropic { transcript.append(["role": "user", "content": results]) }
            if !reply.text.isEmpty { try await emit("\n\n") }
        }
    }

    static func decode(_ object: [String: Any], anthropic: Bool) throws -> Reply {
        guard object["error"] == nil else { throw AIResponseError.invalidResponse }
        var reply = Reply()
        if anthropic {
            guard let content = object["content"] as? [[String: Any]],
                  let stop = object["stop_reason"] as? String, ["end_turn", "tool_use"].contains(stop) else { throw AIResponseError.incomplete }
            reply.assistant = ["role": "assistant", "content": content]
            for block in content {
                if block["type"] as? String == "thinking" { reply.thinking += block["thinking"] as? String ?? "" }
                if block["type"] as? String == "text" { reply.text += block["text"] as? String ?? "" }
                if block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { throw AIResponseError.invalidResponse }
                    reply.calls.append(try AIToolCall(id: id, name: name, arguments: AIToolWire.arguments(block["input"] ?? [:])))
                }
            }
            guard (stop == "tool_use") == !reply.calls.isEmpty else { throw AIResponseError.incomplete }
            reply.tokens = AnthropicAIProtocol.tokenTotal(object["usage"])
        } else {
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  let message = choice["message"] as? [String: Any], let stop = choice["finish_reason"] as? String,
                  ["stop", "tool_calls"].contains(stop) else { throw AIResponseError.incomplete }
            reply.assistant = message
            reply.assistant["role"] = "assistant"
            reply.text = message["content"] as? String ?? ""
            reply.thinking = message["reasoning_content"] as? String ?? message["reasoning"] as? String ?? ""
            if reply.thinking.isEmpty {
                reply.thinking = (message["reasoning_details"] as? [[String: Any]] ?? []).compactMap { detail in
                    switch detail["type"] as? String {
                    case "reasoning.summary": return detail["summary"] as? String
                    case "reasoning.text": return detail["text"] as? String
                    default: return nil
                    }
                }.joined(separator: "\n")
            }
            for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                guard call["type"] as? String == "function", let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any], let name = function["name"] as? String,
                      let arguments = function["arguments"] as? String else { throw AIResponseError.invalidResponse }
                reply.calls.append(try AIToolCall(id: id, name: name, arguments: AIToolValue.arguments(arguments)))
            }
            guard (stop == "tool_calls") == !reply.calls.isEmpty else { throw AIResponseError.incomplete }
            reply.tokens = (object["usage"] as? [String: Any])?["total_tokens"] as? Int
        }
        guard Set(reply.calls.map(\.id)).count == reply.calls.count, reply.calls.count <= 12 else { throw AIToolContractError.invalidArguments }
        return reply
    }

    /// Assemble only bounded wire data; signatures and provider continuation fields stay private.
    static func stream(_ bytes: URLSession.AsyncBytes, anthropic: Bool,
                       progress: @Sendable (AIResponseEvent) async -> Void,
                       emit: @Sendable (String) async throws -> Void) async throws -> Reply {
        var collector = StreamCollector(anthropic: anthropic)
        let thoughtID = "http-thought-" + UUID().uuidString
        var events = AISSEEventDecoder()
        var count = 0
        var pending = ""
        let clock = ContinuousClock()
        var nextUpdate = clock.now
        for try await byte in bytes {
            try Task.checkCancellation()
            count += 1
            guard count <= 1_048_576 else { throw AIResponseError.tooLarge }
            guard let payload = try events.consume(byte) else { continue }
            if payload == Data("[DONE]".utf8), !anthropic { break }
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw AIResponseError.invalidResponse }
            pending += try collector.consume(object)
            if let thought = collector.lastThinking { await progress(.thinking(id: thoughtID, delta: thought)) }
            if clock.now >= nextUpdate, !pending.isEmpty {
                try await emit(pending); pending = ""; nextUpdate = clock.now + .milliseconds(40)
            }
            if anthropic, collector.ended { break }
        }
        guard !events.hasPendingData else { throw AIResponseError.incomplete }
        let result = try collector.finish()
        if !pending.isEmpty { try await emit(pending) }
        return result
    }

    struct StreamCollector {
        let anthropic: Bool
        var message: [String: Any] = ["role": "assistant", "content": ""]
        var calls = [Int: [String: Any]]()
        var blocks = [Int: [String: Any]]()
        var closedBlocks = Set<Int>()
        var arguments = [Int: String]()
        var reasoningDetails = [[String: Any]]()
        var stop: String?
        var usage: [String: Any]?
        var ended = false
        var lastThinking: String?

        mutating func consume(_ object: [String: Any]) throws -> String {
            lastThinking = nil
            guard object["error"] == nil else { throw AIResponseError.invalidResponse }
            if !anthropic {
                if let next = object["usage"] as? [String: Any] { usage = next }
                guard let choice = (object["choices"] as? [[String: Any]])?.first else { return "" }
                if let reason = choice["finish_reason"] as? String { stop = reason }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                let text = delta["content"] as? String ?? ""
                lastThinking = delta["reasoning_content"] as? String ?? delta["reasoning"] as? String
                for detail in delta["reasoning_details"] as? [[String: Any]] ?? [] {
                    // Encrypted items are complete opaque blocks, never text fragments.
                    let type = detail["type"] as? String
                    let field = type == "reasoning.text" ? "text" : type == "reasoning.summary" ? "summary" : nil
                    let index = detail["index"] as? Int
                    let id = detail["id"] as? String
                    let format = detail["format"] as? String
                    let match = reasoningDetails.lastIndex { previous in
                        guard field != nil, previous["type"] as? String == type,
                              previous["format"] as? String == format else { return false }
                        if id != nil || index != nil {
                            return previous["id"] as? String == id && previous["index"] as? Int == index
                        }
                        return reasoningDetails.last.map { NSDictionary(dictionary: $0).isEqual(to: previous) } == true
                    }
                    if let match, let field {
                        var combined = reasoningDetails[match]
                        for (key, value) in detail {
                            if key == field || key == "signature", let fragment = value as? String {
                                combined[key] = (combined[key] as? String ?? "") + fragment
                            } else if !(value is NSNull) || combined[key] == nil { combined[key] = value }
                        }
                        reasoningDetails[match] = combined
                    } else {
                        guard reasoningDetails.count < 64 else { throw AIResponseError.tooLarge }
                        reasoningDetails.append(detail)
                    }
                }
                if !reasoningDetails.isEmpty { message["reasoning_details"] = reasoningDetails }
                for (key, value) in delta where key != "tool_calls" && key != "reasoning_details" {
                    if let string = value as? String { message[key] = (message[key] as? String ?? "") + string }
                    else if !(value is NSNull) || message[key] == nil { message[key] = value }
                }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    guard let index = call["index"] as? Int, (0..<12).contains(index) else { throw AIResponseError.invalidResponse }
                    var current = calls[index] ?? ["type": "function"]
                    for (key, value) in call where key != "index" && key != "function" && !(value is NSNull) {
                        if key == "id", let part = value as? String {
                            let previous = current[key] as? String ?? ""
                            current[key] = part.hasPrefix(previous) ? part : previous + part
                        } else { current[key] = value }
                    }
                    if let function = call["function"] as? [String: Any] {
                        var accumulated = current["function"] as? [String: Any] ?? [:]
                        for (key, value) in function where !(value is NSNull) {
                            if let text = value as? String {
                                let previous = accumulated[key] as? String ?? ""
                                accumulated[key] = key == "name" && text.hasPrefix(previous) ? text : previous + text
                            }
                            else { accumulated[key] = value }
                        }
                        current["function"] = accumulated
                    }
                    if let id = current["id"] as? String, id.utf8.count > 256 { throw AIResponseError.tooLarge }
                    if let function = current["function"] as? [String: Any] {
                        if (function["name"] as? String ?? "").utf8.count > 64 ||
                           (function["arguments"] as? String ?? "").utf8.count > 16_384 { throw AIResponseError.tooLarge }
                    }
                    calls[index] = current
                }
                return text
            }
            let type = object["type"] as? String ?? ""
            switch type {
            case "message_start": usage = (object["message"] as? [String: Any])?["usage"] as? [String: Any]
            case "content_block_start":
                guard let index = object["index"] as? Int, (0..<64).contains(index), blocks[index] == nil,
                      let block = object["content_block"] as? [String: Any] else { throw AIResponseError.invalidResponse }
                blocks[index] = block
                if block["type"] as? String == "text" { return block["text"] as? String ?? "" }
                if block["type"] as? String == "thinking" { lastThinking = block["thinking"] as? String }
            case "content_block_stop":
                guard let index = object["index"] as? Int, blocks[index] != nil,
                      closedBlocks.insert(index).inserted else { throw AIResponseError.invalidResponse }
            case "content_block_delta":
                guard let index = object["index"] as? Int, !closedBlocks.contains(index), var block = blocks[index], let delta = object["delta"] as? [String: Any] else { throw AIResponseError.invalidResponse }
                switch delta["type"] as? String {
                case "input_json_delta":
                    arguments[index, default: ""] += delta["partial_json"] as? String ?? ""
                    guard arguments[index]!.utf8.count <= 16_384 else { throw AIResponseError.tooLarge }
                case "text_delta": block["text"] = (block["text"] as? String ?? "") + (delta["text"] as? String ?? "")
                case "thinking_delta":
                    lastThinking = delta["thinking"] as? String
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta": block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                default: break
                }
                blocks[index] = block
                if delta["type"] as? String == "text_delta" { return delta["text"] as? String ?? "" }
            case "message_delta":
                stop = (object["delta"] as? [String: Any])?["stop_reason"] as? String
                if let next = object["usage"] as? [String: Any] { usage = (usage ?? [:]).merging(next) { _, new in new } }
            case "message_stop": ended = true
            default: break
            }
            return ""
        }

        func finish() throws -> Reply {
            guard let stop else { throw AIResponseError.incomplete }
            if !anthropic {
                var assistant = message
                assistant["role"] = "assistant"
                if !calls.isEmpty { assistant["tool_calls"] = calls.keys.sorted().compactMap { calls[$0] } }
                return try decode(["choices": [["message": assistant, "finish_reason": stop]], "usage": usage ?? [:]], anthropic: false)
            }
            guard ended, closedBlocks.count == blocks.count else { throw AIResponseError.incomplete }
            let content = try blocks.keys.sorted().map { index -> [String: Any] in
                var block = blocks[index]!
                if let json = arguments[index], !json.isEmpty { block["input"] = try AIToolWire.object(AIToolValue.object(AIToolValue.arguments(json))) }
                return block
            }
            return try decode(["content": content, "stop_reason": stop, "usage": usage ?? [:]], anthropic: true)
        }
    }
}
