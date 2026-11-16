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
    public final class Name: NSObject {
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
    private static let cache: NSCache<NSString, Name> = { let value = NSCache<NSString, Name>(); value.countLimit = 4096; return value }()
    public static func prepareName(_ text: String) -> Name {
        if let value = cache.object(forKey: text as NSString) { return value }
        let value = Name(text); cache.setObject(value, forKey: text as NSString); return value
    }
    public struct Query {
        fileprivate let plain: String
        fileprivate let simplified: String
        fileprivate let compact: String

        public init(_ text: String) {
            plain = SearchRanker.normalize(text)
            simplified = plain.isEmpty ? "" : SearchRanker.prepareName(plain).simplified
            // Spaces between pinyin syllables do not occur in a compact transliteration.
            compact = plain.replacingOccurrences(of: " ", with: "")
        }

        public var isEmpty: Bool { plain.isEmpty }
    }

    public static func score(_ title: String, query: String) -> Int? {
        let prepared = Query(query)
        return prepared.isEmpty ? 0 : score(prepareName(title), query: prepared)
    }

    public static func score(_ name: Name, query: Query) -> Int? {
        guard !query.isEmpty else { return 0 }
        var best = -1
        func match(_ text: String, _ needle: String) {
            if text == needle { best = 1000; return }
            if best >= 800 { return }
            if text.hasPrefix(needle) { best = 800; return }
            if best >= 600 { return }
            if text.contains(needle) { best = 600; return }
            if best >= 300 { return }
            var remaining = text[...]
            var gaps = 0
            for char in needle {
                guard let index = remaining.firstIndex(of: char) else { return }
                gaps += remaining.distance(from: remaining.startIndex, to: index)
                remaining = remaining[remaining.index(after: index)...]
            }
            best = max(best, max(1, 300 - gaps))
        }
        match(name.plain, query.plain)
        match(name.simplified, query.simplified)
        match(name.latin, query.compact)
        match(name.initials, query.compact)
        return best >= 0 ? best : nil
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
    public static func evaluate(_ input: String, locale: Locale = Locale(identifier: "en_US_POSIX")) -> Double? {
        guard input.utf16.count <= 512 else { return nil }
        let normalized = decimalInput(input.folding(options: .widthInsensitive, locale: locale), locale: locale)
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
        var parser = Parser(chars: Array(normalized.lowercased()))
        parser.skipSpaces()
        _ = parser.consume("=")
        guard let value = parser.expression(), value.isFinite else { return nil }
        parser.skipSpaces()
        return parser.index == parser.chars.count ? value : nil
    }

    static func decimalInput(_ input: String, locale: Locale) -> String {
        guard let separator = locale.decimalSeparator, separator != "." else { return input }
        return input.replacingOccurrences(of: separator, with: ".")
    }

    public static func format(_ value: Double, locale: Locale = .current) -> String {
        let number = String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value)
        return number.replacingOccurrences(of: ".", with: locale.decimalSeparator ?? ".")
    }

    public static func isExpression(_ input: String) -> Bool {
        let text = input.folding(options: .widthInsensitive, locale: .current)
        return text.first == "=" || text.contains(where: { "+-−*/×÷^%()".contains($0) })
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var depth = 0

        mutating func skipSpaces() {
            while index < chars.count && chars[index].isWhitespace { index += 1 }
        }

        mutating func consume(_ character: Character) -> Bool {
            skipSpaces()
            guard index < chars.count, chars[index] == character else { return false }
            index += 1
            return true
        }

        mutating func expression() -> Double? {
            guard var value = product() else { return nil }
            while true {
                if consume("+") {
                    guard let rhs = product() else { return nil }
                    value += rhs
                } else if consume("-") {
                    guard let rhs = product() else { return nil }
                    value -= rhs
                } else { return value }
            }
        }

        mutating func product() -> Double? {
            guard var value = unary() else { return nil }
            while true {
                if consume("*") {
                    guard let rhs = unary() else { return nil }
                    value *= rhs
                } else if consume("/") {
                    guard let rhs = unary(), rhs != 0 else { return nil }
                    value /= rhs
                } else { return value }
            }
        }

        mutating func unary() -> Double? {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { return nil }
            if consume("+") { return unary() }
            if consume("-") { return unary().map { -$0 } }
            guard var value = atom() else { return nil }
            if consume("%") { value /= 100 }
            if consume("^") {
                guard let rhs = unary() else { return nil }
                value = pow(value, rhs)
            }
            return value.isFinite ? value : nil
        }

        mutating func atom() -> Double? {
            if consume("(") {
                guard let value = expression(), consume(")") else { return nil }
                return value
            }
            skipSpaces()
            let start = index
            while index < chars.count && chars[index].isLetter { index += 1 }
            if index > start {
                let name = String(chars[start..<index])
                switch name {
                case "pi", "π": return .pi
                case "e": return exp(1)
                default:
                    guard consume("("), let x = expression(), consume(")") else { return nil }
                    switch name {
                    case "sqrt": return sqrt(x)
                    case "abs": return abs(x)
                    case "ln": return log(x)
                    case "log": return log10(x)
                    case "sin": return sin(x)
                    case "cos": return cos(x)
                    case "tan": return tan(x)
                    default: return nil
                    }
                }
            }
            while index < chars.count && (chars[index].isASCII && chars[index].isNumber || chars[index] == ".") { index += 1 }
            guard index > start else { return nil }
            if index < chars.count, chars[index] == "e" {
                index += 1
                if index < chars.count, chars[index] == "+" || chars[index] == "-" { index += 1 }
                while index < chars.count && chars[index].isASCII && chars[index].isNumber { index += 1 }
            }
            return Double(String(chars[start..<index]))
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
            guard version <= 2 else { throw StoreError.incompatibleVersion(version) }
            try execute("""
                PRAGMA busy_timeout=2000;
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, updated REAL NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS records_fts USING fts5(id UNINDEXED,title,body);
                """)
            if version < 2 { try removeLegacyNotes() }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func removeLegacyNotes() throws {
        // Rebuild FTS from surviving rows so deleted text is removed from its
        // shadow tables as well. Record the migration only after compaction.
        try execute("PRAGMA secure_delete=ON; BEGIN IMMEDIATE;")
        do {
            try execute("""
                DELETE FROM records WHERE kind='note';
                DROP TABLE records_fts;
                CREATE VIRTUAL TABLE records_fts USING fts5(id UNINDEXED,title,body);
                INSERT INTO records_fts SELECT id,title,body FROM records;
                COMMIT;
                """)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        try execute("VACUUM;")
        guard sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        try execute("PRAGMA user_version=2;")
    }

    private func execute(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) } }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }
        for (i,v) in values.enumerated() { sqlite3_bind_text(stmt, Int32(i+1), v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }; return stmt
    }
    private func write(_ sql: String, _ values: [String]) throws { let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }; guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) } }
    public func save(_ record: Record) throws { try save([record]) }

    public func save(_ records: [Record]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for record in records {
                let values = [record.id, record.kind, record.title, record.body, String(record.updated)]
                try write("INSERT INTO records VALUES(?,?,?,?,?) ON CONFLICT(id) DO NOTHING", values)
                if sqlite3_changes(db) == 0 {
                    try write("INSERT OR REPLACE INTO records VALUES(?,?,?,?,?)", values)
                    // The FTS id is unindexed. Only scan it when replacing an existing row.
                    try write("DELETE FROM records_fts WHERE id=?", [record.id])
                }
                try write("INSERT INTO records_fts VALUES(?,?,?)", [record.id, record.title, record.body])
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    public func remove(id: String) throws { try execute("BEGIN IMMEDIATE"); do { try write("DELETE FROM records WHERE id=?",[id]); try write("DELETE FROM records_fts WHERE id=?",[id]); try execute("COMMIT") } catch { try? execute("ROLLBACK"); throw error } }
    public func records(kind: String) throws -> [Record] {
        let stmt = try statement("SELECT id,kind,title,body,updated FROM records WHERE kind=? ORDER BY updated DESC,id ASC", [kind]); defer { sqlite3_finalize(stmt) }; var result: [Record] = []
        while true { let status = sqlite3_step(stmt); if status == SQLITE_DONE { break }; guard status == SQLITE_ROW else { throw StoreError.sqlite(String(cString: sqlite3_errmsg(db))) }; func text(_ index: Int32) -> String { String(cString: sqlite3_column_text(stmt,index)) }; result.append(Record(id: text(0), kind: text(1), title: text(2), body: text(3), updated: sqlite3_column_double(stmt,4))) }; return result
    }
    public func export(to url: URL) throws { let all = try ["link", "snippet"].flatMap { try records(kind: $0) }; try JSONEncoder().encode(all).write(to: url, options: .atomic) }
}
