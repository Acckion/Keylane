import Foundation

/// Shared by controllers and sync adapters in this process. Never held during cloud I/O.
/// SQLite continues to own durable transactions; this closes the local UI check/write gap
/// between separate connections to the same module database.
public enum SyncMutationLock {
    private static let registryLock = NSLock()
    private static var locks: [String: NSRecursiveLock] = [:]
    public static func database(_ url: URL) -> NSRecursiveLock {
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        registryLock.lock(); defer { registryLock.unlock() }
        if let lock = locks[key] { return lock }
        let lock = NSRecursiveLock(); locks[key] = lock; return lock
    }
}
