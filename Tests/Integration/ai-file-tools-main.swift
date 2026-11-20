import Foundation
import Combine
import KeylaneCore

// Only owned synthetic directories and in-memory consent decisions. No account,
// network, system permission grant/bookmark creation, app launch or user file.
@MainActor final class IndexFixtureState { var searches = 0; var revision = 0 }

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
        func registrations(index: AIFileToolIndexSource? = nil) -> [AIToolRegistration] {
            AIFileToolProvider.registrations(preferences: preferences, project: project, currentProject: { project }, index: index)
        }
        precondition(!preferences.enabled && registrations().isEmpty)
        preferences.add(.init(path: root.path)); preferences.enabled = true
        let restored = AIFileToolPreferences(store: store)
        precondition(restored.enabled && restored.scopes == preferences.scopes)
        let note = root.appendingPathComponent("note.txt")
        try Data("synthetic needle".utf8).write(to: note)
        try Data("protected fixture".utf8).write(to: root.appendingPathComponent(".env"))
        precondition(!registrations().contains { $0.definition.name == "keylane_edit_file" })
        var approvals: [String] = [], events: [AIResponseEvent] = []
        var allow = false
        var onApproval: (() -> Void)?
        let recipient = AIToolRecipient(destination: "https://actual-proxy.fixture.test/v1/chat/completions", model: "synthetic-model")
        func run(_ tools: [AIToolRegistration]? = nil, recipient: AIToolRecipient? = recipient) throws -> AIToolRun {
            try AIToolRun(registrations: tools ?? registrations(), recipient: recipient, isCurrent: { true }) { _, text in
                approvals.append(text); onApproval?(); return allow
            }
        }
        func execute(_ run: AIToolRun, _ name: String, _ arguments: [String: AIToolValue]) async throws -> AIToolResult {
            try await run.execute(AIToolCall(id: UUID().uuidString, name: "keylane_" + name, arguments: arguments), scope: "fixture", progress: { event in await MainActor.run { events.append(event) } })
        }
        let deniedOperations: [(String, [String: AIToolValue])] = [
            ("file_roots", [:]), ("read_file", ["path": .string("note.txt")]),
            ("file_info", ["path": .string("note.txt")]),
            ("glob", ["path": .string("."), "pattern": .string("**/*")]),
            ("grep", ["path": .string("."), "pattern": .string("**/*"), "query": .string("needle")]),
            ("write_file", ["path": .string("created.txt"), "content": .string("approved fixture")]),
            ("create_directory", ["path": .string("folder")])
        ]
        var deniedResults: [String] = []
        for (name, arguments) in deniedOperations {
            let before = approvals.count
            let result = try await execute(run(), name, arguments)
            precondition(result.isError && approvals.count == before + 1)
            deniedResults.append(result.text)
            precondition(!result.text.contains("synthetic needle") && !result.text.contains(root.path))
            precondition(approvals.last!.contains(recipient.destination) && approvals.last!.contains(recipient.model))
        }
        precondition(!FileManager.default.fileExists(atPath: root.path + "/created.txt"))
        precondition(!FileManager.default.fileExists(atPath: root.path + "/folder"))
        print("PASS file tools: names, metadata, listing, search and writes all require recipient-bound approval")

        allow = true
        let read = try await execute(run(), "read_file", ["path": .string(root.path + "/unused/../note.txt")])
        precondition(!read.isError && read.text.contains("synthetic needle") && !read.text.contains(root.path))
        precondition(approvals.last!.contains(note.path))
        for (name, arguments) in deniedOperations.prefix(5) {
            let result = try await execute(run(), name, arguments)
            precondition(!result.isError && !result.text.contains(root.path) && !result.text.contains(".env"))
        }
        var preparationFailures: [String] = []
        for tool in ["read_file", "file_info", "glob", "grep"] {
            let before = approvals.count
            var args: [String: AIToolValue] = ["path": .string("safe/../.env")]
            if tool == "glob" || tool == "grep" { args["pattern"] = .string("**/*") }
            if tool == "grep" { args["query"] = .string("fixture") }
            let protected = try await execute(run(), tool, args)
            precondition(protected.isError && approvals.count == before && !protected.text.contains("protected fixture"))
            preparationFailures.append(protected.text)
        }
        let missingRecipient = try await execute(run(recipient: nil), "read_file", ["path": .string("note.txt")])
        precondition(missingRecipient.isError && !missingRecipient.text.contains("synthetic needle"))
        let nonexistent = try await execute(run(), "read_file", ["path": .string("missing-file")])
        precondition(nonexistent.isError && preparationFailures.allSatisfy { $0 == nonexistent.text } && deniedResults.allSatisfy { $0 == nonexistent.text })
        precondition(!String(describing: events).contains(root.path))
        print("PASS file tools: normalized targets, uniform protected-data policy, relative results/progress, non-oracular preparation errors and fail-closed missing recipient")

        let write: [String: AIToolValue] = ["path": .string("created.txt"), "content": .string("approved fixture")]
        let written = try await execute(run(), "write_file", write)
        let created = try String(contentsOf: root.appendingPathComponent("created.txt"), encoding: .utf8)
        precondition(!written.isError && created == "approved fixture")
        let noOverwrite = try await execute(run(), "write_file", write)
        precondition(noOverwrite.isError && noOverwrite.text == nonexistent.text)
        var replace = write; replace["mode"] = .string("replace")
        let disabledReplace = try await execute(run(), "write_file", replace)
        let disabledEdit = try await execute(run(), "edit_file", ["path": .string("created.txt")])
        precondition(disabledReplace.isError && disabledEdit.isError)
        onApproval = { preferences.remove(root.path); preferences.add(.init(path: root.path)) }
        do {
            _ = try await execute(run(), "write_file", ["path": .string("stale.txt"), "content": .string("must not exist")])
            preconditionFailure("Revoked source did not cancel generation")
        } catch { precondition(error is CancellationError) }
        precondition(!FileManager.default.fileExists(atPath: root.path + "/stale.txt"))
        onApproval = nil
        let frozen = try run()
        preferences.enabled = false; preferences.enabled = true
        let oldRead = try await execute(frozen, "read_file", ["path": .string("note.txt")])
        precondition(oldRead.isError)
        print("PASS file tools: exclusive FD-based creation, disabled overwrite/edit, revoke/re-enable rejects old approvals")

        onApproval = {
            try! FileManager.default.moveItem(at: note, to: root.appendingPathComponent("old-note.txt"))
            try! Data("unapproved replacement".utf8).write(to: note)
        }
        let swapped = try await execute(run(), "read_file", ["path": .string("note.txt")])
        precondition(swapped.isError && !swapped.text.contains("unapproved replacement"))
        onApproval = nil
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        preferences.add(.init(path: parent.path))
        onApproval = {
            try! FileManager.default.moveItem(at: parent, to: root.appendingPathComponent("old-parent"))
            try! FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        let parentSwap = try await execute(run(), "write_file", ["path": .string(parent.path + "/new"), "content": .string("fixture")])
        precondition(parentSwap.isError && !FileManager.default.fileExists(atPath: parent.path + "/new") && !FileManager.default.fileExists(atPath: root.path + "/old-parent/new"))
        onApproval = nil
        print("PASS file tools: target and parent replacement during approval cannot redirect the prepared operation")

        let projectRoot = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)
        try Data("project default".utf8).write(to: projectRoot.appendingPathComponent("note.txt"))
        project = AIChatProject(name: "fixture", directory: projectRoot)
        let projectRead = try await execute(run(), "read_file", ["path": .string("note.txt")])
        precondition(!projectRead.isError && projectRead.text.contains("project default"))
        precondition(approvals.last!.contains(projectRoot.path + "/note.txt"))
        let projectRun = try run(); project = nil
        let switched = try await execute(projectRun, "read_file", ["path": .string("note.txt")])
        precondition(switched.isError)
        var effects = 0
        let sentinel = AIToolRegistration(definition: try .init(name: "fixture_unused", title: "Read metadata", description: "Search only")) { _ in
            effects += 1; return try .init(text: "must not run")
        }
        let discovery = try run([sentinel, AIFileToolProvider.discovery([sentinel])])
        let metadata = try await execute(discovery, "search_tools", ["query": .string("Read")])
        precondition(!metadata.isError && metadata.text.contains("fixture_unused") && effects == 0)
        // Bad unrelated configuration is not resolved while preparing a selected valid root.
        preferences.add(.init(path: root.appendingPathComponent("unrelated").path, bookmark: Data([1, 2, 3])))
        let unrelated = try await execute(run(), "read_file", ["path": .string("created.txt")])
        precondition(!unrelated.isError)
        print("PASS file tools: project root binding, stale project catalog, pure tool discovery, unrelated bookmark isolation")
        let direct = registrations().first { $0.definition.name == "keylane_read_file" }!
        do {
            _ = try await direct.perform(["path": .string("created.txt")])
            preconditionFailure("File handler bypassed preparation/approval")
        } catch { precondition(error is AIToolContractError) }
        var current = true
        let staleConnection = try AIToolRun(registrations: registrations(), recipient: recipient, isCurrent: { current }) { _, _ in
            current = false; return true
        }
        do {
            _ = try await execute(staleConnection, "read_file", ["path": .string("created.txt")])
            preconditionFailure("Changed run/recipient disclosed a file")
        } catch { precondition(error is CancellationError) }
        var preparedEffects = 0
        let preparedTool = AIToolRegistration(definition: try .init(name: "fixture_prepared", title: "Prepared", description: "Synthetic prepared operation"), prepare: { _, _ in
            AIToolPreparedOperation(displayArguments: "normalized fixture", approvalArguments: "bound review") {
                preparedEffects += 1; return try .init(text: "prepared result")
            }
        }) { _ in preconditionFailure("Prepared operation used raw fallback") }
        allow = false
        let generic = try run([preparedTool])
        let deniedPrepared = try await generic.execute(.init(id: "prepared-denial", name: "fixture_prepared", arguments: [:]), scope: "fixture", progress: { _ in })
        precondition(deniedPrepared.isError && preparedEffects == 0 && approvals.last == "bound review")
        allow = true
        let allowedPrepared = try await generic.execute(.init(id: "prepared-allowed", name: "fixture_prepared", arguments: [:]), scope: "fixture", progress: { _ in })
        precondition(!allowedPrepared.isError && preparedEffects == 1)
        var duringChange: [AIToolRegistration] = []
        let observer = preferences.$scopes.dropFirst().sink { _ in duringChange = registrations() }
        preferences.remove(root.path)
        observer.cancel()
        precondition(!duringChange.isEmpty)
        let publishedCatalog = try run(duringChange)
        let removedScope = try await execute(publishedCatalog, "read_file", ["path": .string(root.path + "/created.txt")])
        precondition(removedScope.isError && !removedScope.text.contains("approved fixture"))
        print("PASS shared preparation: no raw-handler bypass, recipient/run change blocks disclosure, prepared consent and publication-phase scope invalidation")
        // Reset only this fixture's scopes; no real grants or user preferences are used.
        for scope in preferences.scopes { preferences.remove(scope.path) }
        preferences.add(.init(path: root.path)); project = nil; onApproval = nil; allow = true
        try Data(String(repeating: "continuation fixture 中文 ", count: 100).utf8).write(to: root.appendingPathComponent("large.txt"))
        let shared = registrations(), continuedRun = try run(shared)
        let firstPage = try await execute(continuedRun, "read_file", ["path": .string("large.txt"), "limit": .number(64)])
        let firstObject = try JSONDecoder().decode([String: AIToolValue].self, from: Data(firstPage.text.utf8))
        guard case .string(let cursor) = firstObject["cursor"] else { preconditionFailure("No continuation") }
        allow = false
        let declinedPage = try await execute(continuedRun, "read_result", ["cursor": .string(cursor)])
        precondition(declinedPage.isError && !declinedPage.text.contains("continuation fixture"))
        allow = true
        let nextPage = try await execute(continuedRun, "read_result", ["cursor": .string(cursor), "limit": .number(64)])
        precondition(!nextPage.isError && !nextPage.text.contains(root.path))
        let nextObject = try JSONDecoder().decode([String: AIToolValue].self, from: Data(nextPage.text.utf8))
        guard case .string(let stillLiveCursor) = nextObject["cursor"] else { preconditionFailure("No live continuation") }
        let otherRun = try await execute(run(shared), "read_result", ["cursor": .string(stillLiveCursor)])
        precondition(otherRun.isError)
        let originalRun = try await execute(continuedRun, "read_result", ["cursor": .string(stillLiveCursor), "limit": .number(64)])
        precondition(!originalRun.isError)
        print("PASS read continuation: per-page consent, private references, no pathname disclosure or cross-run registration reuse")

        let indexState = IndexFixtureState()
        for i in 0..<3 { try Data("indexed fixture".utf8).write(to: root.appendingPathComponent("indexed-\(i).txt")) }
        let index = AIFileToolIndexSource(isCurrent: { indexState.revision == 0 }, search: { query, directory in
            indexState.searches += 1
            precondition(query == "indexed" && directory == root.path)
            return (0..<3).map { root.path + "/indexed-\($0).txt" } + ["/outside/synthetic", root.path + "/.env"]
        })
        _ = registrations(index: index).map(\.definition)
        precondition(indexState.searches == 0)
        allow = false
        let deniedIndex = try await execute(run(registrations(index: index)), "search_indexed_files", ["path": .string("."), "query": .string("indexed"), "limit": .number(1)])
        precondition(deniedIndex.isError && indexState.searches == 0)
        allow = true
        let indexRun = try run(registrations(index: index))
        let indexed = try await execute(indexRun, "search_indexed_files", ["path": .string("."), "query": .string("indexed"), "limit": .number(1)])
        let indexedObject = try JSONDecoder().decode([String: AIToolValue].self, from: Data(indexed.text.utf8))
        guard case .string(let indexCursor) = indexedObject["cursor"] else { preconditionFailure("No index continuation") }
        precondition(!indexed.isError && indexState.searches == 1 && !indexed.text.contains(root.path) && !indexed.text.contains(".env") && !indexed.text.contains("/outside"))
        indexState.revision += 1
        do {
            _ = try await execute(indexRun, "read_result", ["cursor": .string(indexCursor)])
            preconditionFailure("Revoked index source disclosed a cached page")
        } catch { precondition(error is CancellationError) }
        precondition(indexState.searches == 1)
        print("PASS indexed search: pure catalog, no query before consent, matched root filtering and generation-bound cached results")

    }
}
