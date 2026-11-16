import Foundation

/// An in-memory cursor over the copy order captured at the start of a run.
struct ClipboardPasteSequence {
    struct Request: Equatable {
        fileprivate let id = UUID()
        let target: Int32
        let generation: Int
        let items: [String]?
        let index: Int
    }

    private struct Snapshot {
        var target: Int32
        var generation: Int
        var lastPaste: TimeInterval?
        var items: [String]
        var index = 0
    }

    private var snapshot: Snapshot?
    private var pending: Request?
    var isPending: Bool { pending != nil }

    mutating func begin(target: Int32, generation: Int, now: TimeInterval, timeout: TimeInterval) -> Request? {
        guard pending == nil else { return nil }
        if let snapshot, snapshot.target != target || snapshot.generation != generation
            || snapshot.lastPaste.map({ now - $0 >= timeout }) == true {
            self.snapshot = nil
        }
        let request = Request(target: target, generation: generation, items: snapshot?.items, index: snapshot?.index ?? 0)
        pending = request
        return request
    }

    func contains(_ request: Request) -> Bool { pending == request }

    mutating func remember(_ items: [String], for request: Request) {
        guard contains(request), snapshot == nil, !items.isEmpty else { return }
        snapshot = Snapshot(target: request.target, generation: request.generation, items: items)
    }

    mutating func wroteClipboard(for request: Request, generation: Int) {
        guard contains(request) else { return }
        snapshot?.generation = generation
    }

    mutating func dispatched(_ request: Request, at now: TimeInterval) {
        guard contains(request) else { return }
        snapshot?.index = request.index + 1
        snapshot?.lastPaste = now
        pending = nil
    }

    mutating func finish(_ request: Request) {
        if contains(request) { pending = nil }
    }

    mutating func cancelPending() { pending = nil }

    mutating func reset() { self = .init() }
}

enum ClipboardSequenceCommand: String {
    case paste = "paste-sequentially"
    case reset = "reset-paste-sequence"

    var title: String { self == .paste ? "顺序粘贴" : "重置粘贴顺序" }
    var symbol: String { self == .paste ? "list.clipboard" : "arrow.counterclockwise" }
}
