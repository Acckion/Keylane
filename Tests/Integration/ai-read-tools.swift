import AppKit
import Foundation
import KeylaneCore
@testable import Keylane

@MainActor private func verifyReadTools() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("keylane-read-fixture-" + UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = "org.keylane.tests.read-tools." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let clips = root.appendingPathComponent("clipboard")
    let store = try ClipboardStore(directory: clips)
    let id = try store.capture(.text("fixture private text"))
    _ = try store.capture(.files([.init(path: "/synthetic/private-file")]))
    let board = NSPasteboard(name: .init("org.keylane.tests.read-tools." + UUID().uuidString))
    defer { board.releaseGlobally() }
    let clipboard = ClipboardController(directory: clips, board: board, preferences: preferences, startTimer: false, presentationActive: false)
    defer { clipboard.stopRuntime() }
    var approvals: [String] = []
    var allowed = true
    func run(_ registrations: [AIToolRegistration]) throws -> AIToolRun {
        try .init(registrations: registrations.map { $0.forRun() }, isCurrent: { true }, approve: { _, detail in
            approvals.append(detail); return allowed
        })
    }
    func execute(_ tools: AIToolRun, _ name: String, _ arguments: [String: AIToolValue]) async throws -> AIToolResult {
        try await tools.execute(.init(id: UUID().uuidString, name: name, arguments: arguments), scope: "fixture", progress: { _ in })
    }
    func rows(_ result: AIToolResult, _ key: String) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as! [String: Any]
        return object[key] as! [[String: Any]]
    }
    let clipboardRun = try run(AIReadTools.clipboard(clipboard))
    allowed = false
    let denied = try await execute(clipboardRun, "keylane_search_clipboard", ["query": .string("fixture")])
    precondition(denied.isError && !denied.text.contains("private text"))
    allowed = true
    let search = try await execute(clipboardRun, "keylane_search_clipboard", ["query": .string("fixture")])
    let clipboardRows = try rows(search, "untrusted_data")
    precondition(clipboardRows.count == 1 && clipboardRows[0]["preview"] as? String == "fixture private text")
    let clipboardReference = clipboardRows[0]["reference"] as! String
    let read = try await execute(clipboardRun, "keylane_read_clipboard", ["reference": .string(clipboardReference)])
    precondition(!read.isError && read.text.contains("fixture private text"))
    precondition(approvals.last!.contains("fixture private text"))
    precondition(!clipboard.captureEnabled && clipboard.items.isEmpty && clipboard.selectedID == nil)
    let separateClipboardRun = try run(AIReadTools.clipboard(clipboard))
    let approvalsBefore = approvals.count
    let foreign = try await execute(separateClipboardRun, "keylane_read_clipboard", ["reference": .string(clipboardReference)])
    let rawID = try await execute(clipboardRun, "keylane_read_clipboard", ["reference": .string(id)])
    precondition(foreign.isError && rawID.isError && approvals.count == approvalsBefore)
    clipboard.historyCommandEnabled = false; clipboard.historyCommandEnabled = true
    let stale = try await execute(clipboardRun, "keylane_read_clipboard", ["reference": .string(clipboardReference)])
    precondition(stale.isError)
    let freshClipboard = try run(AIReadTools.clipboard(clipboard))
    let freshRows = try rows(await execute(freshClipboard, "keylane_search_clipboard", ["query": .string("fixture")]), "untrusted_data")
    try store.remove(id: id)
    let deleted = try await execute(freshClipboard, "keylane_read_clipboard", ["reference": .string(freshRows[0]["reference"] as! String)])
    precondition(deleted.isError)
    for index in 0..<20 {
        _ = try store.capture(.text("bounded-\(index)-" + String(repeating: "\u{0301}", count: 2000)))
    }
    let bounded = try await execute(freshClipboard, "keylane_search_clipboard", ["query": .string("bounded"), "limit": .number(20)])
    precondition(!bounded.isError)
    let boundedRows = try rows(bounded, "untrusted_data")
    precondition(boundedRows.count == 20 && boundedRows.allSatisfy { ($0["preview"] as! String).utf8.count <= 640 })
    print("PASS clipboard preview budget: 20 long combining-scalar records remain bounded and fit the tool result")
    print("PASS clipboard tools: per-operation consent, text-only, opaque isolated references, capture-off history, unchanged page, off/on revocation, deleted source")

    let scope = root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
    let url = scope.appendingPathComponent("fixture.md")
    try Data("fixture file body".utf8).write(to: url)
    let outside = root.appendingPathComponent("outside.md")
    try Data("outside body must never be read".utf8).write(to: outside)
    let symlink = scope.appendingPathComponent("fixture-link.md")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
    let indexDirectory = root.appendingPathComponent("index")
    let index = try FileSearchIndex(url: indexDirectory.appendingPathComponent("index.sqlite"))
    for file in [url, symlink] {
        try index.put(.init(path: file.path, name: file.lastPathComponent, volume: "/", modified: 1, directory: false, symlink: file == symlink), root: scope.path, epoch: "n:fixture")
    }
    preferences.set([scope.path], forKey: "fileSearchSelectedScopes")
    let files = FileSearchController(directory: indexDirectory, preferences: preferences, defaultOptions: .init(roots: [scope.path]), watchChanges: false)
    defer { files.stopRuntime() }
    let deadline = ContinuousClock.now + .seconds(5)
    while (try? await files.aiSearch("fixture", limit: 1).isEmpty) != false && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    let fileRun = try run(AIReadTools.files(files))
    let fileSearch = try await execute(fileRun, "keylane_search_files", ["query": .string("fixture")])
    let fileRows = try rows(fileSearch, "files")
    let fileReference = fileRows.first { $0["path"] as? String == url.path }!["reference"] as! String
    precondition(fileRows.first { $0["path"] as? String == symlink.path }?["reference"] == nil)
    let fileRead = try await execute(fileRun, "keylane_read_file", ["reference": .string(fileReference)])
    precondition(!fileRead.isError && fileRead.text.contains("fixture file body"))
    precondition(approvals.last!.contains(url.path) && !files.isSearching && files.lastPublishedQuery.isEmpty)
    let arbitrary = try await execute(fileRun, "keylane_read_file", ["reference": .string(outside.path)])
    precondition(arbitrary.isError)
    let otherRun = try run(AIReadTools.files(files))
    let foreignFile = try await execute(otherRun, "keylane_read_file", ["reference": .string(fileReference)])
    precondition(foreignFile.isError)
    allowed = false
    let deniedFile = try await execute(fileRun, "keylane_read_file", ["reference": .string(fileReference)])
    precondition(deniedFile.isError && !deniedFile.text.contains("fixture file body"))
    allowed = true
    try Data("replaced private body".utf8).write(to: url, options: .atomic)
    let replaced = try await execute(fileRun, "keylane_read_file", ["reference": .string(fileReference)])
    precondition(replaced.isError && !replaced.text.contains("replaced private body"))
    files.options.enabled = false; files.options.enabled = true
    let revoked = try await execute(fileRun, "keylane_search_files", ["query": .string("fixture")])
    precondition(revoked.isError)
    print("PASS file tools: indexed authorized scope, descriptor-bound content, path approval, no visible search mutation, arbitrary/foreign references rejected, symlink escape blocked, denial/replacement/off-on rejected")
}

@_cdecl("KeylaneModuleAIFixtureMain")
@MainActor public func readToolFixtureMain() -> Int32 {
    Task { @MainActor in
        do { try await verifyReadTools(); exit(0) }
        catch { fputs("Read tools fixture failed: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run()
    return 1
}
