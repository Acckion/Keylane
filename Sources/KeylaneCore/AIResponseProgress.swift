import Foundation

/// Only transport-reported activity is counted. Waiting/writing are phases, not invented steps.
public struct AIResponseProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case waiting, thinking, tool, writing, completed, failed, cancelled }
    public struct Activity: Codable, Identifiable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case thinking, tool }
        public enum State: String, Codable, Sendable { case requested, running, completed, failed, cancelled, notExecuted, unconfirmed }
        public let id: String
        public let kind: Kind
        public var title: String
        public var text = ""
        public var arguments = ""
        public var state: State
    }
    public private(set) var phase: Phase = .waiting
    public private(set) var activities: [Activity] = []
    public init() {}
    public var active: Bool { [.waiting, .thinking, .tool, .writing].contains(phase) }
    public var completedToolCount: Int { activities.filter { $0.kind == .tool && $0.state == .completed }.count }
    public var hasThinking: Bool { activities.contains { $0.kind == .thinking } }
    public var title: String {
        switch phase {
        case .waiting: return "正在准备回复…"
        case .thinking: return "正在思考"
        case .tool:
            if activities.contains(where: { $0.kind == .tool && $0.state == .running }) { return "正在调用工具" }
            if activities.contains(where: { $0.kind == .tool && $0.state == .requested }) { return "模型请求调用工具" }
            return "正在整理回复…"
        case .writing: return "正在回复…"
        case .cancelled: return "已停止"
        case .failed: return activities.contains { $0.state == .notExecuted } ? "工具请求未执行" : "回复中断"
        case .completed:
            if activities.contains(where: { $0.state == .notExecuted }) { return "回复已完成，部分工具未执行" }
            if activities.contains(where: { $0.state == .unconfirmed }) { return "回复已完成，部分工具状态未确认" }
            if completedToolCount > 0 { return "已完成 \(completedToolCount) 项工具调用" }
            return hasThinking ? "已完成思考" : "已生成回复"
        }
    }

    public mutating func apply(_ event: AIResponseEvent) {
        guard active else { return }
        switch event {
        case let .thinking(id, delta):
            phase = .thinking
            if let index = activities.firstIndex(where: { $0.id == id }) {
                let remaining = max(0, 16_000 - activities[index].text.utf8.count)
                activities[index].text += Self.bounded(delta, bytes: remaining)
            } else if activities.count < 64 {
                activities.append(.init(id: id, kind: .thinking, title: "思考", text: Self.bounded(delta), state: .running))
            }
        case let .tool(id, name, arguments, state):
            finishThinking()
            phase = .tool
            if let index = activities.firstIndex(where: { $0.id == id }) {
                activities[index].title = String(name.prefix(100))
                activities[index].arguments = Self.sanitizedArguments(arguments)
                activities[index].state = state
            } else if activities.count < 64 {
                activities.append(.init(id: id, kind: .tool, title: String(name.prefix(100)), arguments: Self.sanitizedArguments(arguments), state: state))
            }
        case .writing:
            finishThinking(); phase = .writing
        case .completed:
            finishThinking(); phase = .completed
            // A tool request without an execution result is never reported as successful.
            for index in activities.indices where activities[index].state == .requested { activities[index].state = .notExecuted }
            for index in activities.indices where activities[index].state == .running { activities[index].state = .unconfirmed }
        case .failed, .cancelled:
            phase = event == .cancelled ? .cancelled : .failed
            for index in activities.indices {
                if activities[index].state == .requested { activities[index].state = .notExecuted }
                else if activities[index].state == .running { activities[index].state = event == .cancelled ? .cancelled : .failed }
            }
        }
    }
    private mutating func finishThinking() {
        for index in activities.indices where activities[index].kind == .thinking && activities[index].state == .running {
            activities[index].state = .completed
        }
    }
    private static func bounded(_ text: String, bytes: Int = 16_000) -> String {
        guard text.utf8.count > bytes else { return text }
        var data = Data(text.utf8.prefix(bytes))
        while !data.isEmpty {
            if let value = String(data: data, encoding: .utf8) { return value }
            data.removeLast()
        }
        return ""
    }
    public static func sanitizedArguments(_ text: String) -> String {
        guard !text.isEmpty, text.utf8.count <= 16_000,
              let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return "" }
        func clean(_ value: Any, depth: Int) -> Any {
            guard depth < 8 else { return "…" }
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for key in dictionary.keys.sorted().prefix(32) {
                    let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                    let secret = ["password", "token", "apikey", "authorization", "cookie", "secret", "credential"].contains { normalized.contains($0) }
                    result[String(key.prefix(100))] = secret ? "[已隐藏]" : clean(dictionary[key]!, depth: depth + 1)
                }
                return result
            }
            if let array = value as? [Any] { return array.prefix(16).map { clean($0, depth: depth + 1) } }
            if let string = value as? String { return String(string.prefix(2_048)) }
            return value
        }
        guard let output = try? JSONSerialization.data(withJSONObject: clean(object, depth: 0), options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(data: output, encoding: .utf8) ?? ""
    }
}

public enum AIResponseEvent: Equatable, Sendable {
    case thinking(id: String, delta: String)
    case tool(id: String, name: String, arguments: String, state: AIResponseProgress.Activity.State)
    case writing, completed, failed, cancelled
}
