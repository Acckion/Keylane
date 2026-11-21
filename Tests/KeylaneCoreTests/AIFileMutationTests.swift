import XCTest
import Darwin
@testable import KeylaneCore

final class AIFileMutationTests: XCTestCase {
    private var base: URL!, source: URL!, destination: URL!, vault: URL!, trash: URL!
    private var service: AIFileToolService!
    private var configuration: AIFileToolService.MutationConfiguration!
    private var scopes: [AIFileToolScope] { [.init(path: source.path), .init(path: destination.path)] }
    override func setUpWithError() throws {
        base = URL(fileURLWithPath: AIFileToolService.systemPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("KeylaneMutation-" + UUID().uuidString)
        source = base.appendingPathComponent("source"); destination = base.appendingPathComponent("destination")
        vault = base.appendingPathComponent(".keylane-ai-recovery"); trash = base.appendingPathComponent("SyntheticTrash")
        for url in [source!, destination!, trash!] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var config = AIFileToolService.MutationConfiguration.live
        config.recoveryDirectory = vault
        let ownedTrash = trash!
        config.trash = { url in
            let moved = ownedTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: moved); return moved
        }
        configuration = config; service = AIFileToolService(mutations: config)
    }
    override func tearDownWithError() throws { if let base { try FileManager.default.removeItem(at: base) } }
    private func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: source.appendingPathComponent(name)) }
    private func content(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func object(_ result: AIToolResult) throws -> [String: AIToolValue] { try JSONDecoder().decode([String: AIToolValue].self, from: Data(result.text.utf8)) }
    private func value(_ value: AIToolValue?) throws -> String { guard case .string(let value) = value else { throw AIFileToolError.invalidText }; return value }
    private func call(_ tool: String, _ arguments: [String: AIToolValue], using other: AIFileToolService? = nil, lease: AIFileAccessLease = .init()) async throws -> AIToolResult {
        let service = other ?? self.service!
        let plan = try await service.prepare("keylane_" + tool, arguments: arguments, scopes: scopes, lease: lease)
        return try await service.execute(plan, lease: lease, cancellation: .init())
    }
    private func revision(_ name: String, root: String = "root_1") async throws -> AIToolValue {
        let result = try await call("file_info", ["root": .string(root), "path": .string(name)])
        return try XCTUnwrap(object(result)["revision"])
    }
    private func arguments(_ name: String, _ more: [String: AIToolValue] = [:]) async throws -> [String: AIToolValue] {
        var result = more; result["path"] = .string(name); result["expected_revision"] = try await revision(name); return result
    }
    private func succeeded(_ result: AIToolResult, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(result.isError, result.text, file: file, line: line) }
    private func rejects(_ code: AIFileToolError? = nil, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected rejection", file: file, line: line) }
        catch { if let code { XCTAssertEqual(error as? AIFileToolError, code, file: file, line: line) } }
    }
    func testBinaryCopyHasIndependentVersionAndNeverOverwritesDestination() async throws {
        let bytes = Data([0, 255, 1, 2, 3]); try bytes.write(to: source.appendingPathComponent("source.bin"))
        let args = try await arguments("source.bin", ["destination_root": .string("root_2"), "destination_path": .string("copy.bin")])
        let result = try await call("copy_file", args)
        XCTAssertFalse(result.isError); XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("copy.bin")), bytes)
        XCTAssertFalse(result.text.contains(base.path))
        await rejects(.exists) { _ = try await self.call("copy_file", args) }
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("source.bin")), bytes)
    }
    func testExactEditAndWholeReplacementPreserveRecoverableOriginals() async throws {
        try write("note.txt", "before 中文 before")
        let args = try await arguments("note.txt", ["old_text": .string("before"), "new_text": .string("after"), "occurrences": .number(2)])
        let edited = try await call("edit_file", args)
        XCTAssertFalse(edited.isError); XCTAssertEqual(try content(source.appendingPathComponent("note.txt")), "after 中文 after")
        let id = try value(object(edited)["recovery_id"])
        let restarted = AIFileToolService(mutations: configuration)
        let restored = try await call("restore_file", ["recovery_id": .string(id), "destination_path": .string("old.txt")], using: restarted)
        XCTAssertFalse(restored.isError); XCTAssertEqual(try content(source.appendingPathComponent("old.txt")), "before 中文 before")
        let replace = try await arguments("note.txt", ["content": .string("completely new")])
        succeeded(try await call("replace_file", replace))
        XCTAssertEqual(try content(source.appendingPathComponent("note.txt")), "completely new")
    }
    func testRestoreCanExplicitlyReplaceEditedOriginalAndKeepCurrentVersion() async throws {
        try write("note", "original")
        let edited = try await call("replace_file", arguments("note", ["content": .string("new")]))
        let id = try value(object(edited)["recovery_id"])
        await rejects(.exists) { _ = try await self.call("restore_file", ["recovery_id": .string(id)]) }
        let current = try await revision("note")
        let restored = try await call("restore_file", ["recovery_id": .string(id), "replace_edited_file": .bool(true), "expected_revision": current])
        XCTAssertFalse(restored.isError); XCTAssertEqual(try content(source.appendingPathComponent("note")), "original")
        let undo = try value(object(restored)["recovery_id"])
        let preserved = try await call("restore_file", ["recovery_id": .string(undo), "destination_path": .string("preserved-new")])
        XCTAssertFalse(preserved.isError); XCTAssertEqual(try content(source.appendingPathComponent("preserved-new")), "new")
    }
    func testEditMismatchAndMissingReplacementCannotMutateOriginal() async throws {
        try write("note", "same same")
        await rejects(.editMismatch) { _ = try await self.call("edit_file", self.arguments("note", ["old_text": .string("same"), "new_text": .string("changed")])) }
        await rejects(.invalidText) { _ = try await self.call("edit_file", self.arguments("note", ["old_text": .string("same")])) }
        await rejects(.tooLarge) { _ = try await self.call("replace_file", self.arguments("note")) }
        XCTAssertEqual(try content(source.appendingPathComponent("note")), "same same")
    }
    func testMoveAndRenameUseExclusiveDestinationAndCanBeRestored() async throws {
        try write("file", "move me")
        let args = try await arguments("file", ["destination_root": .string("root_2"), "destination_path": .string("renamed")])
        let moved = try await call("move_file", args)
        XCTAssertFalse(moved.isError); XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("file").path))
        XCTAssertEqual(try content(destination.appendingPathComponent("renamed")), "move me")
        let id = try value(object(moved)["recovery_id"])
        succeeded(try await call("restore_file", ["recovery_id": .string(id)]))
        XCTAssertEqual(try content(source.appendingPathComponent("file")), "move me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("renamed").path))
    }
    func testTrashAndRestoreUseOwnedSyntheticTrashNotSystemTrash() async throws {
        try write("file", "trash fixture")
        let trashed = try await call("trash_file", arguments("file"))
        XCTAssertFalse(trashed.isError); XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("file").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
        let restarted = AIFileToolService(mutations: configuration)
        let id = try value(object(trashed)["recovery_id"])
        succeeded(try await call("restore_file", ["recovery_id": .string(id)], using: restarted))
        XCTAssertEqual(try content(source.appendingPathComponent("file")), "trash fixture")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
    }
    func testVersionChangeAndRevocationBeforeCommitRefuseWrites() async throws {
        try write("file", "old")
        let lease = AIFileAccessLease(), args = try await arguments("file", ["content": .string("new")])
        let plan = try await service.prepare("keylane_replace_file", arguments: args, scopes: scopes, lease: lease)
        try write("file", "external edit")
        await rejects(.stale) { _ = try await self.service.execute(plan, lease: lease, cancellation: .init()) }
        XCTAssertEqual(try content(source.appendingPathComponent("file")), "external edit")
        let revokedLease = AIFileAccessLease(), revoked = AIFileToolService(mutations: configuration, beforeCommit: { revokedLease.revoke() })
        await rejects { _ = try await self.call("replace_file", self.arguments("file", ["content": .string("new")]), using: revoked, lease: revokedLease) }
        XCTAssertEqual(try content(source.appendingPathComponent("file")), "external edit")
    }
    func testLeafOnlyAndSensitiveStoragePolicyPreserveOldCreationRules() async throws {
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try write("nested/file", "body")
        await rejects(.creationScope) { _ = try await self.call("move_file", self.arguments("nested/file", ["destination_path": .string("new")])) }
        XCTAssertTrue(AIFileToolService.isRecoveryStorage(vault.path + "/receipt.json"))
        XCTAssertTrue(AIFileToolService.isSensitive(vault.path + "/receipt.json"))
        await rejects(.restricted) { _ = try await self.service.prepare("keylane_read_file", arguments: ["path": .string(self.vault.path)], scopes: [.init(path: self.base.path)], lease: .init()) }
        await rejects(.unsupported) { _ = try await self.call("write_file", ["path": .string("new"), "mode": .string("replace"), "content": .string("still disabled")]) }
    }
    func testDestinationAppearingAtFinalCopySyscallIsNotOverwritten() async throws {
        try write("file", "source body")
        let target = destination.appendingPathComponent("target"), native = AIFileToolService.CreationSyscalls.live
        let syscalls = AIFileToolService.CreationSyscalls(cloneFile: { from, parent, name in
            if name == "target" { try! Data("other writer".utf8).write(to: target) }
            return native.cloneFile(from, parent, name)
        }, createDirectory: native.createDirectory)
        let racing = AIFileToolService(mutations: configuration, creationSyscalls: syscalls)
        await rejects(.exists) { _ = try await self.call("copy_file", self.arguments("file", ["destination_root": .string("root_2"), "destination_path": .string("target")]), using: racing) }
        XCTAssertEqual(try content(target), "other writer"); XCTAssertEqual(try content(source.appendingPathComponent("file")), "source body")
    }
    func testLateTargetSwapPreservesForeignObjectButRecoveryOnlyExportsApprovedBackup() async throws {
        try write("file", "approved body")
        let file = source.appendingPathComponent("file"), moved = source.appendingPathComponent("moved-original"), native = configuration.rename
        var config = configuration!
        config.rename = { from, name, to, target, flags in
            if flags == UInt32(RENAME_SWAP) {
                try! FileManager.default.moveItem(at: file, to: moved)
                try! Data("foreign body".utf8).write(to: file)
            }
            return native(from, name, to, target, flags)
        }
        let racing = AIFileToolService(mutations: config)
        let output = try await call("replace_file", arguments("file", ["content": .string("new body")]), using: racing)
        XCTAssertTrue(output.isError); XCTAssertFalse(output.text.contains("foreign body")); XCTAssertFalse(output.text.contains(base.path))
        XCTAssertEqual(try content(file), "new body"); XCTAssertEqual(try content(moved), "approved body")
        let id = try value(object(output)["recovery_id"])
        succeeded(try await call("restore_file", ["recovery_id": .string(id), "destination_path": .string("recovered")]))
        XCTAssertEqual(try content(source.appendingPathComponent("recovered")), "approved body")
        let privateBodies = try FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil).filter { $0.pathExtension == "payload" }
        XCTAssertTrue(try privateBodies.map(content).contains("foreign body")) // preserved, never exported by recovery
    }
    func testPostCommitRevocationReturnsUncertainAndRestartCanRecover() async throws {
        try write("file", "old body")
        let lease = AIFileAccessLease()
        var config = configuration!; config.afterEffect = { lease.revoke() }
        let cancelling = AIFileToolService(mutations: config)
        let output = try await call("replace_file", arguments("file", ["content": .string("new body")]), using: cancelling, lease: lease)
        XCTAssertTrue(output.isError); XCTAssertEqual(try content(source.appendingPathComponent("file")), "new body")
        let id = try value(object(output)["recovery_id"]), restarted = AIFileToolService(mutations: configuration)
        succeeded(try await call("restore_file", ["recovery_id": .string(id), "destination_path": .string("recovered")], using: restarted))
        XCTAssertEqual(try content(source.appendingPathComponent("recovered")), "old body")
    }
    func testUnsupportedSwapDoesNotFallbackAndLeavesOriginalUntouched() async throws {
        try write("file", "old")
        var config = configuration!; config.rename = { _, _, _, _, _ in .init(code: -1, error: ENOTSUP) }
        await rejects(.mutationUnsupported) { _ = try await self.call("replace_file", self.arguments("file", ["content": .string("new")]), using: AIFileToolService(mutations: config)) }
        XCTAssertEqual(try content(source.appendingPathComponent("file")), "old")
    }
    func testRestoreRefusesReplacedRecoveryPayloadAndChangedTargetRevision() async throws {
        try write("file", "old")
        let edited = try await call("replace_file", arguments("file", ["content": .string("new")]))
        let id = try value(object(edited)["recovery_id"]), oldRevision = try await revision("file")
        try write("file", "outside edit")
        await rejects(.stale) { _ = try await self.call("restore_file", ["recovery_id": .string(id), "replace_edited_file": .bool(true), "expected_revision": oldRevision]) }
        let metadata = try JSONDecoder().decode(AIFileRecoveryRecord.self, from: Data(contentsOf: vault.appendingPathComponent(id + ".json")))
        let payload = vault.appendingPathComponent(try XCTUnwrap(metadata.payload))
        try FileManager.default.moveItem(at: payload, to: vault.appendingPathComponent("saved-aside"))
        try Data("untrusted replacement".utf8).write(to: payload)
        await rejects(.stale) { _ = try await self.call("restore_file", ["recovery_id": .string(id), "destination_path": .string("recovered")]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("recovered").path))
    }
    func testRecoveryMetadataCannotSmugglePathsOrSymlinkedStorage() async throws {
        try write("file", "old")
        let edited = try await call("replace_file", arguments("file", ["content": .string("new")]))
        let id = try value(object(edited)["recovery_id"]), url = vault.appendingPathComponent(id + ".json")
        let bytes = try Data(contentsOf: url)
        var data = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        data["originalName"] = "../../escape"
        try JSONSerialization.data(withJSONObject: data).write(to: url)
        await rejects(.restricted) { _ = try await self.call("restore_file", ["recovery_id": .string(id), "destination_path": .string("recovered")]) }
        let other = base.appendingPathComponent("other")
        try FileManager.default.moveItem(at: vault, to: other)
        try FileManager.default.createSymbolicLink(at: vault, withDestinationURL: other)
        await rejects { _ = try await self.call("file_recovery", [:]) }
    }

    func testBackupFailureAfterSuccessfulSwapIsUncertainNotUncommitted() async throws {
        try write("file", "original")
        let native = AIFileToolService.CreationSyscalls.live
        let failing = AIFileToolService.CreationSyscalls(cloneFile: { source, parent, name in
            if name.hasSuffix(".displaced") { return .init(code: -1, error: ENOTSUP) }
            return native.cloneFile(source, parent, name)
        }, createDirectory: native.createDirectory)
        let result = try await call("replace_file", arguments("file", ["content": .string("new")]), using: AIFileToolService(mutations: configuration, creationSyscalls: failing))
        XCTAssertTrue(result.isError); XCTAssertEqual(try content(source.appendingPathComponent("file")), "new")
        let id = try value(object(result)["recovery_id"])
        let record = try JSONDecoder().decode(AIFileRecoveryRecord.self, from: Data(contentsOf: vault.appendingPathComponent(id + ".json")))
        XCTAssertEqual(record.phase, "unconfirmed")
        succeeded(try await call("restore_file", ["recovery_id": .string(id), "destination_path": .string("recovered")]))
        XCTAssertEqual(try content(source.appendingPathComponent("recovered")), "original")
    }
    func testTwoPreparedRestoresCannotConsumeSameRecordAfterFirstSucceeds() async throws {
        try write("file", "original")
        let edit = try await call("replace_file", arguments("file", ["content": .string("new")]))
        let id = try value(object(edit)["recovery_id"]), firstLease = AIFileAccessLease(), secondLease = AIFileAccessLease()
        let first = try await service.prepare("keylane_restore_file", arguments: ["recovery_id": .string(id), "destination_path": .string("first")], scopes: scopes, lease: firstLease)
        let second = try await service.prepare("keylane_restore_file", arguments: ["recovery_id": .string(id), "destination_path": .string("second")], scopes: scopes, lease: secondLease)
        succeeded(try await service.execute(first, lease: firstLease, cancellation: .init()))
        await rejects(.stale) { _ = try await self.service.execute(second, lease: secondLease, cancellation: .init()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("second").path))
    }
    func testRecoveryToEmptyNameStillWorksAtActiveRecordLimit() async throws {
        try write("file", "original")
        let edit = try await call("replace_file", arguments("file", ["content": .string("new")]))
        let id = try value(object(edit)["recovery_id"])
        let real = try JSONDecoder().decode(AIFileRecoveryRecord.self, from: Data(contentsOf: vault.appendingPathComponent(id + ".json")))
        for _ in 0..<63 {
            let token = UUID().uuidString
            let record = AIFileRecoveryRecord(id: token, operation: "keylane_replace_file", created: Date(), originalRoot: real.originalRoot,
                originalRootIdentity: real.originalRootIdentity, originalName: "synthetic-quota", originalIdentity: "synthetic", payload: token + ".payload", phase: "completed")
            let url = vault.appendingPathComponent(token + ".json")
            try JSONEncoder().encode(record).write(to: url); XCTAssertEqual(chmod(url.path, 0o600), 0)
        }
        await rejects(.tooLarge) { _ = try await self.call("replace_file", self.arguments("file", ["content": .string("again")])) }
        succeeded(try await call("restore_file", ["recovery_id": .string(id), "destination_path": .string("recovered")]))
        XCTAssertEqual(try content(source.appendingPathComponent("recovered")), "original")
    }
    func testRootRelocationAfterCommitDoesNotTouchReplacementDirectory() async throws {
        try write("file", "original")
        let originalPath = source!, movedPath = base.appendingPathComponent("moved-root")
        var config = configuration!
        config.afterEffect = {
            try FileManager.default.moveItem(at: originalPath, to: movedPath)
            try FileManager.default.createDirectory(at: originalPath, withIntermediateDirectories: false)
            try Data("replacement directory".utf8).write(to: originalPath.appendingPathComponent("file"))
        }
        let output = try await call("replace_file", arguments("file", ["content": .string("new")]), using: AIFileToolService(mutations: config))
        XCTAssertTrue(output.isError)
        XCTAssertEqual(try content(originalPath.appendingPathComponent("file")), "replacement directory")
        XCTAssertEqual(try content(movedPath.appendingPathComponent("file")), "new")
    }

    func testTextMutationRejectsStructuredDocumentsEvenWhenBytesAreUTF8() async throws {
        for name in ["fake.pdf", "fake.docx", "fake.rtf"] {
            try write(name, "%PDF-1.7 synthetic ASCII container")
            await rejects(.unsupported) { _ = try await self.call("replace_file", self.arguments(name, ["content": .string("plain text")])) }
            await rejects(.unsupported) { _ = try await self.call("edit_file", self.arguments(name, ["old_text": .string("ASCII"), "new_text": .string("changed")])) }
            XCTAssertEqual(try content(source.appendingPathComponent(name)), "%PDF-1.7 synthetic ASCII container")
        }
    }

    func testTrashSuccessDoesNotRequireOpeningWholeTrashFolder() async throws {
        try write("file", "original")
        let folder = trash!, native = configuration.trash
        defer { _ = chmod(folder.path, 0o700) }
        var config = configuration!
        config.trash = { source in
            let moved = try native(source)
            guard chmod(folder.path, 0o000) == 0 else { throw AIFileToolError.unavailable }
            return moved
        }
        let output = try await call("trash_file", arguments("file"), using: AIFileToolService(mutations: config))
        succeeded(output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("file").path))
        XCTAssertEqual(chmod(folder.path, 0o700), 0)
        let id = try value(object(output)["recovery_id"])
        succeeded(try await call("restore_file", ["recovery_id": .string(id)]))
        XCTAssertEqual(try content(source.appendingPathComponent("file")), "original")
    }

}
