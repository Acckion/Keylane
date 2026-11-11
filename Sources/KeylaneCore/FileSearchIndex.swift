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
    private var db: OpaquePointer?
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
                PRAGMA user_version=1;
                """)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
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
        try write("DELETE FROM files WHERE root=? AND epoch<>? AND path IN (SELECT path FROM files WHERE path=? UNION ALL SELECT path FROM files WHERE path>=? AND path<?)",
                  [root, epoch, subtree, lower, upper])
    }
    public func removeScope(_ root: String) throws { try write("DELETE FROM files WHERE root=?",[root]) }
    public func removeUnavailableVolumes() throws {
        let s = try statement("SELECT DISTINCT volume FROM files"); var volumes: [String] = []
        while sqlite3_step(s) == SQLITE_ROW { volumes.append(text(s,0)) }; sqlite3_finalize(s)
        for volume in volumes where !FileManager.default.fileExists(atPath:volume) { try write("DELETE FROM files WHERE volume=?",[volume]) }
    }
    public func clearBodies() throws { try exec("UPDATE files SET body='' WHERE body<>''") }
    public func clear() throws { try exec("DELETE FROM files; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;") }
    public func stats() throws -> FileIndexStats {
        let s = try statement("SELECT count(*),coalesce(sum(directory=0 AND symlink=0),0),coalesce(sum(directory),0),coalesce(sum(symlink),0) FROM files"); defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { throw FileIndexError.database }
        var result = FileIndexStats(); result.entries = Int(sqlite3_column_int(s,0)); result.files = Int(sqlite3_column_int(s,1)); result.directories = Int(sqlite3_column_int(s,2)); result.symlinks = Int(sqlite3_column_int(s,3))
        result.bytes = [url.path,url.path+"-wal",url.path+"-shm"].reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int) ?? 0) }
        return result
    }
    public func search(_ query: String, options: FileSearchOptions, excluded: [String] = [], limit: Int = 200, isCancelled: @escaping () -> Bool = { false }) throws -> [SpotlightFile] {
        try searchRanked(query, options: options, excluded: excluded, limit: limit, isCancelled: isCancelled).map(\.file)
    }
    public func searchRanked(_ query: String, options: FileSearchOptions, excluded: [String] = [], limit: Int = 200, isCancelled: @escaping () -> Bool = { false }) throws -> [RankedFile] {
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
                // Names and bodies are already folded. Match the literal substring directly.
                conditions.append(options.contentSearch ? "(instr(name, ?) > 0 OR instr(body, ?) > 0)" : "instr(name, ?) > 0")
                values.append(word)
                if options.contentSearch { values.append(word) }
            }
        }
        if !options.externalVolumes { conditions.append("external=0") }
        // Root ownership is stored separately from the path: no user text becomes SQL.
        conditions.append("root IN (" + options.roots.map { _ in "?" }.joined(separator: ",") + ")"); values += options.roots
        // Names are already folded in storage. Apply relevance before the candidate cap
        // so an older exact hit cannot be excluded by newer substring or body matches.
        let phrase = FileSearchRules.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let allNameWords = words.map { _ in "instr(name, ?) > 0" }.joined(separator: " AND ")
        let relevance = "CASE WHEN name=? THEN 0 WHEN instr(name,?)=1 THEN 1 WHEN instr(name,?)>0 THEN 2 WHEN (" + allNameWords + ") THEN 3 ELSE 4 END"
        values += [phrase, phrase, phrase] + words
        let sql = "SELECT path,modified FROM files WHERE " + conditions.joined(separator: " AND ")
            + " ORDER BY " + relevance + ",modified DESC,path LIMIT 2000"
        let s = try statement(sql, values)
        defer { sqlite3_finalize(s) }
        var results: [SpotlightFile] = []
        let ignored = FileSearchRules.pathFilter(options.ignorePatterns)
        while true {
            let status = sqlite3_step(s); if status == SQLITE_DONE { break }; if isCancelled() { return [] }; guard status == SQLITE_ROW else { throw FileIndexError.database }
            let url = URL(fileURLWithPath: text(s,0)); let path = url.path
            guard options.includeHidden || !path.split(separator:"/").contains(where: { $0.hasPrefix(".") }),
                  !excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }),
                  !ignored(path,url.lastPathComponent) else { continue }
            results.append(SpotlightFile(url:url,name:url.lastPathComponent,modified:Date(timeIntervalSince1970:sqlite3_column_double(s,1))))
        }
        return RankedFile.top(results, query: query, limit: max(1, min(200, limit)))
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
