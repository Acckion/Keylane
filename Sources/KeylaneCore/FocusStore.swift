import Foundation

public struct FocusPreferences: Codable, Equatable, Sendable {
    public var snoozeMinutes = 3
    public var allowAllWebsites = false
    public var restoreApplications = false
    public var playSound = true
    public var inMenuBar = false
    public init() {}
}

public struct FocusRecord: Codable, Equatable, Sendable {
    public let session: FocusSession
    public let ended: Date
    public let completed: Bool
    public init(session: FocusSession, ended: Date, completed: Bool) {
        var settled = session; settled.pause(at: ended)
        self.session = settled; self.ended = ended; self.completed = completed
    }
}

public struct FocusArchive: Codable, Equatable, Sendable {
    public var categories: [FocusCategory] = []
    public var lastConfiguration = FocusConfiguration()
    public var preferences = FocusPreferences()
    public var session: FocusSession?
    public var systemLink = FocusSystemLink()
    public var checkpoint: Date?
    public var terminatedApplications: [URL] = []
    public var history: [FocusRecord] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case categories, lastConfiguration, preferences, session, checkpoint, terminatedApplications, history, systemLink }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        categories = try values.decodeIfPresent([FocusCategory].self, forKey: .categories) ?? []
        lastConfiguration = try values.decodeIfPresent(FocusConfiguration.self, forKey: .lastConfiguration) ?? .init()
        preferences = try values.decodeIfPresent(FocusPreferences.self, forKey: .preferences) ?? .init()
        session = try values.decodeIfPresent(FocusSession.self, forKey: .session)
        checkpoint = try values.decodeIfPresent(Date.self, forKey: .checkpoint)
        terminatedApplications = try values.decodeIfPresent([URL].self, forKey: .terminatedApplications) ?? []
        systemLink = try values.decodeIfPresent(FocusSystemLink.self, forKey: .systemLink) ?? .init()
        history = try values.decodeIfPresent([FocusRecord].self, forKey: .history) ?? []
    }
}

public final class FocusStore {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Keylane/Focus/state.json")
    }
    private let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> FocusArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return FocusArchive() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32_000_000 else { throw FocusError.storage }
        return try JSONDecoder().decode(FocusArchive.self, from: Data(contentsOf: url))
    }
    public func save(_ archive: FocusArchive) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(archive)
        guard data.count <= 32_000_000 else { throw FocusError.storage }
        try data.write(to: url, options: .atomic)
    }

    public static func decodeCategories(_ data: Data) throws -> [FocusCategory] {
        guard data.count <= 2_000_000 else { throw FocusError.invalidImport }
        let decoder = JSONDecoder()
        struct Export: Codable { var version: Int; var categories: [FocusCategory] }
        let categories: [FocusCategory]
        if let export = try? decoder.decode(Export.self, from: data), export.version == 1 {
            categories = export.categories
        } else if let list = try? decoder.decode([FocusCategory].self, from: data) {
            categories = list
        } else { throw FocusError.invalidImport }
        guard !categories.isEmpty, categories.count <= 200 else { throw FocusError.invalidImport }
        var ids = Set<UUID>()
        return try categories.map {
            let value = try $0.validated()
            guard ids.insert(value.id).inserted else { throw FocusError.invalidImport }
            return value
        }
    }
    public static func encodeCategories(_ categories: [FocusCategory]) throws -> Data {
        struct Export: Encodable { let version = 1; let categories: [FocusCategory] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(categories: try categories.map { try $0.validated() }))
    }
}
