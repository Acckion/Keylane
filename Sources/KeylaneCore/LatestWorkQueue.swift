import Foundation

/// A serial executor with one active item and one replaceable pending item.
/// Each completion yields to the underlying queue before taking the next item.
public final class LatestWorkQueue: @unchecked Sendable {
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        fileprivate func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
    public struct Diagnostics: Sendable {
        public let submitted: Int, executed: Int, replaced: Int
        public let active: Int, pending: Int
    }
    private struct Item {
        let cancellation: Cancellation
        let work: (Cancellation) -> Void
    }
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: Item?
    private var active: Cancellation?
    private var scheduled = false
    private var submitted = 0, executed = 0, replaced = 0

    public init(queue: DispatchQueue) { self.queue = queue }
    deinit { cancel() }
    public var diagnostics: Diagnostics {
        lock.lock(); defer { lock.unlock() }
        return .init(submitted: submitted, executed: executed, replaced: replaced,
                     active: active == nil ? 0 : 1, pending: pending == nil ? 0 : 1)
    }
    public func submit(cancelActive: Bool = true, _ work: @escaping (Cancellation) -> Void) {
        lock.lock()
        submitted += 1
        let previous = pending
        if let previous { previous.cancellation.cancel(); replaced += 1 }
        if cancelActive { active?.cancel() }
        pending = Item(cancellation: Cancellation(), work: work)
        let enqueue = !scheduled
        scheduled = true
        lock.unlock()
        withExtendedLifetime(previous) {}
        if enqueue { schedule() }
    }
    public func cancel() {
        lock.lock()
        let previous = pending
        active?.cancel(); pending?.cancellation.cancel()
        pending = nil
        lock.unlock()
        withExtendedLifetime(previous) {}
    }
    private func schedule() { queue.async { [weak self] in self?.runOne() } }
    private func runOne() {
        lock.lock()
        guard let item = pending else { scheduled = false; lock.unlock(); return }
        pending = nil; active = item.cancellation; executed += 1
        lock.unlock()
        if !item.cancellation.isCancelled { item.work(item.cancellation) }
        lock.lock()
        active = nil
        let again = pending != nil
        scheduled = again
        lock.unlock()
        withExtendedLifetime(item) {}
        if again { schedule() }
    }
}
