import Foundation

/// Strict count/byte bounds with O(1) LRU access. Values already borrowed by a
/// caller remain valid after eviction; destruction never runs under the lock.
public final class CostBoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private final class Node {
        let key: Key, value: Value, cost: Int
        var next: Node?
        weak var previous: Node?
        init(_ key: Key, _ value: Value, _ cost: Int) { self.key = key; self.value = value; self.cost = cost }
    }
    private let lock = NSLock()
    private var entries: [Key: Node] = [:]
    private var first: Node?, last: Node?
    private var bytes = 0, byteLimit: Int, countLimit: Int
    public init(bytes: Int, count: Int) { byteLimit = max(0, bytes); countLimit = max(0, count) }
    public var cost: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }
    public func object(forKey key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let node = entries[key] else { return nil }
        unlink(node); prepend(node); return node.value
    }
    public func setObject(_ value: Value, forKey key: Key, cost: Int) {
        lock.lock()
        var retired: [Node] = []
        if let old = entries.removeValue(forKey: key) { unlink(old); bytes -= old.cost; retired.append(old) }
        if cost >= 0, cost <= byteLimit, byteLimit > 0, countLimit > 0 {
            while bytes > byteLimit - cost || entries.count >= countLimit {
                guard let node = last else { break }
                remove(node); retired.append(node)
            }
            let node = Node(key, value, cost); entries[key] = node; prepend(node); bytes += cost
        }
        evict(into: &retired)
        lock.unlock()
        withExtendedLifetime(retired) {}
    }
    /// Return evicted values so a coordinator can also release its outer lock
    /// before their destructors run.
    @discardableResult public func setLimits(bytes: Int, count: Int) -> [Value] {
        lock.lock()
        byteLimit = max(0, bytes); countLimit = max(0, count)
        var retired: [Node] = []; evict(into: &retired)
        lock.unlock()
        return retired.map(\.value)
    }
    public func removeAllObjects() {
        lock.lock()
        var retired: [Node] = []
        while let node = last { remove(node); retired.append(node) }
        lock.unlock()
        withExtendedLifetime(retired) {}
    }
    private func evict(into retired: inout [Node]) {
        while bytes > byteLimit || entries.count > countLimit || byteLimit == 0 && !entries.isEmpty {
            guard let node = last else { break }
            remove(node); retired.append(node)
        }
    }
    private func remove(_ node: Node) { unlink(node); entries.removeValue(forKey: node.key); bytes -= node.cost }
    private func unlink(_ node: Node) {
        if let previous = node.previous { previous.next = node.next } else { first = node.next }
        if let next = node.next { next.previous = node.previous } else { last = node.previous }
        node.next = nil; node.previous = nil
    }
    private func prepend(_ node: Node) {
        node.next = first; first?.previous = node; first = node
        if last == nil { last = node }
    }
}
