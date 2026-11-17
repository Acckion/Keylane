import Combine
import Foundation

struct CustomAICommand: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var prompt = ""
    var connectionID: UUID?

    var commandID: String { "ai-command:" + id.uuidString.lowercased() }

    func validated() throws -> Self {
        var command = self
        command.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.title.isEmpty, command.title.count <= 100,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 32_000 else { throw CustomAICommandLibrary.Failure.invalidCommand }
        return command
    }
}

final class CustomAICommandLibrary: ObservableObject {
    enum Failure: LocalizedError {
        case invalidCommand, invalidArchive, unreadable

        var errorDescription: String? {
            switch self {
            case .invalidCommand: "请输入名称和提示词。名称限 100 个字符，提示词限 32 KB。"
            case .invalidArchive: "文件不是有效的 Keylane AI 命令导出文件，或超过导入上限。"
            case .unreadable: "无法读取已经保存的 AI 命令。"
            }
        }
    }

    private struct Archive: Codable {
        var version = 1
        var commands: [CustomAICommand]
    }

    private static let key = "customAICommands.v1"
    static let maximumArchiveBytes = 4_000_000
    @Published private(set) var commands: [CustomAICommand] = []
    private(set) var commandsByID: [String: CustomAICommand] = [:]
    let loadError: Failure?
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        guard let data = preferences.data(forKey: Self.key) else { loadError = nil; return }
        do {
            let saved = try Self.decode(data)
            loadError = nil
            replaceCommands(saved)
        } catch {
            loadError = .unreadable
        }
    }

    func save(_ draft: CustomAICommand) throws {
        let command = try draft.validated()
        var updated = commands
        if let index = updated.firstIndex(where: { $0.id == command.id }) {
            updated[index] = command
        } else {
            updated.append(command)
        }
        try persist(updated)
    }

    func remove(_ command: CustomAICommand) throws {
        try persist(commands.filter { $0.id != command.id })
    }

    func exportData() throws -> Data {
        if let loadError { throw loadError }
        return try Self.encode(commands)
    }

    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let incoming = try Self.decode(data)
        var updated = commands
        let existingIDs = Set(commands.map(\.id))
        for command in incoming where !existingIDs.contains(command.id) {
            updated.append(command)
        }
        let imported = updated.count - commands.count
        try persist(updated)
        return imported
    }

    private func persist(_ updated: [CustomAICommand]) throws {
        if let loadError { throw loadError }
        guard updated != commands else { return }
        let data = try Self.encode(updated)
        preferences.set(data, forKey: Self.key)
        replaceCommands(updated)
    }

    private func replaceCommands(_ updated: [CustomAICommand]) {
        commandsByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.commandID, $0) })
        commands = updated
    }

    private static func encode(_ commands: [CustomAICommand]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Archive(commands: commands))
        guard data.count <= maximumArchiveBytes else { throw Failure.invalidArchive }
        return data
    }

    private static func decode(_ data: Data) throws -> [CustomAICommand] {
        guard data.count <= maximumArchiveBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1,
              Set(archive.commands.map(\.id)).count == archive.commands.count else { throw Failure.invalidArchive }
        return try archive.commands.map { try $0.validated() }
    }
}
