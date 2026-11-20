import AppKit
import Foundation
import KeylaneCore
@testable import Keylane

@MainActor private final class ReferenceFixtureClock {
    var now = Date()
    var expireOnApproval = false
    var revokeAtConfirmation = false
}

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
        try .init(registrations: registrations.map { $0.forRun() }, recipient: .init(destination: "https://synthetic.invalid/v1", model: "synthetic"), isCurrent: { true }, approve: { _, detail in
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
    do {
        _ = try await execute(clipboardRun, "keylane_read_clipboard", ["reference": .string(clipboardReference)])
        preconditionFailure("Clipboard publication lease survived revocation")
    } catch is CancellationError { }
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

    do {
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
        for indexInBatch in 0..<20 {
            let file = scope.appendingPathComponent("batchref-\(indexInBatch).txt")
            try Data("Synthetic capacity body \(indexInBatch)".utf8).write(to: file)
            try index.put(.init(path: file.path, name: file.lastPathComponent, volume: "/", modified: 1, directory: false, symlink: false), root: scope.path, epoch: "n:fixture")
        }
        let blockedFolder = scope.appendingPathComponent("excluded-fixture")
        try FileManager.default.createDirectory(at: blockedFolder, withIntermediateDirectories: true)
        let blockedFile = blockedFolder.appendingPathComponent("private-indexed.md")
        try Data("Excluded synthetic body".utf8).write(to: blockedFile)
        try index.put(.init(path: blockedFile.path, name: blockedFile.lastPathComponent, volume: "/", modified: 1, directory: false, symlink: false), root: scope.path, epoch: "n:fixture")
        preferences.set([scope.path], forKey: "fileSearchSelectedScopes")
        let files = FileSearchController(directory: indexDirectory, preferences: preferences, defaultOptions: .init(roots: [scope.path]), watchChanges: false)
        defer { files.stopRuntime() }
        files.setIndexPaused(true) // Keep the manually seeded index deterministic across off/on tests.
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? await files.aiSearch("fixture", limit: 1).isEmpty) != false && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await verifyReferenceBatch(AIReadTools.files(files), resultKey: "files", query: "batchref")
        let mixedScope = AIToolRunScope()
        let clipTools = AIReadTools.clipboard(clipboard), fileTools = AIReadTools.files(files)
        var mixedOldReference = ""
        for batch in 0..<3 {
            let result = try await clipTools[0].performInRun!(["query": .string("bounded"), "limit": .number(20)], mixedScope)
            if batch == 0 { mixedOldReference = try rows(result, "untrusted_data")[0]["reference"] as! String }
        }
        let mixedFiles = try rows(await fileTools[0].performInRun!(["query": .string("batchref"), "limit": .number(20)], mixedScope), "files")
        precondition(mixedFiles.count == 20)
        for row in mixedFiles {
            _ = try fileTools[1].confirmationDetail!(["reference": .string(row["reference"] as! String)], mixedScope)
        }
        do {
            _ = try clipTools[1].confirmationDetail!(["reference": .string(mixedOldReference)], mixedScope)
            preconditionFailure("Mixed clipboard/file directory did not share its capacity")
        } catch AIToolContractError.unavailable { }
        print("PASS file/mixed reference capacity: all new batch entries survive eviction across shared clipboard/file scope")
        let fileRun = try run(AIReadTools.files(files))
        let fileSearch = try await execute(fileRun, "keylane_search_files", ["query": .string("fixture")])
        let fileRows = try rows(fileSearch, "files")
        let fileReference = fileRows.first { $0["path"] as? String == url.path }!["reference"] as! String
        precondition(fileRows.first { $0["path"] as? String == symlink.path }?["reference"] == nil)
        let fileRead = try await execute(fileRun, "keylane_read_searched_file", ["reference": .string(fileReference)])
        precondition(!fileRead.isError && fileRead.text.contains("fixture file body"))
        precondition(approvals.last!.contains(url.path) && !files.isSearching && files.lastPublishedQuery.isEmpty)
        let arbitrary = try await execute(fileRun, "keylane_read_searched_file", ["reference": .string(outside.path)])
        precondition(arbitrary.isError)
        let otherRun = try run(AIReadTools.files(files))
        let foreignFile = try await execute(otherRun, "keylane_read_searched_file", ["reference": .string(fileReference)])
        precondition(foreignFile.isError)
        allowed = false
        let deniedFile = try await execute(fileRun, "keylane_read_searched_file", ["reference": .string(fileReference)])
        precondition(deniedFile.isError && !deniedFile.text.contains("fixture file body"))
        allowed = true
        try Data("replaced private body".utf8).write(to: url, options: .atomic)
        let replaced = try await execute(fileRun, "keylane_read_searched_file", ["reference": .string(fileReference)])
        precondition(replaced.isError && !replaced.text.contains("replaced private body"))
        files.options.enabled = false; files.options.enabled = true
        do {
            _ = try await execute(fileRun, "keylane_search_files", ["query": .string("fixture")])
            preconditionFailure("Searched-file publication lease survived off/on")
        } catch is CancellationError { }
        print("PASS file tools: indexed authorized scope, descriptor-bound content, path approval, no visible search mutation, arbitrary/foreign references rejected, symlink escape blocked, denial/replacement/off-on rejected")

        // A reference expires before confirmation, and can also expire while confirmation is pending.
        let fixtureClock = ReferenceFixtureClock()
        let expiringTools = AIReadTools.files(files, now: { fixtureClock.now })
        let expiring = try run(expiringTools)
        let expiringRows = try rows(await execute(expiring, "keylane_search_files", ["query": .string("fixture")]), "files")
        let expiringRef = expiringRows.first { $0["path"] as? String == url.path }!["reference"] as! String
        fixtureClock.now = fixtureClock.now.addingTimeInterval(301)
        let beforeExpiryApproval = approvals.count
        let expired = try await execute(expiring, "keylane_read_searched_file", ["reference": .string(expiringRef)])
        precondition(expired.isError && approvals.count == beforeExpiryApproval)
        let pendingExpiry = try AIToolRun(registrations: expiringTools.map { $0.forRun() },
            recipient: .init(destination: "https://synthetic.invalid/v1", model: "synthetic"),
            isCurrent: { true }, approve: { _, detail in
                approvals.append(detail)
                if fixtureClock.expireOnApproval { fixtureClock.now = fixtureClock.now.addingTimeInterval(301) }
                return true
            })
        let pendingRows = try rows(await execute(pendingExpiry, "keylane_search_files", ["query": .string("fixture")]), "files")
        let pendingRef = pendingRows.first { $0["path"] as? String == url.path }!["reference"] as! String
        fixtureClock.expireOnApproval = true
        let lateApproved = try await execute(pendingExpiry, "keylane_read_searched_file", ["reference": .string(pendingRef)])
        precondition(lateApproved.isError && !lateApproved.text.contains("replaced private body"))
        let beforeExclusion = try run(AIReadTools.files(files))
        let privateRows = try rows(await execute(beforeExclusion, "keylane_search_files", ["query": .string("private-indexed")]), "files")
        precondition(privateRows.count == 1)
        let privateRef = privateRows[0]["reference"] as! String
        files.options.excludedPaths.append(blockedFolder.path)
        let afterExclusion = try run(AIReadTools.files(files))
        let excludedSearch = try await execute(afterExclusion, "keylane_search_files", ["query": .string("private-indexed")])
        let excludedRows = try rows(excludedSearch, "files")
        precondition(!excludedSearch.isError && excludedRows.isEmpty)
        precondition(!excludedSearch.text.contains(blockedFile.lastPathComponent) && !excludedSearch.text.contains(blockedFolder.path))
        let controllerRows = try await files.aiSearch("private-indexed", limit: 20)
        precondition(controllerRows.isEmpty && files.indexPaused)
        do {
            _ = try await execute(beforeExclusion, "keylane_read_searched_file", ["reference": .string(privateRef)])
            preconditionFailure("Excluded search metadata source did not cancel the old run")
        } catch is CancellationError { }
        print("PASS explicit exclusion: paused/stale index exposes no excluded name, path, reference or body; old reference revoked immediately")
        let deletionRun = try run(AIReadTools.files(files))
        let deletionRows = try rows(await execute(deletionRun, "keylane_search_files", ["query": .string("fixture")]), "files")
        let deletedRef = deletionRows.first { $0["path"] as? String == url.path }!["reference"] as! String
        try FileManager.default.removeItem(at: url)
        let deletedFile = try await execute(deletionRun, "keylane_read_searched_file", ["reference": .string(deletedRef)])
        precondition(deletedFile.isError)
        try Data("after-delete body".utf8).write(to: url)
        try index.put(.init(path: url.path, name: url.lastPathComponent, volume: "/", modified: 1, directory: false, symlink: false), root: scope.path, epoch: "n:fixture")
        let revokedDuringApproval = try AIToolRun(registrations: AIReadTools.files(files).map { $0.forRun() },
            recipient: .init(destination: "https://synthetic.invalid/v1", model: "synthetic"),
            isCurrent: { true }, approve: { _, _ in
                if fixtureClock.revokeAtConfirmation { files.options.roots = [] }
                return true
            })
        let scopedRows = try rows(await execute(revokedDuringApproval, "keylane_search_files", ["query": .string("fixture")]), "files")
        let scopedRef = scopedRows.first { $0["path"] as? String == url.path }!["reference"] as! String
        fixtureClock.revokeAtConfirmation = true
        do {
            _ = try await execute(revokedDuringApproval, "keylane_read_searched_file", ["reference": .string(scopedRef)])
            preconditionFailure("Authorization removal during approval did not cancel the run")
        } catch is CancellationError { }
        precondition(approvals.contains { $0.contains("synthetic.invalid") })
        print("PASS searched-file source checks: deletion and authorization removal during confirmation reject the old reference")
        print("PASS searched-file expiry: five-minute lifetime checked before approval and again after pending confirmation; only current run references accepted")
    }

    // Independently authorized path tools coexist with request-scoped search references.
    let folder = root.appendingPathComponent("authorized-path-files")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("Unified synthetic file body".utf8).write(to: folder.appendingPathComponent("fixture.md"))
    let filePreferences = AIFileToolPreferences(store: preferences)
    filePreferences.enabled = true
    filePreferences.add(.init(path: folder.path))
    let fileTools = AIFileToolProvider.registrations(preferences: filePreferences, project: nil, currentProject: { nil })
    let scopedController = FileSearchController(directory: root.appendingPathComponent("unused-index"), preferences: preferences, defaultOptions: .init(roots: []), watchChanges: false, startImmediately: false)
    let combined = AIReadTools.clipboard(clipboard) + AIReadTools.files(scopedController) + fileTools
    _ = try AIToolCatalog(combined.map(\.definition))
    precondition(combined.filter { $0.definition.name == "keylane_read_file" }.count == 1)
    precondition(combined.filter { $0.definition.name == "keylane_read_searched_file" }.count == 1)
    let unified = try AIToolRun(registrations: combined.map { $0.forRun() },
        recipient: .init(destination: "https://synthetic.invalid/v1", model: "synthetic"),
        isCurrent: { true }, approve: { _, detail in approvals.append(detail); return allowed })
    let wrongReference = try await execute(unified, "keylane_read_file", ["reference": .string("not-a-path")])
    let wrongPath = try await execute(unified, "keylane_read_searched_file", ["path": .string("fixture.md")])
    precondition(wrongReference.isError && wrongPath.isError)
    let readArgs: [String: AIToolValue] = ["path": .string("fixture.md")]
    allowed = false
    let deniedFile = try await execute(unified, "keylane_read_file", readArgs)
    precondition(deniedFile.isError && !deniedFile.text.contains("Unified synthetic file body"))
    allowed = true
    let readFile = try await execute(unified, "keylane_read_file", readArgs)
    precondition(!readFile.isError && readFile.text.contains("Unified synthetic file body"))
    precondition(approvals.last!.contains("synthetic.invalid") && approvals.last!.contains("fixture.md"))
    filePreferences.enabled = false; filePreferences.enabled = true
    do {
        _ = try await execute(unified, "keylane_read_file", readArgs)
        preconditionFailure("Revoked prepared source did not cancel its run")
    } catch is CancellationError { }
    print("PASS unified file/clipboard catalog: distinct path/reference schemas, cross-parameter rejection, recipient-aware consent, denial and independent off/on lease revocation")

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
