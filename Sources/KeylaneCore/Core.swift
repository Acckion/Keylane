import Foundation
import SQLite3

public struct CommandDescriptor: Identifiable, Codable, Equatable {
    public let id: String
    public var title: String
    public var aliases: [String]
    public var requiredPermissions: [String]
    public init(id: String, title: String, aliases: [String] = [], requiredPermissions: [String] = []) { self.id = id; self.title = title; self.aliases = aliases; self.requiredPermissions = requiredPermissions }
}
public enum SearchRanker {
    private final class Terms: NSObject {
        let plain: String
        let simplified: String
        let latin: String
        let initials: String
        init(_ title: String) {
            plain = SearchRanker.normalize(title)
            simplified = plain.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? plain
            let words = SearchRanker.normalize(title.applyingTransform(.toLatin, reverse: false) ?? title)
            latin = words.replacingOccurrences(of: " ", with: "")
            initials = words.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap(\.first).map(String.init).joined()
        }
    }
    private static let cache: NSCache<NSString, Terms> = { let value = NSCache<NSString, Terms>(); value.countLimit = 4096; return value }()
    private static func terms(_ text: String) -> Terms {
        if let value = cache.object(forKey: text as NSString) { return value }
        let value = Terms(text); cache.setObject(value, forKey: text as NSString); return value
    }
    public static func score(_ title: String, query: String) -> Int? {
        let query = normalize(query); if query.isEmpty { return 0 }
        let value = terms(title)
        let simplifiedQuery = terms(query).simplified
        // Spaces in pinyin are syllable boundaries, not characters that must occur
        // in an app's compact transliteration. Keep normal English phrase matching.
        let compactQuery = query.replacingOccurrences(of: " ", with: "")
        let pairs = [(value.plain, query), (value.simplified, simplifiedQuery), (value.latin, compactQuery), (value.initials, compactQuery)]
        return pairs.compactMap { text, needle -> Int? in
            if text == needle { return 1000 }; if text.hasPrefix(needle) { return 800 }
            if text.contains(needle) { return 600 }
            var remaining = text[...]; var gaps = 0
            for char in needle { guard let index = remaining.firstIndex(of: char) else { return nil }; gaps += remaining.distance(from: remaining.startIndex, to: index); remaining = remaining[remaining.index(after: index)...] }
            return max(1, 300 - gaps)
        }.max()
    }
    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public enum Calculator {
    public static func evaluate(_ input: String) -> Double? {
        var parser = Parser(chars: Array(input.filter { !$0.isWhitespace })); guard !parser.chars.isEmpty, parser.chars.count < 512 else { return nil }
        guard let value = parser.expression(), parser.i == parser.chars.count, value.isFinite else { return nil }; return value
    }
    private struct Parser {
        let chars: [Character]; var i = 0; var depth = 0
        mutating func consume(_ c: Character) -> Bool { if i < chars.count, chars[i] == c { i += 1; return true }; return false }
        mutating func expression() -> Double? { guard var x = term() else { return nil }; while i < chars.count { if consume("+") { guard let y = term() else { return nil }; x += y } else if consume("-") { guard let y = term() else { return nil }; x -= y } else { break } }; return x }
        mutating func term() -> Double? { guard var x = factor() else { return nil }; while i < chars.count { if consume("*") { guard let y = factor() else { return nil }; x *= y } else if consume("/") { guard let y = factor(), y != 0 else { return nil }; x /= y } else { break } }; return x }
        mutating func factor() -> Double? {
            depth += 1; defer { depth -= 1 }; guard depth < 64 else { return nil }
            if consume("+") { return factor() }; if consume("-") { return factor().map { -$0 } }
            if consume("(") { guard let v = expression(), consume(")") else { return nil }; return v }
            let start = i; while i < chars.count && (chars[i].isNumber || chars[i] == ".") { i += 1 }
            guard i > start else { return nil }; return Double(String(chars[start..<i]))
        }
    }
}
public struct Record: Identifiable, Codable, Equatable {
    public var id: String; public var kind: String; public var title: String; public var body: String; public var updated: Double
    public init(id: String = UUID().uuidString, kind: String, title: String, body: String, updated: Double = Date().timeIntervalSince1970) { self.id = id; self.kind = kind; self.title = title; self.body = body; self.updated = updated }
}
public enum StoreError: Error { case sqlite(String); case incompatibleVersion(Int32) }
public final class Store {
    private var db: OpaquePointer?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.sqlite("Cannot open database") }
        do {
            var statement: OpaquePointer?; sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil);
            let version = sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : 0
            sqlite3_finalize(statement)
            guard version <= 1 else { throw StoreError.incompatibleVersion(version) }
            try execute("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, updated REAL NOT NULL); CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(id UNINDEXED,title,body); PRAGMA user_version=1;")
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) } }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        for (i,v) in values.enumerated() { sqlite3_bind_text(stmt, Int32(i+1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }; return stmt
    }
    private func write(_ sql: String, _ values: [String]) throws { let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) } }
    public func save(_ record: Record) throws {
        try execute("BEGIN IMMEDIATE"); do {
            try write("INSERT OR REPLACE INTO records VALUES(?,?,?,?,?)", [record.id, record.kind, record.title, record.body, String(record.updated)])
            try write("DELETE FROM records_fts WHERE id=?", [record.id]); try write("INSERT INTO records_fts VALUES(?,?,?)", [record.id, record.title, record.body]); try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func remove(id: String) throws { try execute("BEGIN IMMEDIATE"); do { try write("DELETE FROM records WHERE id=?",[id]); try write("DELETE FROM records_fts WHERE id=?",[id]); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error } }
    public func records(kind: String) throws -> [Record] {
        let stmt = try statement("SELECT id,kind,title,body,updated FROM records WHERE kind=? ORDER BY updated DESC,id ASC", [kind]); defer { sqlite3_finalize(stmt) }; var result: [Record] = []
        while true { let status = sqlite3_step(stmt); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }; func text(_ index: Int32) -> String { String(cString: sqlite3_column_text(stmt,index)) }; result.append(Record(id: text(0), kind: text(1), title: text(2), body: text(3), updated: sqlite3_column_double(stmt,4))) }; return result
    }
    public func export(to url: URL) throws { let all = try ["note", "link", "snippet"].flatMap { try records(kind: $0) }; try JSONEncoder().encode(all).write(to: url, options: .atomic) }
}
