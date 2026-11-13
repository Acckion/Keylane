import Foundation

/// Selection survives a reordered result snapshot. A removed selection remains
/// unresolved until the user selects another result or starts a new query.
public struct LauncherResultSelection {
    public var id: CommandID?

    public init(id: CommandID? = nil) { self.id = id }

    public mutating func selectDefault(_ first: CommandID?) {
        if id == nil { id = first }
    }

    public func index<Item>(in results: [Item], identifiedBy key: KeyPath<Item, CommandID>) -> Int? {
        guard let id else { return nil }
        return results.firstIndex { $0[keyPath: key] == id }
    }

    public mutating func move<Item>(by delta: Int, in results: [Item], identifiedBy key: KeyPath<Item, CommandID>) {
        guard !results.isEmpty else { return }
        let destination = index(in: results, identifiedBy: key).map {
            NavigationBounds.move($0, by: delta, count: results.count)
        } ?? 0
        id = results[destination][keyPath: key]
    }
}

/// One logical page can enter, suspend while hidden, and resume on the same
/// route. Showing an already active page and hiding twice have no side effects.
public struct LauncherPagePresentation {
    public enum Activation: Equatable { case enter, resume }

    public struct Change {
        public let previousPage: PageID?
        public let deactivation: PageID?
        public let activation: Activation?
    }

    public private(set) var page: PageID
    public private(set) var visible = false
    private var activationID: UUID?
    private var entered = false

    public init(page: PageID = .root) { self.page = page }

    public mutating func update(page next: PageID, visible showing: Bool, activationID nextActivationID: UUID? = nil) -> Change {
        let previous = page
        let changed = previous != next || activationID != nextActivationID
        let deactivation = visible && (!showing || changed) ? previous : nil
        let activates = showing && (!visible || changed)
        if changed { entered = false }
        let activation: Activation? = activates ? (entered ? .resume : .enter) : nil
        if activates { entered = true }
        page = next
        activationID = nextActivationID
        visible = showing
        return Change(previousPage: changed ? previous : nil, deactivation: deactivation, activation: activation)
    }
}
