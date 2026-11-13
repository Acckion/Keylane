import Darwin
import Foundation

/// Read-only projection of a selected local extension's source metadata.
public struct RaycastExtensionManifest: Encodable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case view
        case noView = "no-view"
        case menuBar = "menu-bar"
    }

    public enum PreferenceValue: Codable, Equatable, Sendable {
        case string(String)
        case bool(Bool)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else { self = .string(try container.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            }
        }
    }

    public struct Field: Codable, Sendable {
        public struct Option: Codable, Sendable {
            public let title: String
            public let value: String
        }

        public let name: String
        public let type: String
        public let title: String?
        public let placeholder: String?
        public let required: Bool?
        public let label: String?
        public let description: String?
        public let defaultValue: PreferenceValue?
        public let options: [Option]?

        private enum CodingKeys: String, CodingKey {
            case name, type, title, label, description, placeholder, required
            case defaultValue = "default"
            case options = "data"
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            name = try values.decode(String.self, forKey: .name)
            type = try values.decode(String.self, forKey: .type)
            title = try values.decodeIfPresent(String.self, forKey: .title)
            label = try values.decodeIfPresent(String.self, forKey: .label)
            description = try values.decodeIfPresent(String.self, forKey: .description)
            placeholder = try values.decodeIfPresent(String.self, forKey: .placeholder)
            required = try values.decodeIfPresent(Bool.self, forKey: .required)
            defaultValue = try? values.decode(PreferenceValue.self, forKey: .defaultValue)
            options = type == "dropdown" ? try values.decodeIfPresent([Option].self, forKey: .options) : nil
        }

        public func accepts(_ value: PreferenceValue) -> Bool {
            switch (type, value) {
            case ("checkbox", .bool): true
            case ("dropdown", .string(let value)): options?.contains { $0.value == value } == true
            case ("textfield", .string): true
            default: false
            }
        }
    }

    public struct Command: Encodable, Sendable {
        public let id: String
        public let name: String
        public let title: String
        public let description: String?
        public let mode: Mode
        public let entry: String
        public let icon: String?
        public let keywords: [String]
        public let arguments: [Field]
        public let preferences: [Field]
        public let disabledByDefault: Bool
        public let backgroundIntervalSeconds: Int?
    }

    public let author: String
    public let name: String
    public let title: String
    public let description: String?
    public let icon: String?
    public let platforms: [String]?
    public let preferences: [Field]
    public let commands: [Command]

    public enum InvalidSource: LocalizedError {
        case missingDirectory
        case invalidManifestFile
        case manifestTooLarge
        case invalidIdentifier(String)
        case missingTitle(String)
        case commandCount
        case duplicateCommand(String)
        case unsupportedMode(String, String)
        case missingEntry(String)
        case ambiguousEntry(String)
        case unsafePath(String)
        case missingAsset(String)

        public var errorDescription: String? {
            switch self {
            case .missingDirectory: return "Select a local extension directory."
            case .invalidManifestFile: return "package.json must be a regular file within the extension."
            case .manifestTooLarge: return "package.json exceeds 1 MiB."
            case .invalidIdentifier(let name): return "Invalid identifier: \(name)"
            case .missingTitle(let name): return "Missing title for \(name)."
            case .commandCount: return "Expected between 1 and 256 commands."
            case .duplicateCommand(let name): return "Duplicate command: \(name)"
            case .unsupportedMode(let name, let mode): return "Unsupported mode \(mode) for \(name)."
            case .missingEntry(let name): return "No source entry in src/ for \(name)."
            case .ambiguousEntry(let name): return "Multiple source entries in src/ for \(name)."
            case .unsafePath(let path): return "Path escapes the selected extension directory: \(path)"
            case .missingAsset(let path): return "Missing asset: \(path)"
            }
        }
    }

    private struct Manifest: Decodable {
        struct Entry: Decodable {
            let name: String
            let title: String
            let description: String?
            let mode: String
            let icon: String?
            let keywords: [String]?
            let arguments: [Field]?
            let preferences: [Field]?
            let disabledByDefault: Bool?
            let interval: String?
        }

        let author: String
        let name: String
        let title: String
        let description: String?
        let icon: String?
        let platforms: [String]?
        let preferences: [Field]?
        let commands: [Entry]
    }

    public static func read(directory: URL) throws -> Self {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw InvalidSource.missingDirectory
        }
        let manifestURL = try containedFile("package.json", under: root)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData(manifestURL))
        try validateIdentifier(manifest.author)
        try validateIdentifier(manifest.name)
        try validateTitle(manifest.title, for: manifest.name)
        guard (1...256).contains(manifest.commands.count) else { throw InvalidSource.commandCount }
        let icon = try asset(manifest.icon, under: root)
        var names = Set<String>()
        let commands = try manifest.commands.map { command in
            try validateIdentifier(command.name)
            try validateTitle(command.title, for: command.name)
            guard names.insert(command.name.lowercased()).inserted else {
                throw InvalidSource.duplicateCommand(command.name)
            }
            guard let mode = Mode(rawValue: command.mode) else {
                throw InvalidSource.unsupportedMode(command.name, command.mode)
            }
            let entries = try ["ts", "tsx", "js", "jsx"].compactMap { suffix -> String? in
                let path = "src/\(command.name).\(suffix)"
                let url = try containedFile(path, under: root)
                return isRegularFile(url) ? path : nil
            }
            guard let entry = entries.first else { throw InvalidSource.missingEntry(command.name) }
            guard entries.count == 1 else { throw InvalidSource.ambiguousEntry(command.name) }
            let id = "extension:raycast:\(manifest.author)/\(manifest.name)/\(command.name)"
            return Command(id: id, name: command.name, title: command.title, description: command.description,
                           mode: mode, entry: entry, icon: try asset(command.icon, under: root) ?? icon,
                           keywords: command.keywords ?? [], arguments: command.arguments ?? [],
                           preferences: command.preferences ?? [], disabledByDefault: command.disabledByDefault ?? false,
                           backgroundIntervalSeconds: mode == .view ? nil : intervalSeconds(command.interval))
        }
        return Self(author: manifest.author, name: manifest.name, title: manifest.title,
                    description: manifest.description, icon: icon, platforms: manifest.platforms, preferences: manifest.preferences ?? [],
                    commands: commands)
    }

    private static func intervalSeconds(_ interval: String?) -> Int? {
        guard let interval, let unit = interval.last,
              let multiplier = ["s": 1, "m": 60, "h": 3600, "d": 86400][String(unit)],
              let amount = Int(interval.dropLast()), amount > 0 else { return nil }
        let (seconds, overflow) = amount.multipliedReportingOverflow(by: multiplier)
        return overflow || seconds < 10 ? nil : seconds
    }

    private static func validateIdentifier(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count <= 128, name != ".", name != "..",
              name.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
                  byte == 45 || byte == 46 || byte == 95
              }) else { throw InvalidSource.invalidIdentifier(name) }
    }

    private static func validateTitle(_ title: String, for name: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw InvalidSource.missingTitle(name)
        }
    }

    private static func asset(_ icon: String?, under root: URL) throws -> String? {
        guard let icon else { return nil }
        let components = icon.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw InvalidSource.unsafePath(icon)
        }
        let path = "assets/\(icon)"
        guard isRegularFile(try containedFile(path, under: root)) else {
            throw InvalidSource.missingAsset(path)
        }
        return path
    }

    private static func containedFile(_ path: String, under root: URL) throws -> URL {
        let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.pathComponents.count > root.pathComponents.count,
              url.pathComponents.starts(with: root.pathComponents) else {
            throw InvalidSource.unsafePath(path)
        }
        return url
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func manifestData(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw InvalidSource.invalidManifestFile }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw InvalidSource.invalidManifestFile
        }
        let limit = 1_048_576
        guard info.st_size <= limit else { throw InvalidSource.manifestTooLarge }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw InvalidSource.manifestTooLarge }
        return data
    }
}
