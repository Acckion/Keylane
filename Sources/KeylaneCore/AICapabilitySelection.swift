import Foundation

/// nil follows the available catalog; an explicit empty set grants no tools.
/// Selection narrows a catalog, never substitutes for execution-time authorization.
public struct AICapabilitySelection: Equatable, Sendable {
    public let modules: Set<ModuleID>?
    public init(modules: Set<ModuleID>? = nil) { self.modules = modules }

    public func permits(_ owner: ModuleID?) -> Bool {
        guard let modules else { return true }
        guard let owner else { return false }
        return modules.contains(owner)
    }

    public func setting(_ owner: ModuleID, enabled: Bool, available: Set<ModuleID>) -> Self {
        var selected = modules ?? available
        if enabled { selected.insert(owner) } else { selected.remove(owner) }
        return .init(modules: selected)
    }
}
