import Foundation

/// Parameters supplied by the OS; empty categories are the system's reset state.
public struct FocusSystemFilter: Codable, Equatable, Sendable {
    public var categories: [UUID]
    public var mode: FocusConfiguration.Mode
    public var goal: String?
    public init(categories: [UUID] = [], mode: FocusConfiguration.Mode = .block, goal: String? = nil) {
        self.categories = Array(Set(categories)).sorted { $0.uuidString < $1.uuidString }
        self.mode = mode
        let value = goal?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.goal = value?.isEmpty == false ? value : nil
    }
    public var active: Bool { !categories.isEmpty }
    public func configuration(available: [FocusCategory]) throws -> FocusConfiguration {
        guard active, categories.count <= 200 else { throw FocusSystemFilterError.missingCategory }
        var selected: [FocusCategory] = []
        for id in categories {
            guard let value = available.first(where: { $0.id == id }) else { throw FocusSystemFilterError.missingCategory }
            selected.append(value)
        }
        let name = goal ?? String(selected.map(\.name).joined(separator: "、").prefix(200))
        let group = try FocusCategory(name: name, applications: selected.flatMap(\.applications), websites: selected.flatMap(\.websites)).validated()
        var result = FocusConfiguration()
        result.goal = group.name; result.mode = mode
        result.applications = group.applications; result.websites = group.websites
        return result
    }
}

public struct FocusSystemLink: Codable, Equatable, Sendable {
    public var selection = FocusSystemFilter()
    public var sessionID: UUID?
    public var userPaused = false
    public init() {}
    public enum Decision: Equatable { case unchanged, preserveManual, start, replace, finish, resume }
    public func decision(for incoming: FocusSystemFilter, session: FocusSession?, recovering: Bool = false) -> Decision {
        if let session, session.id != sessionID { return .preserveManual }
        if incoming == selection {
            if recovering, incoming.active, let session, session.id == sessionID, session.paused, !userPaused { return .resume }
            return .unchanged
        }
        if !incoming.active { return session?.id == sessionID && session != nil ? .finish : .unchanged }
        return session == nil ? .start : .replace
    }
}

public enum FocusSystemFilterError: LocalizedError {
    case missingCategory, unavailable, disabled, automation
    public var errorDescription: String? {
        switch self {
        case .missingCategory: "过滤条件中的专注分类已删除或不可用，请重新选择。"
        case .unavailable: "请先启动 Keylane，并在设置中启用专注功能。"
        case .disabled: "请先在 Keylane 设置中启用专注功能并授予辅助功能权限。"
        case .automation: "请先在 Keylane 中开始一次网站专注会话，完成浏览器自动化授权。"
        }
    }
}
