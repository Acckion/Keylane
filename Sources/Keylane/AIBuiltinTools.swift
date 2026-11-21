import Foundation
import KeylaneCore

/// Native modules own the handlers. The host only advertises and dispatches their declarations.
enum AIBuiltinTools {
    private static func definition(_ name: String, _ title: String, _ description: String,
                                   _ parameters: [AIToolParameter] = []) -> AIToolDefinition {
        // Fixed developer-authored declarations are validated again as one catalog at registration.
        try! AIToolDefinition(name: name, title: title, description: description, parameters: parameters)
    }
    private static func text(_ arguments: [String: AIToolValue], _ name: String) throws -> String {
        guard case .string(let value) = arguments[name] else { throw AIToolContractError.invalidArguments }
        return value
    }
    private static func limit(_ arguments: [String: AIToolValue]) -> Int {
        if case .number(let count) = arguments["limit"] { return Int(count) }; return 10
    }
    private static let query = AIToolParameter("query", description: "要查找的名称", kind: .string(maximumLength: 256))
    private static let count = AIToolParameter("limit", description: "最多返回条数，默认10", kind: .integer(minimum: 1, maximum: 20), required: false)

    static var time: [AIToolRegistration] {
        [.init(definition: definition("keylane_time", "读取时间", "获取当前时间与时区。"), impact: .publicRead) { _ in
            try .init(text: Date().ISO8601Format() + " | " + TimeZone.current.identifier)
        }]
    }
    static var calculator: [AIToolRegistration] {
        [.init(definition: definition("keylane_calculate", "计算", "用 Keylane 计算器计算数学表达式，不执行代码。", [
            .init("expression", description: "数学表达式", kind: .string(maximumLength: 512))]), impact: .computation) { arguments in
            guard let result = CalculatorLanguage.evaluate(try text(arguments, "expression")) else { throw AIToolContractError.invalidArguments }
            return try .init(text: result)
        }]
    }
    static func applications(_ model: Model) -> [AIToolRegistration] {
        [.init(definition: definition("keylane_search_apps", "查找应用", "查找当前启用且可用的应用，返回准确路径供打开使用。", [query, count]), impact: .privateRead) { [weak model] arguments in
            guard let model else { throw AIToolContractError.unavailable }
            let query = try text(arguments, "query")
            let apps = model.apps.lazy.filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query) && model.isApplicationCommandAvailable(at: $0.path) }.prefix(limit(arguments))
            return try AIToolWire.result(["applications": .array(apps.map { .object(["name": .string($0.deletingPathExtension().lastPathComponent), "path": .string($0.path)]) })])
        }, .init(definition: definition("keylane_open_app", "打开应用", "请求打开查找到的应用，每次都必须等待用户确认。", [
            .init("path", description: "查找应用返回的准确路径", kind: .string(maximumLength: 4096))]), requiresConfirmation: true, impact: .openApplication) { [weak model] arguments in
            let path = try text(arguments, "path")
            guard let model, model.isApplicationCommandAvailable(at: path),
                  model.runCommand(CommandID(rawValue: "app:" + path), origin: .menu) else { throw AIToolContractError.unavailable }
            return try .init(text: "已向系统请求打开该应用。")
        }]
    }
    static func files(_ model: Model) -> [AIToolRegistration] { AIReadTools.files(model.fileSearch) }
    static func clipboard(_ model: Model) -> [AIToolRegistration] { AIReadTools.clipboard(model.clipboard) }
    static func calendar(_ model: Model) -> [AIToolRegistration] {
        [.init(definition: definition("keylane_calendar", "查询日程", "查询已授权且已选中日历的日程标题及时间。不申请新权限，不读取备注。最多七天。", [
            .init("start", description: "ISO8601开始时间，包含时区", kind: .string(maximumLength: 64)),
            .init("end", description: "ISO8601结束时间，包含时区", kind: .string(maximumLength: 64)), count]),
               impact: .privateRead, available: { [weak model] in model?.calendar.enabled == true }) { [weak model] arguments in
            let formatter = ISO8601DateFormatter()
            guard let model, let start = formatter.date(from: try text(arguments, "start")),
                  let end = formatter.date(from: try text(arguments, "end")) else { throw AIToolContractError.invalidArguments }
            let events = try await model.calendar.aiEvents(start: start, end: end, limit: limit(arguments))
            return try AIToolWire.result(["events": .array(events.map(AIToolValue.string))])
        }]
    }
}
