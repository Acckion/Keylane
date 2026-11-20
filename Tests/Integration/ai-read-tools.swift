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
    // Exercise the module's private reference directory directly: checking 20 references must
    // not relax the production executor's 12-call budget or manufacture confirmations.
    func verifyReferenceBatch(_ registrations: [AIToolRegistration], resultKey: String, query: String) async throws {
        let scope = AIToolRunScope()
        let search = registrations[0], read = registrations[1]
        let args: [String: AIToolValue] = ["query": .string(query), "limit": .number(20)]
        var oldReference = ""
        var finalReferences: [String] = []
        for batch in 0..<4 {
            let result = try await search.performInRun!(args, scope)
            let values = try rows(result, resultKey)
            let refs = values.compactMap { $0["reference"] as? String }
            precondition(refs.count == 20 && Set(refs).count == 20)
            if batch == 0 { oldReference = refs[0] }
            if batch == 3 { finalReferences = refs }
        }
        for reference in finalReferences {
            let detail = try read.confirmationDetail!(["reference": .string(reference)], scope)
            precondition(!detail.isEmpty)
        }
        for reference in [finalReferences.first!, finalReferences.last!] {
            let result = try await read.performInRun!(["reference": .string(reference)], scope)
            precondition(!result.isError && !result.text.isEmpty)
        }
        do {
            _ = try read.confirmationDetail!(["reference": .string(oldReference)], scope)
            preconditionFailure("Old references were not evicted before admitting the next batch")
        } catch AIToolContractError.unavailable { }
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
    try await verifyReferenceBatch(AIReadTools.clipboard(clipboard), resultKey: "untrusted_data", query: "bounded")
    print("PASS clipboard reference capacity: four batches of 20 keep every new reference resolvable; first/last content readable and older batch revoked")
    print("PASS clipboard preview budget: 20 long combining-scalar records remain bounded and fit the tool result")
    print("PASS clipboard tools: per-operation consent, text-only, opaque isolated references, capture-off history, unchanged page, off/on revocation, deleted source")

    // The merged file foundation owns file names, authorization and reads. It must coexist
    // with module clipboard tools without duplicate schemas or a second file permission path.
    let folder = root.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Unified synthetic file body".utf8).write(to: folder.appendingPathComponent("fixture.md"))
    let filePreferences = AIFileToolPreferences(store: preferences)
    filePreferences.enabled = true
    filePreferences.add(.init(path: folder.path))
    let fileTools = AIFileToolProvider.registrations(preferences: filePreferences, project: nil, currentProject: { nil })
    let combined = AIReadTools.clipboard(clipboard) + fileTools
    _ = try AIToolCatalog(combined.map(\.definition))
    precondition(combined.filter { $0.definition.name == "keylane_read_file" }.count == 1)
    precondition(!combined.contains { $0.definition.name == "keylane_search_files" })
    let unified = try AIToolRun(registrations: combined.map { $0.forRun() },
        recipient: .init(destination: "https://synthetic.invalid/v1", model: "synthetic"),
        isCurrent: { true }, approve: { _, detail in approvals.append(detail); return allowed })
    let readArgs: [String: AIToolValue] = ["path": .string("fixture.md")]
    allowed = false
    let deniedFile = try await execute(unified, "keylane_read_file", readArgs)
    precondition(deniedFile.isError && !deniedFile.text.contains("Unified synthetic file body"))
    allowed = true
    let readFile = try await execute(unified, "keylane_read_file", readArgs)
    precondition(!readFile.isError && readFile.text.contains("Unified synthetic file body"))
    precondition(approvals.last!.contains("synthetic.invalid") && approvals.last!.contains("fixture.md"))
    filePreferences.enabled = false; filePreferences.enabled = true
    let revokedFile = try await execute(unified, "keylane_read_file", readArgs)
    precondition(revokedFile.isError && !revokedFile.text.contains("Unified synthetic file body"))
    print("PASS unified file/clipboard catalog: one read schema, recipient-aware consent, denial and off/on lease revocation; no legacy index permission bypass")

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
