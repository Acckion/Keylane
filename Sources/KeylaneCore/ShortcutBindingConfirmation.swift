import Foundation

/// Owns one reviewable binding change. Cancellation invalidates the identity,
/// even if the picker is reopened for the same command and shortcut.
public struct ShortcutBindingConfirmation {
    public struct Proposal {
        public let id = UUID()
        public let target: Shortcut
        public let commandID: String
        public let previous: Shortcut?
        public let displaced: String?
        public let evidence: [ShortcutMapEntry]
    }

    public enum Completion: Equatable {
        case ignored
        case needsConfirmation
        case invalid
        case save([String: Shortcut])
    }

    public private(set) var proposal: Proposal?
    public init() {}

    public mutating func begin(target: Shortcut, commandID: String, previous: Shortcut?,
                               displaced: String?, evidence: [ShortcutMapEntry]) {
        proposal = Proposal(target: target, commandID: commandID, previous: previous,
                            displaced: displaced, evidence: evidence)
    }

    public mutating func cancel() { proposal = nil }
    public func isCurrent(_ id: UUID) -> Bool { proposal?.id == id }

    public mutating func complete(_ id: UUID, evidence: [ShortcutMapEntry], bindings: [String: Shortcut]) -> Completion {
        guard let proposed = proposal, proposed.id == id else { return .ignored }
        guard bindings[proposed.commandID] == proposed.previous,
              bindings.first(where: { $0.value == proposed.target })?.key == proposed.displaced else {
            cancel()
            return .invalid
        }
        guard evidence == proposed.evidence else {
            begin(target: proposed.target, commandID: proposed.commandID, previous: proposed.previous,
                  displaced: proposed.displaced, evidence: evidence)
            return .needsConfirmation
        }
        cancel()
        var updated = bindings
        if let displaced = proposed.displaced { updated.removeValue(forKey: displaced) }
        updated[proposed.commandID] = proposed.target
        return .save(updated)
    }
}
