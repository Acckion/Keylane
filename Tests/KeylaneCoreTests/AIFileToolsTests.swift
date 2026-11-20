import XCTest
import Darwin
@testable import KeylaneCore

final class AIFileToolsTests: XCTestCase {
    private var root: URL!
    private var service: AIFileToolService!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: AIFileToolService.systemPath(FileManager.default.temporaryDirectory.path))
            .appendingPathComponent("KeylaneFileTools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = AIFileToolService()
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func file(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func prepare(_ name: String, _ arguments: [String: AIToolValue], lease: AIFileAccessLease = .init()) async throws -> AIFileToolService.Prepared {
        try await service.prepare("keylane_" + name, arguments: arguments, scopes: [.init(path: root.path)], lease: lease)
    }
    private func call(_ name: String, _ arguments: [String: AIToolValue], lease: AIFileAccessLease = .init()) async throws -> [String: AIToolValue] {
        let plan = try await prepare(name, arguments, lease: lease)
        return try decode(await service.execute(plan, lease: lease, cancellation: .init()))
    }
    private func decode(_ result: AIToolResult) throws -> [String: AIToolValue] { try JSONDecoder().decode([String: AIToolValue].self, from: Data(result.text.utf8)) }
    private func text(_ value: AIToolValue?) -> String { if case .string(let text) = value { return text }; return "" }
    private func rows(_ value: AIToolValue?) -> [[String: AIToolValue]] {
        if case .array(let rows) = value { return rows.compactMap { if case .object(let object) = $0 { return object }; return nil } }; return []
    }
    private func rejects(_ expected: AIFileToolError? = nil, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected refusal", file: file, line: line) }
        catch { if let expected { XCTAssertEqual(error as? AIFileToolError, expected, file: file, line: line) } }
    }
    func testDirectoryPagingOnlyDisclosesRelativePaths() async throws {
        try file("z.txt", "not returned"); try file("a.txt", "not returned"); try file(".hidden", "not returned")
        let first = try await call("read_file", ["path": .string(root.path), "limit": .number(1)])
        XCTAssertEqual(rows(first["entries"]).map { text($0["path"]) }, ["a.txt"])
        XCTAssertEqual(first["next_offset"], .number(1)); XCTAssertEqual(first["root"], .string("root_1"))
        let second = try await call("read_file", ["path": .string("."), "limit": .number(1), "offset": .number(1)])
        XCTAssertEqual(rows(second["entries"]).map { text($0["path"]) }, ["z.txt"])
        XCTAssertEqual(second["next_offset"], .null)
        XCTAssertFalse(String(describing: first).contains(root.path))
        XCTAssertFalse(String(describing: first).contains("not returned"))
    }
    func testUTF8PagingLargeFilesAndBinaryRefusal() async throws {
        let expected = "你好👋\nmore 中文"
        try file("utf8", expected)
        var offset = 0, result = ""
        while true {
            let part = try await call("read_file", ["path": .string("utf8"), "offset": .number(Double(offset)), "limit": .number(7)])
            result += text(part["text"])
            guard case .number(let next) = part["next_offset"] else { break }
            XCTAssertGreaterThan(Int(next), offset); offset = Int(next)
        }
        XCTAssertEqual(result, expected)
        await rejects(.invalidText) { _ = try await self.call("read_file", ["path": .string("utf8"), "offset": .number(1)]) }
        try Data([0, 1, 255]).write(to: root.appendingPathComponent("binary"))
        await rejects(.invalidText) { _ = try await self.call("read_file", ["path": .string("binary")]) }
        try file("large", String(repeating: "a", count: 100_000))
        let large = try await call("read_file", ["path": .string("large")])
        XCTAssertEqual(text(large["text"]).utf8.count, 4096); XCTAssertEqual(large["next_offset"], .number(4096))
    }
    func testGrepRecognizesCRLFAndMixedNewlineBoundaries() async throws {
        // The match is beyond the first excerpt; treating the file as one line hides it.
        let before = (1...12).map { "unmatched line \($0) " + String(repeating: "x", count: 30) }
        try file("windows.txt", (before + ["Needle on line thirteen", "tail"]).joined(separator: "\r\n"))
        try file("mixed.txt", "first\r\nsecond\nthird\rNeedle on line four\r\nNeedle on final line")
        let result = try await call("grep", ["path": .string("."), "pattern": .string("**/*"), "query": .string("needle")])
        let matches = rows(result["matches"])
        let windows = matches.filter { text($0["path"]) == "windows.txt" }
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?["line"], .number(13))
        XCTAssertEqual(text(windows.first?["text"]), "Needle on line thirteen")
        let mixed = matches.filter { text($0["path"]) == "mixed.txt" }
        XCTAssertEqual(mixed.map { $0["line"] }, [.number(4), .number(5)])
        XCTAssertEqual(mixed.map { text($0["text"]) }, ["Needle on line four", "Needle on final line"])
    }

    func testGlobAndGrepUseTheSameProtectedDataPolicy() async throws {
        try file("nested/deep/code.swift", "FIRST\nNeedle here\nlast")
        try file("z.swift", "needle second"); try file(".private.swift", "needle")
        try file(".env", "needle credential"); try file("nested/.env.local", "needle credential")
        try file(".ssh/config", "needle credential"); try file(".config/secret", "needle credential")
        let glob = try await call("glob", ["path": .string("."), "pattern": .string("**/*"), "include_hidden": .bool(true)])
        let paths = rows(glob["matches"]).map { text($0["path"]) }
        XCTAssertTrue(paths.contains("nested/deep/code.swift")); XCTAssertTrue(paths.contains(".private.swift"))
        XCTAssertFalse(paths.contains { $0.contains(".env") || $0.contains(".ssh") || $0.contains(".config") })
        let grep = try await call("grep", ["path": .string("."), "pattern": .string("**/*"), "query": .string("NEEDLE")])
        XCTAssertEqual(rows(grep["matches"]).count, 2)
        XCTAssertFalse(String(describing: grep).contains(root.path))
        let shallow = try await call("glob", ["path": .string("."), "pattern": .string("**/*.swift"), "depth": .number(1)])
        XCTAssertEqual(rows(shallow["matches"]).map { text($0["path"]) }, ["z.swift"])
        XCTAssertEqual(shallow["truncated"], .bool(true))
    }
    func testProtectedPathsCannotDiscloseMetadataOrAppearInListings() async throws {
        try file(".env", "secret"); try file("ordinary", "normal")
        for tool in ["read_file", "file_info", "glob", "grep", "write_file", "create_directory"] {
            await rejects(.restricted) { _ = try await self.prepare(tool, ["path": .string("safe/../.env")]) }
        }
        let list = try await call("read_file", ["path": .string("."), "include_hidden": .bool(true)])
        XCTAssertEqual(rows(list["entries"]).map { text($0["path"]) }, ["ordinary"])
        await rejects(.restricted) {
            _ = try await self.service.prepare("keylane_file_roots", arguments: [:], scopes: [.init(path: self.root.path + "/.ssh")], lease: .init())
        }
    }
    func testLongestMatchingScopeAndRootHandlesNeverExposeLocalPaths() async throws {
        try file("nested/note", "fixture")
        let lease = AIFileAccessLease(), scopes = [AIFileToolScope(path: root.path), .init(path: root.path + "/nested")]
        let plan = try await service.prepare("keylane_read_file", arguments: ["path": .string("nested/note")], scopes: scopes, lease: lease)
        XCTAssertEqual(plan.rootID, "root_2"); XCTAssertEqual(plan.relativePath, "note")
        XCTAssertEqual(plan.localRoot, root.path + "/nested")
        let output = try await service.execute(plan, lease: lease, cancellation: .init())
        XCTAssertFalse(output.text.contains(root.path)); XCTAssertTrue(output.text.contains("root_2"))
        let roots = try await service.prepare("keylane_file_roots", arguments: [:], scopes: scopes, lease: lease)
        let metadata = try await service.execute(roots, lease: lease, cancellation: .init())
        XCTAssertFalse(metadata.text.contains(root.path)); XCTAssertFalse(metadata.text.contains("nested"))
        await rejects(.outsideScope) {
            _ = try await self.service.prepare("keylane_read_file", arguments: ["root": .string("root_2"), "path": .string("../ordinary")], scopes: scopes, lease: lease)
        }
    }
    func testSymlinkAndHardlinkDisclosureAreRefused() async throws {
        try file("outside/secret", "outside")
        let scope = root.appendingPathComponent("scope")
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: scope.appendingPathComponent("escape"), withDestinationURL: root.appendingPathComponent("outside"))
        try FileManager.default.linkItem(at: root.appendingPathComponent("outside/secret"), to: scope.appendingPathComponent("alias"))
        for path in ["escape/secret", "alias", "../outside/secret"] {
            await rejects { _ = try await self.service.prepare("keylane_read_file", arguments: ["path": .string(path)], scopes: [.init(path: scope.path)], lease: .init()) }
        }
    }
    func testTargetSwapAfterPreparationFailsClosed() async throws {
        try file("target", "approved old object")
        let lease = AIFileAccessLease()
        let plan = try await prepare("read_file", ["path": .string("target")], lease: lease)
        try FileManager.default.moveItem(at: root.appendingPathComponent("target"), to: root.appendingPathComponent("old"))
        try file("target", "unapproved new object")
        await rejects { _ = try await self.service.execute(plan, lease: lease, cancellation: .init()) }
        // Updating bytes of the same object during approval must also invalidate its read snapshot.
        let changed = try await prepare("read_file", ["path": .string("target")], lease: lease)
        try file("target", "changed in place")
        await rejects(.stale) { _ = try await self.service.execute(changed, lease: lease, cancellation: .init()) }
    }
    func testParentSwapCannotRedirectAnApprovedCreation() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("parent"), withIntermediateDirectories: false)
        let lease = AIFileAccessLease()
        let plan = try await service.prepare("keylane_write_file", arguments: ["path": .string("new"), "content": .string("approved")], scopes: [.init(path: root.path + "/parent")], lease: lease)
        try FileManager.default.moveItem(at: root.appendingPathComponent("parent"), to: root.appendingPathComponent("old-parent"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("parent"), withIntermediateDirectories: false)
        await rejects { _ = try await self.service.execute(plan, lease: lease, cancellation: .init()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/parent/new"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/old-parent/new"))
    }
    func testRootSwapCannotRedirectAnApprovedRead() async throws {
        try file("scoped/note", "old")
        let lease = AIFileAccessLease()
        let plan = try await service.prepare("keylane_read_file", arguments: ["path": .string("note")], scopes: [.init(path: root.path + "/scoped")], lease: lease)
        try FileManager.default.moveItem(at: root.appendingPathComponent("scoped"), to: root.appendingPathComponent("moved"))
        try file("scoped/note", "new")
        await rejects { _ = try await self.service.execute(plan, lease: lease, cancellation: .init()) }
    }
    func testOnlyExclusiveCreationIsSupported() async throws {
        let result = try await call("write_file", ["path": .string("new"), "content": .string("first")])
        XCTAssertEqual(result["written"], .bool(true)); XCTAssertEqual(result["path"], .string("new"))
        await rejects(.exists) { _ = try await self.call("write_file", ["path": .string("new"), "content": .string("overwrite")]) }
        await rejects(.unsupported) { _ = try await self.call("write_file", ["path": .string("new"), "mode": .string("replace"), "content": .string("overwrite")]) }
        await rejects(.unsupported) { _ = try await self.call("edit_file", ["path": .string("new")]) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new"), encoding: .utf8), "first")
        _ = try await call("create_directory", ["path": .string("folder")])
        await rejects(.exists) { _ = try await self.call("create_directory", ["path": .string("folder")]) }
    }
    func testCreationCannotUseARelocatableDescendantParent() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        await rejects(.creationScope) { _ = try await self.call("write_file", ["path": .string("nested/new"), "content": .string("blocked")]) }
        await rejects(.creationScope) { _ = try await self.call("create_directory", ["path": .string("nested/new")]) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/nested/new"))
    }
    func testDestinationCreatedDuringApprovalIsNeverOverwritten() async throws {
        let lease = AIFileAccessLease()
        let plan = try await prepare("write_file", ["path": .string("new"), "content": .string("approved")], lease: lease)
        try file("new", "other process")
        await rejects(.exists) { _ = try await self.service.execute(plan, lease: lease, cancellation: .init()) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new"), encoding: .utf8), "other process")
    }
    func testRevocationAndCancellationBeforeCommitLeaveNoFileOrTemporary() async throws {
        for cancellationCase in [false, true] {
            let lease = AIFileAccessLease(), cancellation = AIFileAccessLease()
            let service = AIFileToolService(beforeCommit: { if cancellationCase { cancellation.revoke() } else { lease.revoke() } })
            let plan = try await service.prepare("keylane_write_file", arguments: ["path": .string("blocked"), "content": .string("staged text")], scopes: [.init(path: root.path)], lease: lease)
            await rejects { _ = try await service.execute(plan, lease: lease, cancellation: cancellation) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/blocked"))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".keylane-ai-") })
        }
    }
    func testPreparedOperationsCannotBeReplayed() async throws {
        try file("note", "fixture")
        let lease = AIFileAccessLease()
        let plan = try await prepare("read_file", ["path": .string("note")], lease: lease)
        _ = try await service.execute(plan, lease: lease, cancellation: .init())
        await rejects(.stale) { _ = try await self.service.execute(plan, lease: lease, cancellation: .init()) }
    }
    func testPreparedOperationCannotSubstituteAnUnrevokedLease() async throws {
        let lease = AIFileAccessLease()
        let plan = try await prepare("write_file", ["path": .string("blocked"), "content": .string("fixture")], lease: lease)
        lease.revoke()
        await rejects(.stale) { _ = try await self.service.execute(plan, lease: .init(), cancellation: .init()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/blocked"))
    }
    func testLeaseRevocationSerializesWithCommitSections() throws {
        let lease = AIFileAccessLease(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), revoked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? lease.withValidAccess { entered.signal(); release.wait() }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { lease.revoke(); revoked.signal() }
        XCTAssertEqual(revoked.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(revoked.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try lease.withValidAccess { XCTFail("Post-revocation effect") })
    }
}
