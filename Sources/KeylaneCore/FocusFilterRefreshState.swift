/// Coalesce overlapping OS lookups without losing a pending startup/wake recovery.
public struct FocusFilterRefreshState: Sendable {
    private var generation = 0
    public private(set) var recovering = false
    public init() {}
    public mutating func begin(recovering: Bool) -> Int {
        generation += 1; self.recovering = self.recovering || recovering
        return generation
    }
    public func isCurrent(_ ticket: Int) -> Bool { ticket == generation }
    public mutating func complete(_ ticket: Int) { if isCurrent(ticket) { recovering = false } }
    public mutating func reset() { generation += 1; recovering = false }
}
