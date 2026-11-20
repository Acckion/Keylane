import Foundation
import CryptoKit
import SQLite3
import Darwin

/// Fixed destination IDs: a source export can never select an arbitrary filesystem path.
public enum MigrationResourceID: String, Codable, CaseIterable {
    case snippets, clipboard, conversations, focus
    public var relativePath: String {
        switch self {
        case .snippets: "data.sqlite"
        case .clipboard: "Clipboard/clipboard.sqlite"
        case .conversations: "AI/history.sqlite"
        case .focus: "Focus/state.json"
        }
    }
    var sqlite: Bool { self != .focus }
}

/// The user's confirmed, normalized import is replayed before controllers open their stores.
/// Every preference/resource must still match either its before or after state. Crash recovery
/// rolls forward; unknown edits stop the transaction instead of overwriting them.
public enum RaycastMigrationTransaction {
    public struct Resource: Codable {
        public let id: MigrationResourceID
        public let before: Data?
        public let after: Data
        public init(id: MigrationResourceID, before: Data?, after: Data) { self.id = id; self.before = before; self.after = after }
    }
    private struct Intent: Codable {
        let version: Int
        let keys: [String]
        let before: Data
        let after: Data
        var resources: [Resource]
        let undo: Bool
        var started: Bool? = nil
    }
    public static let maximumBytes = 256 * 1024 * 1024
    private static func pending(_ directory: URL) -> URL { directory.appendingPathComponent("raycast-pending.plist") }
    private static func receipt(_ directory: URL) -> URL { directory.appendingPathComponent("raycast-last.plist") }
    public static func hasPending(in directory: URL) -> Bool { FileManager.default.fileExists(atPath: pending(directory).path) }

    public static func stage(changes: [String:Any], current: [String:Any], resources: [Resource], directory: URL) throws {
        guard !changes.isEmpty || !resources.isEmpty else { throw ConfigurationError("没有需要导入的更改。") }
        guard !hasPending(in: directory), !FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending.plist").path) else { throw ConfigurationError("已有待处理导入，请先完成或取消。") }
        guard Set(resources.map(\.id)).count == resources.count else { throw ConfigurationError("迁移资源重复。") }
        let before = current.filter { changes[$0.key] != nil }
        try save(Intent(version: 1, keys: changes.keys.sorted(), before: plist(before), after: plist(changes), resources: resources, undo: false), to: pending(directory))
    }
    public static func cancel(directory: URL, root: URL, current: [String:Any]) throws {
        guard hasPending(in: directory) else { return }
        let intent = try load(pending(directory))
        if intent.started != true { try FileManager.default.removeItem(at: pending(directory)); return }
        guard matches(current, try dictionary(intent.before), keys: intent.keys),
              try intent.resources.allSatisfy({ try fingerprint(snapshot($0.id, root: root), id: $0.id) == fingerprint($0.before, id: $0.id) }) else {
            throw ConfigurationError("导入已经部分应用，请重启完成后再撤销，未删除恢复记录。")
        }
        try FileManager.default.removeItem(at: pending(directory))
    }
    public static func stageUndo(directory: URL, root: URL, current: [String:Any]) throws {
        guard !hasPending(in: directory), !FileManager.default.fileExists(atPath: directory.appendingPathComponent("pending.plist").path) else { throw ConfigurationError("请先完成待处理导入。") }
        let old = try load(receipt(directory))
        guard matches(current, try dictionary(old.after), keys: old.keys) else { throw ConfigurationError("导入后相关设置已改变，无法自动撤销。") }
        var inverse: [Resource] = []
        for resource in old.resources {
            let found = try snapshot(resource.id, root: root)
            let value = Resource(id: resource.id, before: resource.after, after: resource.before ?? Data())
            guard try canApply(value, current: found) else { throw ConfigurationError("导入后相关资料已改变，无法自动撤销。请先备份，再手动处理。") }
            inverse.append(try rebasedFocus(value, current: found, undo: true))
        }
        try save(Intent(version: 1, keys: old.keys, before: old.after, after: old.before, resources: inverse, undo: true), to: pending(directory))
    }
    public static func hasStarted(in directory: URL) -> Bool {
        guard let intent = try? load(pending(directory)) else { return true }; return intent.started == true
    }
    public static func canUndo(in directory: URL) -> Bool { FileManager.default.fileExists(atPath: receipt(directory).path) }

    @discardableResult public static func finish(directory: URL, root: URL,
        read: () -> [String:Any], persist: ([String:Any]) -> Bool) throws -> Bool {
        try finish(directory: directory, root: root, read: read, persist: persist, installationObserver: { _, _ in })
    }

    // An instance-scoped seam for isolated interruption tests; no process-global fault state.
    enum InstallationEvent: String, CaseIterable { case created, copying, verified, published }
    @discardableResult static func finish(directory: URL, root: URL,
        read: () -> [String:Any], persist: ([String:Any]) -> Bool,
        installationObserver: (InstallationEvent, URL) throws -> Void) throws -> Bool {
        guard hasPending(in: directory) else { return false }
        var intent = try load(pending(directory))
        let before = try dictionary(intent.before), after = try dictionary(intent.after)
        let current = read()
        guard matches(current, before, keys: intent.keys) || matches(current, after, keys: intent.keys) else { throw ConfigurationError("待导入设置已被修改，已停止迁移。") }
        // Focus checkpoints change during normal shutdown. Only categories belong to this
        // import; preserve the latest independent session/preferences/history fields.
        if intent.started != true {
            for index in intent.resources.indices where intent.resources[index].id == .focus {
                let resource = intent.resources[index]
                let found = try snapshot(.focus, root: root)
                let target: Data? = intent.undo && resource.after.isEmpty ? nil : resource.after
                if try fingerprint(found, id: .focus) != fingerprint(target, id: .focus) {
                    intent.resources[index] = try rebasedFocus(resource, current: found, undo: intent.undo)
                }
            }
        }
        // Validate ALL resources before the first write, including replay after interruption.
        for resource in intent.resources {
            let found = try fingerprint(snapshot(resource.id, root: root), id: resource.id)
            let target: Data? = intent.undo && resource.after.isEmpty ? nil : resource.after
            let original = try fingerprint(resource.before, id: resource.id)
            let final = try fingerprint(target, id: resource.id)
            guard found == original || found == final else {
                throw ConfigurationError("待导入资料已被修改，已停止迁移并保留恢复记录。")
            }
        }
        if intent.started != true { intent.started = true; try save(intent, to: pending(directory)) }
        for resource in intent.resources {
            let target: Data? = intent.undo && resource.after.isEmpty ? nil : resource.after
            if try fingerprint(snapshot(resource.id, root: root), id: resource.id) != fingerprint(target, id: resource.id) {
                try install(target, id: resource.id, root: root, observer: installationObserver)
            }
        }
        for resource in intent.resources {
            let target: Data? = intent.undo && resource.after.isEmpty ? nil : resource.after
            guard try fingerprint(snapshot(resource.id, root: root), id: resource.id) == fingerprint(target, id: resource.id) else { throw ConfigurationError("迁移资料校验失败，恢复记录已保留。") }
        }
        var updated = current
        for key in intent.keys { updated[key] = after[key] }
        guard persist(updated), matches(read(), after, keys: intent.keys) else { throw ConfigurationError("迁移设置未能保存。恢复记录已保留，下次启动可继续。") }
        if !intent.undo { try save(intent, to: receipt(directory)) }
        try FileManager.default.removeItem(at: pending(directory))
        return true
    }

    /// Validates only fields owned by the import; independent Focus state may advance.
    public static func canApply(_ resource: Resource, current: Data?) throws -> Bool {
        if resource.id == .focus,
           let before = focus(resource.before), let found = focus(current) {
            return before.categories == found.categories
        }
        return try fingerprint(resource.before, id: resource.id) == fingerprint(current, id: resource.id)
    }
    private static func focus(_ data: Data?) -> FocusArchive? {
        guard let data else { return FocusArchive() }
        return try? JSONDecoder().decode(FocusArchive.self, from: data)
    }
    private static func rebasedFocus(_ resource: Resource, current: Data?, undo: Bool) throws -> Resource {
        guard resource.id == .focus, current != resource.before else { return resource }
        guard let before = focus(resource.before), var found = focus(current),
              let target = focus(undo && resource.after.isEmpty ? nil : resource.after), before.categories == found.categories else {
            throw ConfigurationError("专注分类在预览后发生变化，已停止导入。")
        }
        let remove = undo && resource.after.isEmpty && found == before
        found.categories = target.categories
        return Resource(id: .focus, before: current, after: remove ? Data() : try JSONEncoder().encode(found))
    }

    /// A consistent, read-only snapshot; preview never opens the original store for writing.
    public static func snapshot(_ id: MigrationResourceID, root: URL) throws -> Data? {
        try parents(id, root: root)
        let url = root.appendingPathComponent(id.relativePath)
        guard exists(url) else { return nil }
        try regular(url)
        if !id.sqlite { return try boundedRead(url) }
        return try temporary { temp in
            let target = temp.appendingPathComponent("snapshot.sqlite")
            try backup(from: url, to: target)
            return try boundedRead(target)
        }
    }
    public static func fingerprint(_ data: Data?, id: MigrationResourceID) throws -> String {
        guard let data else { return "missing" }
        guard data.count <= maximumBytes else { throw ConfigurationError("迁移资料超过大小限制。") }
        if !id.sqlite { return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        return try temporary { temp in
            let file = temp.appendingPathComponent("read.sqlite")
            try privateWrite(data, to: file)
            var db: OpaquePointer?
            guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); throw ConfigurationError("迁移数据库无法读取。") }
            defer { sqlite3_close(db) }
            var hash = SHA256()
            func include(_ value: Data) { var size = UInt64(value.count).littleEndian; withUnsafeBytes(of: &size) { hash.update(data: Data($0)) }; hash.update(data: value) }
            var schema: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT type,name,sql FROM sqlite_master ORDER BY type,name", -1, &schema, nil) == SQLITE_OK else {
                throw ConfigurationError("无法校验资料结构。") }
            defer { sqlite3_finalize(schema) }
            while true {
                let status = sqlite3_step(schema)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw ConfigurationError("无法校验资料结构。") }
                for column: Int32 in 0..<3 { if let value = sqlite3_column_text(schema, column) { include(Data(String(cString: value).utf8)) } else { include(Data()) } }
            }
            for pragma in ["user_version", "application_id"] {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, "PRAGMA " + pragma, -1, &statement, nil) == SQLITE_OK else { throw ConfigurationError("无法校验资料版本。") }
                defer { sqlite3_finalize(statement) }
                guard sqlite3_step(statement) == SQLITE_ROW else { throw ConfigurationError("无法校验资料版本。") }
                include(Data(String(sqlite3_column_int64(statement, 0)).utf8))
            }
            var tables: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name", -1, &tables, nil) == SQLITE_OK else { throw ConfigurationError("无法读取迁移资料结构。") }
            defer { sqlite3_finalize(tables) }
            while true {
                let status = sqlite3_step(tables)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW, let namePointer = sqlite3_column_text(tables, 0) else { throw ConfigurationError("无法读取迁移资料结构。") }
                let name = String(cString: namePointer)
                include(Data(name.utf8))
                if let sql = sqlite3_column_text(tables, 1) { include(Data(String(cString: sql).utf8)) }
                let quoted = name.replacingOccurrences(of: "\"", with: "\"\"")
                var rows: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT * FROM \"\(quoted)\"", -1, &rows, nil) == SQLITE_OK else { throw ConfigurationError("无法校验迁移资料。") }
                defer { sqlite3_finalize(rows) }
                var hashes: [Data] = []
                while true {
                    let status = sqlite3_step(rows)
                    if status == SQLITE_DONE { break }
                    guard status == SQLITE_ROW else { throw ConfigurationError("无法校验迁移记录。") }
                    var row = Data()
                    for column in 0..<sqlite3_column_count(rows) {
                        let type = sqlite3_column_type(rows, column); row.append(UInt8(type))
                        let count = sqlite3_column_bytes(rows, column)
                        var size = UInt64(count).littleEndian; withUnsafeBytes(of: &size) { row.append(contentsOf: $0) }
                        if count > 0, let bytes = sqlite3_column_blob(rows, column) { row.append(Data(bytes: bytes, count: Int(count))) }
                    }
                    hashes.append(Data(SHA256.hash(data: row)))
                }
                for row in hashes.sorted(by: { $0.lexicographicallyPrecedes($1) }) { include(row) }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }
    private static func install(_ data: Data?, id: MigrationResourceID, root: URL,
                                observer: (InstallationEvent, URL) throws -> Void) throws {
        try parents(id, root: root)
        let destination = root.appendingPathComponent(id.relativePath)
        if exists(destination) { try regular(destination) }
        guard let data else {
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: destination.path + suffix)
                if exists(file) { try regular(file); try FileManager.default.removeItem(at: file) }
            }
            return
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !id.sqlite { try privateWrite(data, to: destination); return }
        try temporary { temp in
            let source = temp.appendingPathComponent("source.sqlite"); try privateWrite(data, to: source)
            if exists(destination) {
                // Keep SQLite's transactional backup for existing stores, including live WAL readers.
                try backup(from: source, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            } else {
                // Never create a partial database at the final path. The candidate lives on the
                // same volume, is closed and verified before an exclusive atomic rename.
                var name = Array(destination.deletingLastPathComponent().appendingPathComponent(".keylane-migration-XXXXXX").path.utf8CString)
                let descriptor = mkstemp(&name)
                guard descriptor >= 0 else { throw ConfigurationError("无法准备迁移资料库。") }
                let candidate = URL(fileURLWithPath: String(cString: name))
                close(descriptor) // mkstemp creates the file with mode 0600.
                defer {
                    for suffix in ["", "-wal", "-shm", "-journal"] {
                        try? FileManager.default.removeItem(atPath: candidate.path + suffix)
                    }
                }
                try observer(.created, candidate)
                try backup(from: source, to: candidate, standalone: true, pagesPerStep: 16) {
                    try observer(.copying, candidate)
                }
                guard try fingerprint(boundedRead(candidate), id: id) == fingerprint(data, id: id) else {
                    throw ConfigurationError("新资料库校验失败，未发布迁移结果。")
                }
                try observer(.verified, candidate)
                // RENAME_EXCL also rejects a destination created after the absence check.
                guard renamex_np(candidate.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw ConfigurationError("无法发布新资料库，目标可能已改变。恢复记录已保留。")
                }
                try observer(.published, destination)
            }
        }
    }
    private static func backup(from source: URL, to destination: URL, standalone: Bool = false,
                               pagesPerStep: Int32 = -1, progress: () throws -> Void = {}) throws {
        let newDestination = !exists(destination)
        var input: OpaquePointer?, output: OpaquePointer?
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(input); throw ConfigurationError("无法创建迁移数据库快照。") }
        defer { sqlite3_close(input) }
        guard sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(output); throw ConfigurationError("无法保存迁移数据库快照。") }
        defer { sqlite3_close(output) }
        sqlite3_busy_timeout(input, 2000); sqlite3_busy_timeout(output, 2000)
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw ConfigurationError("资料库正在使用，请重试。") }
        var status: Int32
        do {
            repeat {
                status = sqlite3_backup_step(backup, pagesPerStep)
                if status == SQLITE_OK || status == SQLITE_DONE { try progress() }
            } while status == SQLITE_OK
        } catch { sqlite3_backup_finish(backup); throw error }
        let finished = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finished == SQLITE_OK else {
            throw ConfigurationError("资料库快照未完成，未确认迁移成功。") }
        // Backup copies the source header's WAL mode. Normalize standalone snapshots before
        // reading their bytes, or reopening a copied header can require a missing WAL/shm.
        guard !(newDestination || standalone) || sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw ConfigurationError("无法完成迁移快照。") }
        guard sqlite3_close(output) == SQLITE_OK else { throw ConfigurationError("无法关闭迁移快照。") }
        output = nil
        guard sqlite3_close(input) == SQLITE_OK else { throw ConfigurationError("无法关闭迁移来源。") }
        input = nil
    }
    private static func matches(_ source: [String:Any], _ expected: [String:Any], keys: [String]) -> Bool {
        NSDictionary(dictionary: source.filter { keys.contains($0.key) }).isEqual(to: expected)
    }
    private static func plist(_ value: [String:Any]) throws -> Data { try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) }
    private static func dictionary(_ data: Data) throws -> [String:Any] {
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String:Any] else { throw ConfigurationError("迁移设置结构损坏。") }; return result
    }
    private static func load(_ url: URL) throws -> Intent {
        try regular(url)
        let intent = try PropertyListDecoder().decode(Intent.self, from: boundedRead(url))
        guard intent.version == 1, Set(intent.keys).count == intent.keys.count,
              Set(intent.resources.map(\.id)).count == intent.resources.count,
              Set(try dictionary(intent.before).keys).isSubset(of: Set(intent.keys)),
              Set(try dictionary(intent.after).keys).isSubset(of: Set(intent.keys)) else { throw ConfigurationError("迁移事务记录无效。") }
        return intent
    }
    private static func save(_ intent: Intent, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try PropertyListEncoder().encode(intent)
        guard data.count <= maximumBytes else { throw ConfigurationError("迁移事务超过大小限制。") }
        try privateWrite(data, to: url)
    }
    private static func privateWrite(_ data: Data, to url: URL) throws {
        if exists(url) { try regular(url) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func boundedRead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw ConfigurationError("迁移资料超过大小限制。") }; return data
    }
    private static func exists(_ url: URL) -> Bool {
        // attributesOfItem uses lstat semantics and also detects dangling symlinks.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    private static func parents(_ id: MigrationResourceID, root: URL) throws {
        var path = root
        for component in [""] + id.relativePath.split(separator: "/").dropLast().map(String.init) {
            if !component.isEmpty { path.appendPathComponent(component) }
            if exists(path) {
                let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw ConfigurationError("迁移资料目录包含不支持的链接或文件。") }
            }
        }
    }
    private static func regular(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ConfigurationError("迁移路径不是普通文件。") }
    }
    private static func temporary<T>(_ action: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneMigration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: url) }
        return try action(url)
    }
}
