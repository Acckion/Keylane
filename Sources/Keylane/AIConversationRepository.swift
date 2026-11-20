import Foundation
import SQLite3

struct AIChatSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let updated: Date
    var pinned = false
    var archived = false
    var projectID: UUID?
}

struct AIChatRecord: Sendable {
    struct ModelReference: Codable, Equatable, Sendable {
        let profileID: UUID
        let endpoint: String
        let model: String

        init(importedModel: String) {
            profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            endpoint = "raycast-import:unavailable"
            model = importedModel
        }

        init(_ connection: AIConnection) {
            profileID = connection.id
            endpoint = connection.requestIdentity
            model = connection.model
        }
    }

    struct Content: Codable, Sendable {
        let model: ModelReference
        let turns: [AIConversationTurn]
        var instructions: String?
    }

    let id: UUID
    let content: Content
}

/// All operations are serialized, including a final snapshot followed by deletion.
final class AIConversationRepository: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "org.keylane.ai-chat-history", qos: .utility)
    private enum DatabaseError: Error { case open, read, write }

    init(url: URL) { self.url = url }

    func perform<Value: Sendable>(_ operation: @escaping @Sendable (AIConversationRepository) throws -> Value,
                                 completion: @escaping @Sendable (Result<Value, Error>) -> Void) {
        queue.async { [self] in
            let result = Result { try operation(self) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func list() throws -> [AIChatSummary] {
        try withStatement("SELECT c.id, COALESCE(m.title, c.title), c.updated, COALESCE(m.pinned, 0), COALESCE(m.archived, 0), m.project_id FROM chats c LEFT JOIN chat_metadata m ON c.id = m.id ORDER BY c.updated DESC, c.id", values: []) { stmt in
            var result: [AIChatSummary] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW,
                      let id = sqlite3_column_text(stmt, 0), let uuid = UUID(uuidString: String(cString: id)),
                      let title = sqlite3_column_text(stmt, 1) else { throw DatabaseError.read }
                result.append(.init(id: uuid, title: String(cString: title),
                                    updated: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                                    pinned: sqlite3_column_int(stmt, 3) != 0, archived: sqlite3_column_int(stmt, 4) != 0,
                                    projectID: sqlite3_column_text(stmt, 5).flatMap { UUID(uuidString: String(cString: $0)) }))
            }
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

    /// Isolated migration copies only; keeps source dates and never resolves a model/account.
    func importHistory(_ record: AIChatRecord, title: String, updated: Date, archived: Bool) throws {
        let payload = String(decoding: try JSONEncoder().encode(record.content), as: UTF8.self)
        try withStatement("""
            INSERT INTO chats(id,title,content,updated) VALUES(?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title,content=excluded.content,updated=excluded.updated
            """, values: [record.id.uuidString, String(title.prefix(120)), payload, String(updated.timeIntervalSince1970)]) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw DatabaseError.write }
        }
        try update(record.id, change: .rename(title))
        try update(record.id, change: .archive(archived))
    }

    /// Must run on perform's serial queue, after pending source edits/deletions.
    func duplicate(_ id: UUID) throws -> UUID? {
        guard let record = try load(id), let summary = try list().first(where: { $0.id == id }) else { return nil }
        let projectID = try projects().contains(where: { $0.id == summary.projectID }) ? summary.projectID : nil
        let copy = AIChatRecord(id: UUID(), content: record.content)
        try save(copy, title: summary.title + " · 分支", projectID: projectID)
        return copy.id
    }

    func save(_ record: AIChatRecord, title: String, projectID: UUID?) throws {
        try save(record)
        if !title.isEmpty { try update(record.id, change: .rename(title)) }
        let validProject = try projects().contains(where: { $0.id == projectID }) ? projectID : nil
        try update(record.id, change: .project(validProject))
    }

    enum Change: Sendable {
        case pin(Bool), archive(Bool), rename(String), project(UUID?)
    }

    func update(_ id: UUID, change: Change) throws {
        let column: String
        let value: String
        switch change {
        case .pin(let pinned): column = "pinned"; value = pinned ? "1" : "0"
        case .archive(let archived): column = "archived"; value = archived ? "1" : "0"
        case .project(let id): column = "project_id"; value = id?.uuidString ?? ""
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
        try withStatement("DELETE FROM chats WHERE id = ?", values: [id.uuidString]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.write }
        }
    }

    func projects() throws -> [AIChatProject] {
        try withStatement("SELECT content FROM chat_projects", values: []) { stmt in
            var result: [AIChatProject] = []
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
                guard status == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { throw DatabaseError.read }
                result.append(try JSONDecoder().decode(AIChatProject.self, from: Data(String(cString: text).utf8)))
            }
        }
    }

    func saveProject(_ project: AIChatProject) throws {
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.name.count <= 120, project.instructions.utf8.count <= 32_000 else { throw DatabaseError.write }
        let content = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        try withStatement("INSERT INTO chat_projects(id, content) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET content=excluded.content",
                          values: [project.id.uuidString, content]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.write }
        }
    }

    func removeProject(_ id: UUID) throws {
        try withStatement("DELETE FROM chat_projects WHERE id = ?", values: [id.uuidString]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.write }
        }
    }

    private func withStatement<Value>(_ sql: String, values: [String],
                                      _ body: (OpaquePointer) throws -> Value) throws -> Value {
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
        // Additive migration: old chat content and metadata remain untouched.
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(chat_metadata)", -1, &columns, nil) == SQLITE_OK else { throw DatabaseError.read }
        var hasProject = false
        while sqlite3_step(columns) == SQLITE_ROW {
            if let name = sqlite3_column_text(columns, 1), String(cString: name) == "project_id" { hasProject = true }
        }
        sqlite3_finalize(columns)
        if !hasProject, sqlite3_exec(db, "ALTER TABLE chat_metadata ADD COLUMN project_id TEXT", nil, nil, nil) != SQLITE_OK {
            throw DatabaseError.write
        }
        guard sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS chat_projects(id TEXT PRIMARY KEY, content TEXT NOT NULL);
            CREATE TRIGGER IF NOT EXISTS chat_project_removed AFTER DELETE ON chat_projects
            BEGIN UPDATE chat_metadata SET project_id = '' WHERE project_id = OLD.id; END;
            """, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.write }
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

/// Local history IDs only; links never carry prompts, credentials or file paths.
enum AIChatLink {
    static func make(_ id: UUID) -> String { "keylane://ai/chat/" + id.uuidString.lowercased() }
    static func parse(_ url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "keylane", url.host?.lowercased() == "ai",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.pathComponents.count == 3, url.pathComponents[1] == "chat" else { return nil }
        return UUID(uuidString: url.pathComponents[2])
    }
}
