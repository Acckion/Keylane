import Foundation

/// A durable, private intent file is applied before any app controllers exist.
/// Preferences are submitted as one domain update; an interrupted launch can be replayed safely.
public enum ConfigurationTransaction {
    public static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else { throw ConfigurationError("文件超过 16 MB。") }
        return data
    }
    public static func stage(changes: [String: Any], current: [String: Any], directory: URL) throws {
        guard !changes.isEmpty else { throw ConfigurationError("没有需要导入的更改。") }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let pending = directory.appendingPathComponent("pending.plist")
        guard !fm.fileExists(atPath: pending.path) else { throw ConfigurationError("已有等待重启的导入。请先重启 Keylane。") }
        let before = current.filter { changes[$0.key] != nil }
        let intent: [String: Any] = ["version": 1, "keys": changes.keys.sorted(), "before": before, "after": changes]
        let data = try PropertyListSerialization.data(fromPropertyList: intent, format: .binary, options: 0)
        // Save a recoverable inverse before accepting the pending transaction.
        try privateWrite(data, to: directory.appendingPathComponent("last-import.plist"))
        try privateWrite(data, to: pending)
    }
    public static func stageUndo(current: [String: Any], directory: URL) throws {
        let receipt = try readIntent(directory.appendingPathComponent("last-import.plist"))
        guard matches(current, receipt.after, receipt.keys) else { throw ConfigurationError("导入后相关配置已改变，无法自动撤销。请先导出当前配置，再手动恢复。") }
        let pending = directory.appendingPathComponent("pending.plist")
        guard !FileManager.default.fileExists(atPath: pending.path) else { throw ConfigurationError("请先重启完成待处理导入。") }
        let intent: [String: Any] = ["version": 1, "keys": receipt.keys, "before": receipt.after, "after": receipt.before]
        try privateWrite(PropertyListSerialization.data(fromPropertyList: intent, format: .binary, options: 0), to: pending)
    }
    public static func finish(defaults: UserDefaults, domain: String, directory: URL,
                              persist: (([String: Any]) -> Bool)? = nil) throws -> Bool {
        let pending = directory.appendingPathComponent("pending.plist")
        guard FileManager.default.fileExists(atPath: pending.path) else { return false }
        let intent = try readIntent(pending)
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        if !matches(current, intent.after, intent.keys) {
            guard matches(current, intent.before, intent.keys) else { throw ConfigurationError("待导入的配置已变化，已停止恢复，原配置未覆盖。") }
            var updated = current
            for key in intent.keys { updated[key] = intent.after[key] }
            let write = persist ?? { value in defaults.setPersistentDomain(value, forName: domain); return defaults.synchronize() }
            guard write(updated), matches(defaults.persistentDomain(forName: domain) ?? [:], intent.after, intent.keys) else {
                defaults.setPersistentDomain(current, forName: domain)
                guard defaults.synchronize() else { throw ConfigurationError("配置写入及恢复失败。保留了本地备份，请勿删除 ConfigurationRecovery 目录。") }
                throw ConfigurationError("配置写入失败，已恢复导入前配置。下次启动会重试；可取消待处理导入。")
            }
        }
        try FileManager.default.removeItem(at: pending)
        return true
    }
    public static func cancel(directory: URL) throws {
        let url = directory.appendingPathComponent("pending.plist")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private static func privateWrite(_ data: Data, to url: URL) throws {
        // Atomic temp creation inherits a private directory; final file is owner-only.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func readIntent(_ url: URL) throws -> (keys: [String], before: [String: Any], after: [String: Any]) {
        guard let object = try PropertyListSerialization.propertyList(from: read(url), format: nil) as? [String: Any],
              object["version"] as? Int == 1, let keys = object["keys"] as? [String],
              let before = object["before"] as? [String: Any], let after = object["after"] as? [String: Any],
              Set(keys).count == keys.count, Set(before.keys).isSubset(of: Set(keys)), Set(after.keys).isSubset(of: Set(keys)),
              keys.allSatisfy({ ConfigurationArchive.enums[$0] != nil || ConfigurationArchive.flags.contains($0) || ["launcherReturnDelay", "aliases", "shortcuts", "disabledLauncherCommands", QuicklinkLibrary.storageKey].contains($0) }) else {
            throw ConfigurationError("本地恢复记录损坏，未修改配置。")
        }
        return (keys, before, after)
    }
    private static func matches(_ current: [String: Any], _ desired: [String: Any], _ keys: [String]) -> Bool {
        keys.allSatisfy { ConfigurationArchive.equal(current[$0], desired[$0]) }
    }
}
