import Foundation
import SQLite3
import KeylaneCore

struct AIChatSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let updated: Date
    var pinned = false
    var archived = false
}

struct AIChatRecord: Sendable {
    struct ModelReference: Codable, Equatable, Sendable {
        let profileID: UUID
        let endpoint: String
        let model: String

        init(_ connection: AIConnection) {
            profileID = connection.id
            endpoint = connection.requestIdentity
            model = connection.model
        }
    }

    struct Content: Codable, Sendable {
        let model: ModelReference
        let turns: [QuickAIController.Turn]
        var instructions: String?
    }

    let id: UUID
    let content: Content
}

/// All operations are serialized, including a final snapshot followed by deletion.
final class AIChatHistory: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "org.keylane.ai-chat-history", qos: .utility)
    private enum DatabaseError: Error { case open, read, write }

    init(url: URL) { self.url = url }

    func perform<Value: Sendable>(_ operation: @escaping @Sendable (AIChatHistory) throws -> Value,
                                 completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try operation(self) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func list() throws -> [AIChatSummary] {
        try withStatement("SELECT c.id, COALESCE(m.title, c.title), c.updated, COALESCE(m.pinned, 0), COALESCE(m.archived, 0) FROM chats c LEFT JOIN chat_metadata m ON c.id = m.id ORDER BY c.updated DESC, c.id", values: []) { stmt in
            var result: [AIChatSummary] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW,
                      let id = sqlite3_column_text(stmt, 0), let uuid = UUID(uuidString: String(cString: id)),
                      let title = sqlite3_column_text(stmt, 1) else { throw DatabaseError.read }
                result.append(.init(id: uuid, title: String(cString: title),
                                    updated: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                                    pinned: sqlite3_column_int(stmt, 3) != 0, archived: sqlite3_column_int(stmt, 4) != 0))
            }
        }
    }

    func syncSummary(_ id: UUID) throws -> AIChatSummary? {
        try withStatement("SELECT c.id, COALESCE(m.title,c.title), c.updated, COALESCE(m.pinned,0), COALESCE(m.archived,0) FROM chats c LEFT JOIN chat_metadata m ON c.id=m.id WHERE c.id=?", values: [id.uuidString]) { stmt in
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let title = sqlite3_column_text(stmt, 1) else { throw DatabaseError.read }
            return AIChatSummary(id: id, title: String(cString: title), updated: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                                 pinned: sqlite3_column_int(stmt, 3) != 0, archived: sqlite3_column_int(stmt, 4) != 0)
        }
    }

    func load(_ id: UUID) throws -> AIChatRecord? {
        try withStatement("SELECT content FROM chats WHERE id = ?", values: [id.uuidString]) { stmt in
            let status = sqlite3_step(stmt)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw DatabaseError.read }
            let content = try JSONDecoder().decode(AIChatRecord.Content.self, from: Data(String(cString: text).utf8))
            return AIChatRecord(id: id, content: content)
        }
    }

    func save(_ record: AIChatRecord) throws {
        defer { NotificationCenter.default.post(name: .keylaneSyncSourceChanged, object: nil) }
        let question = record.content.turns.first?.question ?? ""
        let title = String(question.split(whereSeparator: \.isNewline).first?.prefix(72) ?? "")
        let payload = String(decoding: try JSONEncoder().encode(record.content), as: UTF8.self)
        try withStatement("""
            INSERT INTO chats(id, title, content, updated) VALUES(?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET content=excluded.content, updated=excluded.updated
            """, values: [record.id.uuidString, title, payload, String(Date().timeIntervalSince1970)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.write }
        }
    }

    enum Change: Sendable {
        case pin(Bool), archive(Bool), rename(String)
    }

    func update(_ id: UUID, change: Change) throws {
        defer { NotificationCenter.default.post(name: .keylaneSyncSourceChanged, object: nil) }
        let column: String
        let value: String
        switch change {
        case .pin(let pinned): column = "pinned"; value = pinned ? "1" : "0"
        case .archive(let archived): column = "archived"; value = archived ? "1" : "0"
        case .rename(let title):
            let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            guard !trimmed.isEmpty else { return }
            column = "title"; value = trimmed
        }
        try withStatement("INSERT INTO chat_metadata(id, \(column)) SELECT id, ? FROM chats WHERE id = ? ON CONFLICT(id) DO UPDATE SET \(column)=excluded.\(column)",
                          values: [value, id.uuidString]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.write }
        }
    }

    func remove(_ id: UUID) throws {
        defer { NotificationCenter.default.post(name: .keylaneSyncSourceChanged, object: nil) }
        try withStatement("DELETE FROM chats WHERE id = ?", values: [id.uuidString]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.write }
        }
    }

    /// One durable transaction for conversation and metadata; a failed import cannot leave a
    /// new body paired with old pin/title state and masquerade as a user edit on retry.
    func applySyncChat(_ id: UUID, value: SyncChat?) throws {
        try withStatement("SELECT 1", values: []) { sentinel in
            guard let database = sqlite3_db_handle(sentinel) else { throw DatabaseError.open }
            func execute(_ sql: String, _ values: [String] = []) throws {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw DatabaseError.write }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                for (offset, text) in values.enumerated() { sqlite3_bind_text(statement, Int32(offset + 1), text, -1, transient) }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.write }
            }
            try execute("BEGIN IMMEDIATE")
            do {
                if let value {
                    let content = String(decoding: try JSONEncoder().encode(value.content), as: UTF8.self)
                    try execute("INSERT INTO chats(id,title,content,updated) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,content=excluded.content,updated=excluded.updated", [id.uuidString, value.title, content, String(value.updated.timeIntervalSince1970)])
                    try execute("INSERT INTO chat_metadata(id,title,pinned,archived) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,pinned=excluded.pinned,archived=excluded.archived", [id.uuidString, value.title, value.pinned ? "1" : "0", value.archived ? "1" : "0"])
                } else { try execute("DELETE FROM chats WHERE id=?", [id.uuidString]) }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
        NotificationCenter.default.post(name: .keylaneSyncSourceChanged, object: nil)
    }

    var syncMutationGate: NSRecursiveLock { SyncMutationLock.database(url) }

    private func withStatement<Value>(_ sql: String, values: [String],
                                      _ body: (OpaquePointer) throws -> Value) throws -> Value {
        let mutationLock = SyncMutationLock.database(url); mutationLock.lock(); defer { mutationLock.unlock() }
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        if !files.fileExists(atPath: url.path),
           !files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) {
            throw DatabaseError.open
        }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw DatabaseError.open
        }
        sqlite3_busy_timeout(db, 2_000)
        guard sqlite3_exec(db, """
            PRAGMA secure_delete=ON;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS chats(
              id TEXT PRIMARY KEY, title TEXT NOT NULL, content TEXT NOT NULL, updated REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS chats_updated ON chats(updated DESC);
            CREATE TABLE IF NOT EXISTS chat_metadata(
              id TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
              title TEXT, pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0
            );
            """, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.open }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw DatabaseError.read
        }
        defer { sqlite3_finalize(prepared) }
        for (index, value) in values.enumerated() {
            guard let count = Int32(exactly: value.utf8.count) else { throw DatabaseError.write }
            let bound = value.withCString {
                sqlite3_bind_text(prepared, Int32(index + 1), $0, count,
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard bound == SQLITE_OK else { throw DatabaseError.write }
        }
        return try body(prepared)
    }
}
