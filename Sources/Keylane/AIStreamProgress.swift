import Foundation
import KeylaneCore

/// Adapts response metadata without enabling or executing any tool.
struct OpenAIProgressBuffer {
    private struct Call { var name = ""; var arguments = "" }
    private var calls: [Int: Call] = [:]
    private(set) var requestedTools = false
    private var thoughtIndex = 0
    private var thinkingActive = false

    mutating func events(_ text: AICompletionEnvelope.Choice.Text, delta: Bool) throws -> [AIResponseEvent] {
        var events: [AIResponseEvent] = []
        if let thought = text.reasoning, !thought.isEmpty {
            if !thinkingActive { thoughtIndex += 1; thinkingActive = true }
            events.append(.thinking(id: "model-thought-\(thoughtIndex)", delta: thought))
        }
        if text.content?.isEmpty == false || text.toolCalls?.isEmpty == false { thinkingActive = false }
        for (position, tool) in (text.toolCalls ?? []).enumerated() {
            let index = tool.index ?? position
            guard (0..<32).contains(index) else { throw AIResponseError.tooLarge }
            requestedTools = true
            var call = calls[index] ?? Call()
            if let name = tool.function?.name {
                if !delta || call.name.isEmpty || name.hasPrefix(call.name) { call.name = name }
                else if name != call.name { call.name += name }
            }
            if let arguments = tool.function?.arguments {
                if delta { call.arguments += arguments } else { call.arguments = arguments }
            }
            guard call.name.utf8.count <= 256, call.arguments.utf8.count <= 16_000 else { throw AIResponseError.tooLarge }
            calls[index] = call
            events.append(.tool(id: "model-tool-\(index)", name: call.name.isEmpty ? "工具请求" : call.name,
                                arguments: call.arguments, state: .requested))
        }
        return events
    }
}

/// Public Codex progress notifications; encrypted/raw reasoning is intentionally ignored.
enum CodexProgressAdapter {
    static func events(method: String, params: [String: Any]) -> [AIResponseEvent] {
        if method == "item/reasoning/summaryTextDelta", let id = params["itemId"] as? String, let delta = params["delta"] as? String {
            return [.thinking(id: "codex-" + id, delta: delta)]
        }
        guard ["item/started", "item/completed"].contains(method), let item = params["item"] as? [String: Any],
              let id = item["id"] as? String, let type = item["type"] as? String else { return [] }
        if type == "reasoning" { return method == "item/started" ? [.thinking(id: "codex-" + id, delta: "")] : [] }
        guard ["mcpToolCall", "dynamicToolCall", "webSearch"].contains(type) else { return [] }
        let name = item["tool"] as? String ?? item["name"] as? String ?? (type == "webSearch" ? "搜索网页" : "工具调用")
        var arguments: Any? = item["arguments"]
        if arguments == nil {
            if let action = item["action"], !(action is NSNull) { arguments = action }
            else if let query = item["query"] as? String { arguments = ["query": query] }
        }
        let data = arguments.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let failed = ["failed", "errored"].contains(item["status"] as? String ?? "") || item["error"] is [String: Any] || item["success"] as? Bool == false
        let state: AIResponseProgress.Activity.State = method == "item/started" ? .running : (failed ? .failed : .completed)
        return [.tool(id: "codex-" + id, name: name, arguments: text, state: state)]
    }
}
