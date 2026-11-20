import Foundation

public struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var duration: TimeInterval
    public var rawText: String
    public var text: String
    public var application: String
    public var styleName: String?
    public var error: String?
    public var hasRecording: Bool
    public init(id: UUID = UUID(), date: Date = Date(), duration: TimeInterval, rawText: String = "", text: String = "",
                application: String = "", styleName: String? = nil, error: String? = nil, hasRecording: Bool = false) {
        self.id = id; self.date = date; self.duration = duration; self.rawText = rawText; self.text = text
        self.application = application; self.styleName = styleName; self.error = error; self.hasRecording = hasRecording
    }
}

public struct DictationStatistics: Equatable, Sendable {
    public let words: Int
    public let sessions: Int
    public let wordsPerMinute: Int
    public let secondsSaved: TimeInterval
    public let activity: [Int]
    public init(records: [DictationRecord], now: Date = Date(), calendar: Calendar = .current) {
        let completed = records.filter { !$0.text.isEmpty && $0.error == nil }
        sessions = completed.count
        words = completed.reduce(0) { sum, record in
            var count = 0
            record.text.enumerateSubstrings(in: record.text.startIndex..., options: .byWords) { _, _, _, _ in count += 1 }
            return sum + count
        }
        let seconds = completed.reduce(0) { $0 + max(0, $1.duration) }
        wordsPerMinute = seconds > 0 ? Int(Double(words) / seconds * 60) : 0
        secondsSaved = max(0, Double(words) / 40 * 60 - seconds)
        let start = calendar.startOfDay(for: now)
        activity = (0..<7).reversed().map { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: start) else { return 0 }
            return completed.filter { calendar.isDate($0.date, inSameDayAs: date) }.count
        }
    }
}

/// A single owner serializes history writes and audio deletion. Nothing is synced or exported.
public actor DictationHistory {
    public let directory: URL
    private var deleted = Set<UUID>()
    private var clearedAt = Date.distantPast
    public init(directory: URL) { self.directory = directory }
    private var index: URL { directory.appendingPathComponent("history.json") }

    public func recordingURL(_ id: UUID) throws -> URL {
        try prepare()
        return directory.appendingPathComponent(id.uuidString).appendingPathExtension("m4a")
    }
    public func list() throws -> [DictationRecord] {
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        let data = try Data(contentsOf: index)
        guard data.count <= 32_000_000 else { throw AITranscriptionError.responseTooLarge }
        return try JSONDecoder().decode([DictationRecord].self, from: data).sorted { $0.date > $1.date }
    }
    public func save(_ record: DictationRecord, retainRecording: Bool) throws {
        guard !deleted.contains(record.id), record.date > clearedAt else {
            try discardRecording(record.id)
            return
        }
        var records = try list()
        records.removeAll { $0.id == record.id }
        var updated = record
        let recording = try recordingURL(record.id)
        updated.hasRecording = retainRecording && FileManager.default.fileExists(atPath: recording.path)
        records.insert(updated, at: 0)
        try write(records)
        if !retainRecording { try discardRecording(record.id) }
    }
    public func remove(_ id: UUID) throws {
        try write(list().filter { $0.id != id })
        deleted.insert(id)
        try discardRecording(id)
    }
    public func removeAll() throws {
        try write([])
        clearedAt = Date()
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "m4a" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
            try FileManager.default.removeItem(at: url)
        }
    }
    public func discardRecording(_ id: UUID) throws {
        let url = try recordingURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func write(_ records: [DictationRecord]) throws {
        try prepare()
        let data = try JSONEncoder().encode(records)
        guard data.count <= 32_000_000 else { throw AITranscriptionError.responseTooLarge }
        try data.write(to: index, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
    }
}
