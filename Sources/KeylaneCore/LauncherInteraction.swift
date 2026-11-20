import Foundation

/// A paste owns its window retention until it completes or the user cancels it.
public struct LauncherPaste {
    public struct Request {
        fileprivate let id: UUID
        public let keepsLauncherOpen: Bool
    }

    private var current: Request?

    public init() {}

    public var isPending: Bool { current != nil }
    public var keepsLauncherOpen: Bool { current?.keepsLauncherOpen == true }

    public mutating func begin(keepingLauncherOpen: Bool) -> Request? {
        guard current == nil else { return nil }
        let request = Request(id: UUID(), keepsLauncherOpen: keepingLauncherOpen)
        current = request
        return request
    }

    public func isCurrent(_ request: Request) -> Bool { current?.id == request.id }

    public mutating func finish(_ request: Request) {
        if isCurrent(request) { cancel() }
    }

    public mutating func cancel() { current = nil }
}

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

public enum LauncherActionSelection {
    public static func reconcile(_ selectedID: String?, enabledIDs: [String]) -> String? {
        if let selectedID, enabledIDs.contains(selectedID) { return selectedID }
        return enabledIDs.first
    }
}

/// One logical page can enter, suspend while hidden, and resume on the same
/// route. Showing an already active page and hiding twice have no side effects.
public struct LauncherPagePresentation {
    /// Only an opted-in page may replace an explicitly supplied query with its entry result.
    /// Returning to a page preserves its saved draft unless the caller supplied a new query.
    public static func entryQuery(explicit: String?, pageResult: String?, restored: String?,
                                  pageConsumesEntryQuery: Bool = false) -> String? {
        guard restored == nil || explicit != nil else { return nil }
        return pageConsumesEntryQuery ? pageResult ?? explicit : explicit ?? pageResult
    }

    /// Existing drafts are restored locally without invoking entry actions.
    public enum EntryIntent: Equatable {
        case standard, query(String), existingDraft

        public func resolve(current: String, restored: String?, pageConsumesEntryQuery: Bool,
                            existingDraft: () -> String?, enter: (String) -> String?) -> String? {
            if self == .existingDraft { return existingDraft() }
            let explicit: String?
            if case .query(let query) = self { explicit = query } else { explicit = nil }
            return LauncherPagePresentation.entryQuery(explicit: explicit, pageResult: enter(explicit ?? current),
                restored: restored, pageConsumesEntryQuery: pageConsumesEntryQuery)
        }
    }

    public enum Activation: Equatable { case enter, resume }

    public struct Change {
        public let previousPage: PageID?
        public let deactivation: PageID?
        public let activation: Activation?
    }

    public private(set) var page: PageID
    public private(set) var visible = false
    public struct ActionContext: Equatable {
        fileprivate let page: PageID
        fileprivate let visit: UInt64
        fileprivate let selectionID: String?
    }

    private var visit: UInt64 = 0
    private var activationID: UUID?
    private var entered = false

    public init(page: PageID = .root) { self.page = page }

    public func actionContext(page: PageID, activationID: UUID?, selectionID: String?) -> ActionContext? {
        guard visible, self.page == page, self.activationID == activationID else { return nil }
        return .init(page: page, visit: visit, selectionID: selectionID)
    }

    public mutating func update(page next: PageID, visible showing: Bool, activationID nextActivationID: UUID? = nil) -> Change {
        let previous = page
        let changed = previous != next || activationID != nextActivationID
        let deactivation = visible && (!showing || changed) ? previous : nil
        let activates = showing && (!visible || changed)
        if changed || visible != showing { visit &+= 1 }
        if changed { entered = false }
        let activation: Activation? = activates ? (entered ? .resume : .enter) : nil
        if activates { entered = true }
        page = next
        activationID = nextActivationID
        visible = showing
        return Change(previousPage: changed ? previous : nil, deactivation: deactivation, activation: activation)
    }
}

public enum LauncherEscapeBehavior: String {
    case backOrClose, closeWindow

    public func returnsToParent(from page: PageID) -> Bool {
        self == .backOrClose && page != .root
    }
}

/// Keeps a parent's query only while the launcher is following its declared child routes.
public struct LauncherPageHistory {
    private struct Visit {
        let parent: PageID
        let child: PageID
        let query: String
    }

    private var visits: [Visit] = []

    public init() {}

    public mutating func transition(from previous: PageID, to current: PageID,
                                    parentOfCurrent: PageID?, query: String) -> String? {
        if let visit = visits.last, visit.child == previous, visit.parent == current {
            visits.removeLast()
            return visit.query
        }
        if previous != current, parentOfCurrent == previous, previous != .root {
            visits.append(Visit(parent: previous, child: current, query: query))
        } else {
            visits.removeAll()
        }
        return nil
    }
}
