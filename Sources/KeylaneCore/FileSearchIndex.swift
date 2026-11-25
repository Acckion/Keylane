import Foundation
import SQLite3
import PDFKit

public struct FileIndexStats: Codable, Equatable {
    public var entries = 0, files = 0, directories = 0, symlinks = 0, invalid = 0, bytes = 0
    public var seconds: Double = 0
    public init() {}
}
public struct FileIndexRecord {
    public let path: String, name: String, volume: String
    public let modified: Double
    public let directory: Bool, symlink: Bool, external: Bool
    public init(path: String, name: String, volume: String, modified: Double, directory: Bool, symlink: Bool, external: Bool = false) { self.path = path; self.name = name; self.volume = volume; self.modified = modified; self.directory = directory; self.symlink = symlink; self.external = external }
}
public enum FileIndexError: LocalizedError {
    case database, diskSpace, newerSchema
    public var errorDescription: String? { switch self { case .database: return "文件索引操作失败，请检查储存空间。"; case .diskSpace: return "可用空间不足，已暂停索引。"; case .newerSchema: return "文件索引来自更新的版本，无法打开。" } }
}
/// Separate writer and reader instances share this WAL database. Call each instance
/// on its own serial queue. No clipboard or note schema is accessed.
public final class FileSearchIndex {
    private final class QueryCancellation { let check: () -> Bool; init(_ check: @escaping () -> Bool) { self.check = check } }
    private final class QueryPathFilter {
        let options: FileSearchOptions
        let excluded: [String]
        let ignoresFile: (String, String) -> Bool
        let ignoresDirectory: (String, String) -> Bool
        let pathAllowed: ((String, Bool) -> Bool)?
        let isCancelled: () -> Bool
        init(options: FileSearchOptions, excluded: [String], pathAllowed: ((String, Bool) -> Bool)?, isCancelled: @escaping () -> Bool) {
            self.options = options; self.excluded = excluded; self.pathAllowed = pathAllowed
            ignoresFile = FileSearchRules.pathFilter(options.ignorePatterns)
            ignoresDirectory = FileSearchRules.pathFilter(options.ignorePatterns, directory: true)
            self.isCancelled = isCancelled
        }
        func allows(_ path: String, directory: Bool, owner: String) -> Bool {
            guard !isCancelled(), options.includeHidden || !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }),
                  !excluded.contains(where: { FileSearchLocation.contains(path, in: $0) }) else { return false }
            let url = URL(fileURLWithPath: path)
            guard !(directory ? ignoresDirectory : ignoresFile)(path, url.lastPathComponent) else { return false }
            // The host supplies its full scoped policy, including ignore files and
            // restored directories. SQL ownership remains independent of path aliases.
            if let pathAllowed { return pathAllowed(path, directory) }
            var parent = url.deletingLastPathComponent()
            while parent.path != owner && parent.path != "/" {
                guard !isCancelled(), !ignoresDirectory(parent.path, parent.lastPathComponent) else { return false }
                parent.deleteLastPathComponent()
            }
            return true
        }
    }
    private var db: OpaquePointer?
    private var activeRecoveryScan: UUID?
    public let url: URL
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); throw FileIndexError.database }
        do {
            try exec("PRAGMA busy_timeout=3000")
            let s = try statement("PRAGMA user_version"); let version = sqlite3_step(s) == SQLITE_ROW ? sqlite3_column_int(s, 0) : 0; sqlite3_finalize(s)
            guard version <= 1 else { throw FileIndexError.newerSchema }
            try exec("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,name TEXT NOT NULL,body TEXT NOT NULL DEFAULT '',root TEXT NOT NULL,volume TEXT NOT NULL,modified REAL NOT NULL,directory INTEGER NOT NULL,symlink INTEGER NOT NULL,external INTEGER NOT NULL DEFAULT 0,epoch TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS files_root ON files(root);
                CREATE INDEX IF NOT EXISTS files_name_search ON files(root,name,modified,path,external);
                CREATE VIRTUAL TABLE IF NOT EXISTS file_fts USING fts5(name,body,content='files',content_rowid='rowid',tokenize='trigram');
                CREATE TRIGGER IF NOT EXISTS file_ai AFTER INSERT ON files BEGIN INSERT INTO file_fts(rowid,name,body) VALUES(new.rowid,new.name,new.body); END;
                CREATE TRIGGER IF NOT EXISTS file_ad AFTER DELETE ON files BEGIN INSERT INTO file_fts(file_fts,rowid,name,body) VALUES('delete',old.rowid,old.name,old.body); END;
                CREATE TRIGGER IF NOT EXISTS file_au AFTER UPDATE OF name,body ON files BEGIN INSERT INTO file_fts(file_fts,rowid,name,body) VALUES('delete',old.rowid,old.name,old.body); INSERT INTO file_fts(rowid,name,body) VALUES(new.rowid,new.name,new.body); END;
                CREATE TABLE IF NOT EXISTS file_recovery(id INTEGER PRIMARY KEY CHECK(id=1),state TEXT NOT NULL);
                PRAGMA user_version=1;
                """)
            try prepareStatistics()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    public func releaseCachedPages() { sqlite3_db_release_memory(db) }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw FileIndexError.database } }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { throw FileIndexError.database }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index,value) in values.enumerated() { guard value.withCString({ sqlite3_bind_text(s, Int32(index+1), $0, Int32(value.utf8.count), transient) }) == SQLITE_OK else { sqlite3_finalize(s); throw FileIndexError.database } }
        return s
    }
    private func write(_ sql: String, _ values: [String] = []) throws { let s = try statement(sql, values); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_DONE else { throw FileIndexError.database } }
    private func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s,i).map { String(cString: $0) } ?? "" }
    public func put(_ record: FileIndexRecord, body: String = "", root: String, epoch: String) throws {
        try write("INSERT INTO files(path,name,body,root,volume,modified,directory,symlink,external,epoch) VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(path) DO UPDATE SET name=excluded.name,body=excluded.body,root=excluded.root,volume=excluded.volume,modified=excluded.modified,directory=excluded.directory,symlink=excluded.symlink,external=excluded.external,epoch=excluded.epoch",[record.path,FileSearchRules.fold(record.name),FileSearchRules.fold(body),root,record.volume,String(record.modified),record.directory ? "1":"0",record.symlink ? "1":"0",record.external ? "1":"0",epoch])
    }
    public func touchUnchanged(_ record: FileIndexRecord, root: String, epoch: String, contentSearch: Bool) throws -> Bool {
        try write("UPDATE files SET root=?,epoch=?,volume=?,external=? WHERE path=? AND modified=? AND directory=? AND symlink=? AND epoch LIKE ?",[root,epoch,record.volume,record.external ? "1":"0",record.path,String(record.modified),record.directory ? "1":"0",record.symlink ? "1":"0",contentSearch ? "c:%":"n:%"])
        return sqlite3_changes(db) > 0
    }
    public func transaction(_ body: () throws -> Void) throws { try exec("BEGIN IMMEDIATE"); do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error } }
    public func removeUnseen(root: String, epoch: String) throws { try write("DELETE FROM files WHERE root=? AND epoch<>?",[root,epoch]) }
    /// Limit reconciliation to the changed entry and its descendants.
    public func removeUnseen(root: String, subtree: String, epoch: String) throws {
        let lower = subtree + "/"
        let upper = subtree + "0" // The next byte after the slash, under SQLite's binary collation.
        // Bind row IDs first so SQLite cannot scan every record in the root
        // (including large body overflow pages) for each changed subtree.
        try write("DELETE FROM files WHERE rowid IN (SELECT rowid FROM files WHERE path=? UNION ALL SELECT rowid FROM files WHERE path>=? AND path<?) AND root=? AND epoch<>?",
                  [subtree, lower, upper, root, epoch])
    }
    /// Reconcile completed areas while retaining the last known rows below
    /// unreadable paths. Fetch bounded metadata batches, never file bodies.
    public func removeUnseen(root: String, subtree: String? = nil, epoch: String, preserving: Set<String>) throws {
        if preserving.isEmpty {
            if let subtree { try removeUnseen(root: root, subtree: subtree, epoch: epoch) }
            else { try removeUnseen(root: root, epoch: epoch) }
            return
        }
        var cursor: Int64 = 0
        while true {
            let candidates: String
            let values: [String]
            if let subtree {
                candidates = "rowid IN (SELECT rowid FROM files WHERE path=? UNION ALL SELECT rowid FROM files WHERE path>=? AND path<?) AND "
                values = [subtree, subtree + "/", subtree + "0", String(cursor), root, epoch]
            } else {
                candidates = ""
                values = [String(cursor), root, epoch]
            }
            let s = try statement("SELECT rowid,path FROM files WHERE " + candidates + "rowid>? AND root=? AND epoch<>? ORDER BY rowid LIMIT 512", values)
            var rows: [(Int64, String)] = []
            var status = sqlite3_step(s)
            while status == SQLITE_ROW {
                rows.append((sqlite3_column_int64(s, 0), text(s, 1)))
                status = sqlite3_step(s)
            }
            sqlite3_finalize(s)
            guard status == SQLITE_DONE else { throw FileIndexError.database }
            guard let last = rows.last else { return }
            cursor = last.0
            let ids = rows.compactMap { id, path -> String? in
                var ancestor = path
                while true {
                    if preserving.contains(ancestor) { return nil }
                    if ancestor == "/" { break }
                    ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
                }
                return String(id)
            }
            if !ids.isEmpty {
                try write("DELETE FROM files WHERE rowid IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")", ids)
            }
        }
    }
    public func removeScope(_ root: String) throws { try write("DELETE FROM files WHERE root=?",[root]) }
    public func removeUnavailableVolumes() throws {
        let s = try statement("SELECT DISTINCT volume FROM files"); var volumes: [String] = []
        while sqlite3_step(s) == SQLITE_ROW { volumes.append(text(s,0)) }; sqlite3_finalize(s)
        for volume in volumes where !FileManager.default.fileExists(atPath:volume) { try write("DELETE FROM files WHERE volume=?",[volume]) }
    }
    public func clearBodies() throws {
        // Clearing a body invalidates its extraction state even if the file has not changed.
        try exec("UPDATE files SET body='',epoch='n:' || substr(epoch,3) WHERE body<>''")
    }
    public func clear() throws {
        try transaction {
            try invalidateRecoveryPoint()
            try exec("DELETE FROM files")
        }
        // Maintenance may fail or be interrupted without unpairing data and checkpoint.
        try exec("PRAGMA wal_checkpoint(TRUNCATE); VACUUM;")
    }
    private func prepareStatistics() throws {
        // Initialize older indexes once. The immediate transaction serializes
        // concurrent reader/writer opens and keeps the snapshot and triggers atomic.
        try transaction {
            try exec("CREATE TABLE IF NOT EXISTS file_counts(id INTEGER PRIMARY KEY CHECK(id=1),entries INTEGER NOT NULL,files INTEGER NOT NULL,directories INTEGER NOT NULL,symlinks INTEGER NOT NULL)")
            let existing = try statement("SELECT 1 FROM file_counts WHERE id=1")
            let status = sqlite3_step(existing)
            sqlite3_finalize(existing)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw FileIndexError.database }
            if status == SQLITE_DONE {
                try exec("INSERT INTO file_counts SELECT 1,count(*),coalesce(sum(directory=0 AND symlink=0),0),coalesce(sum(directory),0),coalesce(sum(symlink),0) FROM files")
            }
            let triggers = try statement("""
                SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN
                ('file_recovery_files_insert','file_recovery_files_update','file_recovery_files_delete')
                """)
            let triggerStatus = sqlite3_step(triggers)
            let protected = triggerStatus == SQLITE_ROW && sqlite3_column_int(triggers, 0) == 3
            sqlite3_finalize(triggers)
            guard triggerStatus == SQLITE_ROW else { throw FileIndexError.database }
            if !protected {
                // An older writer could have changed rows before the triggers existed.
                // Preserve its rows but require a new recovery baseline once.
                try invalidateRecoveryPoint()
                try exec("""
                    CREATE TRIGGER IF NOT EXISTS file_recovery_files_insert AFTER INSERT ON files
                        WHEN EXISTS(SELECT 1 FROM file_recovery WHERE id=1) BEGIN DELETE FROM file_recovery WHERE id=1; END;
                    CREATE TRIGGER IF NOT EXISTS file_recovery_files_update AFTER UPDATE ON files
                        WHEN EXISTS(SELECT 1 FROM file_recovery WHERE id=1) BEGIN DELETE FROM file_recovery WHERE id=1; END;
                    CREATE TRIGGER IF NOT EXISTS file_recovery_files_delete AFTER DELETE ON files
                        WHEN EXISTS(SELECT 1 FROM file_recovery WHERE id=1) BEGIN DELETE FROM file_recovery WHERE id=1; END;
                    """)
            }
            // Every mutation participates in the caller's transaction, including
            // changes made by older app builds or another index connection.
            try exec("""
                CREATE TRIGGER IF NOT EXISTS file_counts_insert AFTER INSERT ON files BEGIN
                    UPDATE file_counts SET entries=entries+1,
                        files=files+(new.directory=0 AND new.symlink=0),
                        directories=directories+new.directory,symlinks=symlinks+new.symlink WHERE id=1;
                END;
                CREATE TRIGGER IF NOT EXISTS file_counts_delete AFTER DELETE ON files BEGIN
                    UPDATE file_counts SET entries=entries-1,
                        files=files-(old.directory=0 AND old.symlink=0),
                        directories=directories-old.directory,symlinks=symlinks-old.symlink WHERE id=1;
                END;
                CREATE TRIGGER IF NOT EXISTS file_counts_update AFTER UPDATE OF directory,symlink ON files
                    WHEN old.directory<>new.directory OR old.symlink<>new.symlink BEGIN
                    UPDATE file_counts SET files=files+(new.directory=0 AND new.symlink=0)-(old.directory=0 AND old.symlink=0),
                        directories=directories+new.directory-old.directory,
                        symlinks=symlinks+new.symlink-old.symlink WHERE id=1;
                END;
                """)
        }
    }

    public struct RecoveryPoint: Codable, Equatable, Sendable {
        public let eventID: UInt64
        public let configuration: String
        public let retryPaths: Set<String>
        public let historyDomain: UUID?
        public init(eventID: UInt64, configuration: String, retryPaths: Set<String> = [], historyDomain: UUID? = nil) {
            self.eventID = eventID
            self.configuration = configuration
            self.retryPaths = retryPaths
            self.historyDomain = historyDomain
        }
        private enum CodingKeys: String, CodingKey { case eventID, configuration, retryPaths, historyDomain }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventID = try c.decode(UInt64.self, forKey: .eventID)
            configuration = try c.decode(String.self, forKey: .configuration)
            retryPaths = try c.decodeIfPresent(Set<String>.self, forKey: .retryPaths) ?? []
            historyDomain = try c.decodeIfPresent(UUID.self, forKey: .historyDomain)
        }
    }

    public func recoveryPoint() throws -> RecoveryPoint? {
        let s = try statement("SELECT state FROM file_recovery WHERE id=1")
        defer { sqlite3_finalize(s) }
        let status = sqlite3_step(s)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw FileIndexError.database }
        return try? JSONDecoder().decode(RecoveryPoint.self, from: Data(text(s, 0).utf8))
    }

    public func saveRecoveryPoint(_ point: RecoveryPoint) throws {
        let state = String(decoding: try JSONEncoder().encode(point), as: UTF8.self)
        try write("INSERT INTO file_recovery(id,state) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state", [state])
    }

    public func invalidateRecoveryPoint() throws {
        activeRecoveryScan = nil
        try exec("DELETE FROM file_recovery WHERE id=1")
    }

    public struct RecoveryScan {
        fileprivate let id: UUID
        fileprivate let owner: ObjectIdentifier
        fileprivate let dataVersion: Int64
    }

    /// The cursor is absent throughout a scan. A partial scan must still have
    /// the matching complete baseline when it acquires the write lock.
    public func beginRecoveryScan(requiring configurations: Set<String>? = nil, historyDomain: UUID? = nil) throws -> RecoveryScan? {
        var scan: RecoveryScan?
        try transaction {
            if let configurations {
                guard let existing = try recoveryPoint(), existing.historyDomain == historyDomain,
                      configurations.contains(existing.configuration) else { return }
            }
            try invalidateRecoveryPoint()
            scan = .init(id: UUID(), owner: ObjectIdentifier(self), dataVersion: try dataVersion())
        }
        activeRecoveryScan = scan?.id
        return scan
    }

    /// SQLite data_version only compares observations on the same connection,
    /// and only changes for commits by other connections.
    public func completeRecoveryScan(_ scan: RecoveryScan, point: RecoveryPoint,
                                     whileCurrent isCurrent: () -> Bool = { true }) throws -> Bool {
        guard scan.owner == ObjectIdentifier(self), scan.id == activeRecoveryScan else { return false }
        activeRecoveryScan = nil
        var committed = false
        try transaction {
            guard isCurrent() else { return }
            guard try dataVersion() == scan.dataVersion else {
                try invalidateRecoveryPoint()
                return
            }
            guard isCurrent() else { return }
            try saveRecoveryPoint(point)
            committed = true
        }
        return committed
    }

    /// Idle cursor progress may update a matching point, never create one or
    /// overwrite another scan's outstanding repair work.
    public func advanceExistingRecoveryPoint(_ point: RecoveryPoint, compatibleConfiguration: String? = nil,
                                             whileCurrent isCurrent: () -> Bool = { true }) throws -> Bool {
        var matched = false
        try transaction {
            guard isCurrent(), let existing = try recoveryPoint(), existing.retryPaths == point.retryPaths,
                  existing.historyDomain == point.historyDomain,
                  existing.configuration == point.configuration || existing.configuration == compatibleConfiguration,
                  isCurrent() else { return }
            if point.eventID >= existing.eventID, point != existing {
                let state = String(decoding: try JSONEncoder().encode(point), as: UTF8.self)
                try write("UPDATE file_recovery SET state=? WHERE id=1", [state])
            }
            matched = true
        }
        return matched
    }

    private func dataVersion() throws -> Int64 {
        let s = try statement("PRAGMA data_version")
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw FileIndexError.database }
        return sqlite3_column_int64(s, 0)
    }

    public func stats() throws -> FileIndexStats {
        let s = try statement("SELECT entries,files,directories,symlinks FROM file_counts WHERE id=1"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw FileIndexError.database }
        var result = FileIndexStats(); result.entries = Int(sqlite3_column_int(s,0)); result.files = Int(sqlite3_column_int(s,1)); result.directories = Int(sqlite3_column_int(s,2)); result.symlinks = Int(sqlite3_column_int(s,3))
        result.bytes = [url.path,url.path+"-wal",url.path+"-shm"].reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int) ?? 0) }
        return result
    }
    public func search(_ query: String, options: FileSearchOptions, excluded: [String] = [], limit: Int = 200, within: String? = nil, pathAllowed: ((String, Bool) -> Bool)? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> [SpotlightFile] {
        try searchRanked(query, options: options, excluded: excluded, limit: limit, within: within, pathAllowed: pathAllowed, isCancelled: isCancelled).map(\.file)
    }
    public func searchRanked(_ query: String, options: FileSearchOptions, excluded: [String] = [], limit: Int = 200, within: String? = nil, pathAllowed: ((String, Bool) -> Bool)? = nil, isCancelled: @escaping () -> Bool = { false }) throws -> [RankedFile] {
        guard !isCancelled() else { return [] }
        let cancellation = QueryCancellation(isCancelled)
        sqlite3_progress_handler(db, 1000, { raw in
            guard let raw else { return 0 }
            return Unmanaged<QueryCancellation>.fromOpaque(raw).takeUnretainedValue().check() ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil); withExtendedLifetime(cancellation) {} }
        let words = FileSearchRules.tokens(query).map(FileSearchRules.fold)
        guard options.enabled, !words.isEmpty, query.count <= 256, !options.roots.isEmpty else { return [] }
        var conditions: [String] = []; var values: [String] = []
        for word in words {
            if word.count >= 3 {
                let phrase = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                conditions.append("rowid IN (SELECT rowid FROM file_fts WHERE file_fts MATCH ?)")
                values.append(options.contentSearch ? phrase : "name : " + phrase)
            } else {
                // Names are already folded. Match the literal substring directly.
                if options.contentSearch {
                    let literal = "%" + word.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "%", with: "\\%")
                        .replacingOccurrences(of: "_", with: "\\_") + "%"
                    conditions.append("(instr(name, ?) > 0 OR body LIKE ? ESCAPE '\\')")
                    values += [word, literal]
                } else {
                    conditions.append("instr(name, ?) > 0")
                    values.append(word)
                }
            }
        }
        if let within {
            guard within.hasPrefix("/"), !within.contains("\0") else { return [] }
            var ranges: [String] = []
            for root in LocalFilePath.indexAliases(within) {
                let lower = root == "/" ? "/" : root + "/", upper = root == "/" ? "0" : root + "0"
                ranges.append("(path=? OR (path>=? AND path<?))"); values += [root, lower, upper]
            }
            conditions.append("(" + ranges.joined(separator: " OR ") + ")")
        }
        // Filter saved ancestors in SQLite before either candidate or result cap.
        // The context checks paths without opening files, retaining offline rows.
        let pathFilter = QueryPathFilter(options: options, excluded: excluded, pathAllowed: pathAllowed, isCancelled: isCancelled)
        guard sqlite3_create_function_v2(db, "keylane_search_path_allowed", 3, SQLITE_UTF8,
            Unmanaged.passUnretained(pathFilter).toOpaque(), { context, count, arguments in
                guard let context, count == 3, let arguments,
                      let raw = sqlite3_user_data(context), let path = sqlite3_value_text(arguments[0]),
                      let owner = sqlite3_value_text(arguments[2]) else {
                    sqlite3_result_int(context, 0); return
                }
                let filter = Unmanaged<QueryPathFilter>.fromOpaque(raw).takeUnretainedValue()
                let allowed = filter.allows(String(cString: path), directory: sqlite3_value_int(arguments[1]) != 0, owner: String(cString: owner))
                sqlite3_result_int(context, allowed ? 1 : 0)
            }, nil, nil, nil) == SQLITE_OK else { throw FileIndexError.database }
        defer {
            sqlite3_create_function_v2(db, "keylane_search_path_allowed", 3, SQLITE_UTF8, nil, nil, nil, nil, nil)
            withExtendedLifetime(pathFilter) {}
        }
        conditions.append("keylane_search_path_allowed(path,directory,root)=1")
        if !options.externalVolumes { conditions.append("external=0") }
        // Root ownership is stored separately from the path: no user text becomes SQL.
        conditions.append("root IN (" + options.roots.map { _ in "?" }.joined(separator: ",") + ")"); values += options.roots
        // Names are already folded in storage. Apply relevance before the candidate cap
        // so an older exact hit cannot be excluded by newer substring or body matches.
        let phrase = FileSearchRules.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let allNameWords = words.map { _ in "instr(name, ?) > 0" }.joined(separator: " AND ")
        let relevance = "CASE WHEN name=? THEN 0 WHEN instr(name,?)=1 THEN 1 WHEN instr(name,?)>0 THEN 2 WHEN (" + allNameWords + ") THEN 3 ELSE 4 END"
        values += [phrase, phrase, phrase] + words
        // Use the covering index only when a name scan is unavoidable. FTS
        // queries should intersect their row IDs with the root index.
        let shortNameScan = !options.contentSearch && words.allSatisfy { $0.count < 3 }
        let searchIndex = shortNameScan ? "files_name_search" : "files_root"
        let sql = "SELECT path,modified,directory FROM files INDEXED BY " + searchIndex + " WHERE " + conditions.joined(separator: " AND ")
            + " ORDER BY " + relevance + ",modified DESC,path LIMIT 2000"
        let s = try statement(sql, values)
        defer { sqlite3_finalize(s) }
        var results: [RankedFile] = []
        let rank = FileSearchRules.ranker(for: query)
        let ignored = FileSearchRules.pathFilter(options.ignorePatterns)
        while true {
            let status = sqlite3_step(s); if status == SQLITE_DONE { break }; if isCancelled() { return [] }; guard status == SQLITE_ROW else { throw FileIndexError.database }
            let url = URL(fileURLWithPath: text(s,0)); let path = url.path
            guard options.includeHidden || !path.split(separator:"/").contains(where: { $0.hasPrefix(".") }),
                  !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  !ignored(path,url.lastPathComponent) else { continue }
            let name = url.lastPathComponent
            let score = rank(name)
            let file = SpotlightFile(url: url, name: name, modified: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                     isDirectory: sqlite3_column_int(s, 2) != 0,
                                     matchesContent: options.contentSearch && score == 0)
            results.append(RankedFile(file: file, score: score))
        }
        return Array(results.sorted { $0.precedes($1) }.prefix(max(1, min(200, limit))))
    }
    public static func content(at url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isUbiquitousItemKey,.isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
              values.isUbiquitousItem != true, (values.fileSize ?? 0) <= 2_097_152 else { return "" }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return String((PDFDocument(url:url)?.string ?? "").prefix(100_000)) }
        guard ["txt","md","csv","tsv","json","swift","js","ts","py","html","css","xml","yaml","yml","log"].contains(ext),
              let data = try? Data(contentsOf:url), let text = String(data:data,encoding:.utf8) else { return "" }
        return String(text.prefix(100_000))
    }
}
