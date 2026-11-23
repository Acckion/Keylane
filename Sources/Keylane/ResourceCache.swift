import Foundation
import KeylaneCore

private protocol ResourceCacheOwner: AnyObject {
    var role: ResourceCaches.Role { get }
    func apply(bytes: Int, count: Int) -> [Any]
}

/// Shared, explicit retention policy; visible views retain their own images.
/// A late worker cannot refill a background-only cache after it was trimmed.
enum ResourceCaches {
    enum Role: Hashable {
        case artwork, workspace, clipboard, screenshots, shelf, theme, screenshotText, linkPreview, linkIcons
        var foregroundBytes: Int {
            switch self {
            case .artwork, .workspace, .theme: return 2 * 1024 * 1024
            case .clipboard, .screenshotText, .linkPreview: return 4 * 1024 * 1024
            case .screenshots, .shelf: return 8 * 1024 * 1024
            case .linkIcons: return 1024 * 1024
            }
        }
        var backgroundBytes: Int { self == .artwork ? 256 * 1024 : 0 }
        var count: Int { self == .screenshotText ? 2000 : 256 }
    }
    private final class WeakCache {
        weak var value: ResourceCacheOwner?
        init(_ value: ResourceCacheOwner) { self.value = value }
    }
    private static let lock = NSLock()
    private static var caches: [WeakCache] = []
    private static var background = true
    fileprivate static func register(_ cache: ResourceCacheOwner) {
        lock.lock()
        caches.removeAll { $0.value == nil }; caches.append(WeakCache(cache))
        let live = caches.compactMap(\.value)
        let retired = rebalance(live)
        lock.unlock()
        withExtendedLifetime((live, retired)) {}
    }
    static func setBackground(_ value: Bool) {
        lock.lock(); background = value
        caches.removeAll { $0.value == nil }
        let live = caches.compactMap(\.value)
        let retired = rebalance(live)
        lock.unlock()
        withExtendedLifetime((live, retired)) {}
    }
    // The role's budget is shared across all live instances, not multiplied
    // when a module recreates its worker or several windows share a role.
    private static func rebalance(_ live: [ResourceCacheOwner]) -> [Any] {
        let counts = live.reduce(into: [Role: Int]()) { $0[$1.role, default: 0] += 1 }
        return live.flatMap { cache in
            let copies = counts[cache.role] ?? 1
            let bytes = background ? cache.role.backgroundBytes : cache.role.foregroundBytes
            return cache.apply(bytes: bytes / copies, count: cache.role.count / copies)
        }
    }
}

final class ResourceCache<Key: Hashable, Value>: ResourceCacheOwner, @unchecked Sendable {
    fileprivate let role: ResourceCaches.Role
    private let storage = CostBoundedCache<Key, Value>(bytes: 0, count: 0)
    init(_ role: ResourceCaches.Role) { self.role = role; ResourceCaches.register(self) }
    func object(forKey key: Key) -> Value? { storage.object(forKey: key) }
    func setObject(_ value: Value, forKey key: Key, cost: Int) { storage.setObject(value, forKey: key, cost: cost) }
    func removeAllObjects() { storage.removeAllObjects() }
    #if KEYLANE_RESOURCE_TESTING
    var retainedCost: Int { storage.cost }
    #endif
    fileprivate func apply(bytes: Int, count: Int) -> [Any] {
        storage.setLimits(bytes: bytes, count: count).map { $0 as Any }
    }
}
