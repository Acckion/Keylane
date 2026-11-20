import Foundation
import KeylaneCore

// Native temporary-file handlers plus the real shared permission/runtime boundary.
// No network, account, application launch, or user file is used.
@main struct FileToolsIntegration {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: AIFileToolService.systemPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("KeylaneToolFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "KeylaneFileToolsFixture-" + UUID().uuidString
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let preferences = AIFileToolPreferences(store: store)
        var project: AIChatProject?
        func registrations() -> [AIToolRegistration] {
            AIFileToolProvider.registrations(preferences: preferences, project: project, currentProject: { project })
        }
        precondition(!preferences.enabled && registrations().isEmpty)
        preferences.add(.init(path: root.path))
        preferences.enabled = true
        let restored = AIFileToolPreferences(store: store)
        precondition(restored.enabled && restored.scopes == preferences.scopes)
        let textURL = root.appendingPathComponent("note.txt")
        try Data("fixture text".utf8).write(to: textURL)
        try Data("private fixture".utf8).write(to: root.appendingPathComponent(".env"))
        var approvals = 0
        var allow = false
        var onApproval: (() -> Void)?
        func run(_ tools: [AIToolRegistration]? = nil) throws -> AIToolRun {
            try AIToolRun(registrations: tools ?? registrations(), isCurrent: { true }) { _, _ in
                approvals += 1; onApproval?(); return allow
            }
        }
        func execute(_ run: AIToolRun, _ name: String, _ arguments: [String: AIToolValue]) async throws -> AIToolResult {
            try await run.execute(AIToolCall(id: UUID().uuidString, name: "keylane_" + name, arguments: arguments), scope: "fixture", progress: { _ in })
        }
        let normal = try await execute(run(), "read_file", ["path": .string("note.txt")])
        precondition(!normal.isError && normal.text.contains("fixture text") && approvals == 0)
        let deniedSensitive = try await execute(run(), "read_file", ["path": .string(".env")])
        precondition(deniedSensitive.isError && !deniedSensitive.text.contains("private fixture") && approvals == 1)
        allow = true
        let sensitive = try await execute(run(), "read_file", ["path": .string(".env")])
        precondition(!sensitive.isError && sensitive.text.contains("private fixture") && approvals == 2)
        allow = false
        let write: [String: AIToolValue] = ["path": .string("created.txt"), "content": .string("created fixture")]
        let denied = try await execute(run(), "write_file", write)
        precondition(denied.isError && !FileManager.default.fileExists(atPath: root.appendingPathComponent("created.txt").path))
        allow = true
        let written = try await execute(run(), "write_file", write)
        let createdText = try String(contentsOf: root.appendingPathComponent("created.txt"), encoding: .utf8)
        precondition(!written.isError && createdText == "created fixture")
        let noOverwrite = try await execute(run(), "write_file", write)
        precondition(noOverwrite.isError)
        onApproval = { preferences.remove(root.path); preferences.add(.init(path: root.path)) }
        let stale = try await execute(run(), "write_file", ["path": .string("stale.txt"), "content": .string("must not exist")])
        precondition(stale.isError && !FileManager.default.fileExists(atPath: root.appendingPathComponent("stale.txt").path))
        onApproval = nil
        let frozen = try run()
        preferences.enabled = false; preferences.enabled = true
        let revoked = try await execute(frozen, "read_file", ["path": .string("note.txt")])
        precondition(revoked.isError)
        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
        try Data("project default".utf8).write(to: projectRoot.appendingPathComponent("note.txt"))
        project = AIChatProject(name: "fixture", directory: projectRoot)
        let projectRead = try await execute(run(), "read_file", ["path": .string("note.txt")])
        precondition(!projectRead.isError && projectRead.text.contains("project default"))
        let projectRun = try run()
        project = nil
        let switched = try await execute(projectRun, "read_file", ["path": .string("note.txt")])
        precondition(switched.isError)
        var effects = 0
        let sentinel = AIToolRegistration(definition: try .init(name: "fixture_unused", title: "Read metadata", description: "Search only")) { _ in
            effects += 1; return try .init(text: "must not run")
        }
        let discovery = try run([sentinel, AIFileToolProvider.discovery([sentinel])])
        let metadata = try await execute(discovery, "search_tools", ["query": .string("Read")])
        precondition(!metadata.isError && metadata.text.contains("fixture_unused") && effects == 0)
        let bookmark = try root.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        preferences.remove(root.path); preferences.add(.init(path: root.path, bookmark: bookmark))
        let bookmarked = try await execute(run(), "read_file", ["path": .string("note.txt")])
        precondition(!bookmarked.isError)
        // A corrupt unrelated bookmark must not prevent access to the selected valid scope.
        preferences.add(.init(path: root.appendingPathComponent("unrelated").path, bookmark: Data([1, 2, 3])))
        let unrelated = try await execute(run(), "read_file", ["path": .string("note.txt")])
        precondition(!unrelated.isError)
        print("AI_FILE_TOOLS_INTEGRATION: default off, persistence, native reads, sensitive approval, denied/allowed writes, stale authorization, project switch, discovery isolation, unrelated bookmarks passed")
    }
}
