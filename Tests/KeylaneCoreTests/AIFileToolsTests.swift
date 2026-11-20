import XCTest
import Darwin
@testable import KeylaneCore

final class AIFileToolsTests: XCTestCase {
    private var root: URL!
    private var service: AIFileToolService!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: AIFileToolService.systemPath(FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneFileTools-" + UUID().uuidString).path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = AIFileToolService()
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func file(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func call(_ name: String, _ args: [String: AIToolValue], lease: AIFileAccessLease? = nil) async throws -> [String: AIToolValue] {
        let result = try await service.execute("keylane_" + name, arguments: args, scopes: [.init(path: root.path)], check: { try lease?.check(); try Task.checkCancellation() })
        return try JSONDecoder().decode([String: AIToolValue].self, from: Data(result.text.utf8))
    }
    private func text(_ value: AIToolValue?) -> String { if case .string(let text) = value { return text }; return "" }
    private func rows(_ value: AIToolValue?) -> [[String: AIToolValue]] {
        if case .array(let rows) = value { return rows.compactMap { if case .object(let object) = $0 { return object }; return nil } }; return []
    }
    private func revision(_ path: String) async throws -> String { text(try await call("file_info", ["path": .string(path)])["revision"]) }
    private func rejects(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected a refused file operation", file: file, line: line) } catch {}
    }

    func testDirectoryReadIsSortedPagedAndDoesNotReadContents() async throws {
        try file("z.txt", "not returned"); try file("a.txt", "not returned"); try file(".hidden", "secret")
        let first = try await call("read_file", ["path": .string(root.path), "limit": .number(1)])
        XCTAssertEqual(rows(first["entries"]).map { text($0["path"]) }, [root.path + "/a.txt"])
        XCTAssertEqual(first["next_offset"], .number(1))
        let second = try await call("read_file", ["path": .string("."), "limit": .number(1), "offset": .number(1)])
        XCTAssertEqual(rows(second["entries"]).map { text($0["path"]) }, [root.path + "/z.txt"])
        XCTAssertEqual(second["next_offset"], .null)
        XCTAssertFalse(String(describing: first).contains("not returned"))
    }
    func testReadPreservesUTF8BoundariesAndRevision() async throws {
        let expected = "你好👋\nmore text 中文"
        try file("utf8.txt", expected)
        var offset = 0, output = "", rev = ""
        while true {
            let part = try await call("read_file", ["path": .string("utf8.txt"), "offset": .number(Double(offset)), "limit": .number(7)])
            output += text(part["text"])
            if rev.isEmpty { rev = text(part["revision"]) }; XCTAssertEqual(text(part["revision"]), rev)
            guard case .number(let next) = part["next_offset"] else { break }
            XCTAssertGreaterThan(Int(next), offset); offset = Int(next)
        }
        XCTAssertEqual(output, expected)
        await rejects { _ = try await self.call("read_file", ["path": .string("utf8.txt"), "offset": .number(1)]) }
        try Data([0, 1, 255]).write(to: root.appendingPathComponent("binary"))
        await rejects { _ = try await self.call("read_file", ["path": .string("binary")]) }
    }
    func testReplacementPreservesExtendedAttributesAndPermissions() async throws {
        try file("tagged.txt", "before")
        let path = root.appendingPathComponent("tagged.txt").path
        let attribute = "com.keylane.fixture", value = Array("fixture attribute".utf8)
        let set = value.withUnsafeBytes { setxattr(path, attribute, $0.baseAddress, $0.count, 0, 0) }
        XCTAssertEqual(set, 0)
        XCTAssertEqual(chmod(path, 0o640), 0)
        let rev = try await revision("tagged.txt")
        _ = try await call("write_file", ["path": .string("tagged.txt"), "content": .string("after"), "mode": .string("replace"), "expected_revision": .string(rev)])
        var bytes = [UInt8](repeating: 0, count: 128)
        let count = getxattr(path, attribute, &bytes, bytes.count, 0, 0)
        XCTAssertEqual(count, value.count)
        XCTAssertEqual(Array(bytes.prefix(max(0, count))), value)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testReadLargeFileIsBoundedAndOffsetContinues() async throws {
        try file("large", String(repeating: "a", count: 100_000))
        let value = try await call("read_file", ["path": .string("large")])
        XCTAssertEqual(text(value["text"]).utf8.count, 4096)
        XCTAssertEqual(value["next_offset"], .number(4096)); XCTAssertEqual(value["truncated"], .bool(true))
    }
    func testGlobRecursionHiddenDepthAndGrep() async throws {
        try file("nested/deep/code.swift", "FIRST\nNeedle here\nlast")
        try file("z.swift", "needle second"); try file(".private.swift", "needle")
        try file(".env", "needle credential"); try file("nested/.env.local", "needle credential")
        let glob = try await call("glob", ["path": .string("."), "pattern": .string("**/*.swift")])
        XCTAssertEqual(Set(rows(glob["matches"]).map { text($0["path"]) }), [root.path + "/z.swift", root.path + "/nested/deep/code.swift"])
        let shallow = try await call("glob", ["path": .string("."), "pattern": .string("**/*.swift"), "depth": .number(1)])
        XCTAssertEqual(rows(shallow["matches"]).map { text($0["path"]) }, [root.path + "/z.swift"])
        XCTAssertEqual(shallow["truncated"], .bool(true))
        let grep = try await call("grep", ["path": .string("."), "pattern": .string("**/*"), "query": .string("NEEDLE")])
        XCTAssertEqual(rows(grep["matches"]).count, 2)
        XCTAssertTrue(rows(grep["matches"]).contains { $0["line"] == .number(2) })
        XCTAssertTrue(AIFileToolService.isSensitive(".env.local"))
        XCTAssertTrue(AIFileToolService.isSensitive("/x/.ssh/key"))
        await rejects { _ = try await self.call("glob", ["path": .string("."), "pattern": .string("../*")]) }
    }
    func testScopeTraversalAndSymlinksAreRefused() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("Outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("secret"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside.appendingPathComponent("secret"))
        for path in [outside.path + "/secret", "../" + outside.lastPathComponent + "/secret", "escape/secret", "link"] {
            await rejects { _ = try await self.call("read_file", ["path": .string(path)]) }
        }
        await rejects { _ = try await self.call("write_file", ["path": .string("escape/new"), "content": .string("changed")]) }
        await rejects { _ = try await self.call("write_file", ["path": .string("link"), "content": .string("changed")]) }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("secret"), encoding: .utf8), "outside")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new").path))
        let glob = try await call("glob", ["path": .string("."), "pattern": .string("**/*")])
        XCTAssertFalse(rows(glob["matches"]).contains { text($0["path"]).hasSuffix("/secret") })
    }
    func testCreateReplaceAndStaleWrites() async throws {
        let created = try await call("write_file", ["path": .string("new.txt"), "content": .string("first")])
        XCTAssertEqual(created["written"], .bool(true))
        await rejects { _ = try await self.call("write_file", ["path": .string("new.txt"), "content": .string("overwrite")]) }
        await rejects { _ = try await self.call("write_file", ["path": .string("new.txt"), "mode": .string("replace"), "content": .string("overwrite")]) }
        _ = try await call("write_file", ["path": .string("new.txt"), "mode": .string("replace"), "content": .string("second"), "expected_revision": created["revision"]!])
        await rejects { _ = try await self.call("write_file", ["path": .string("new.txt"), "mode": .string("replace"), "content": .string("stale"), "expected_revision": created["revision"]!]) }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt"), encoding: .utf8), "second")
    }
    func testEditRequiresUniqueTextAndFreshRevision() async throws {
        try file("edit", "one one")
        let rev = try await revision("edit")
        let args: [String: AIToolValue] = ["path": .string("edit"), "old_text": .string("one"), "new_text": .string("two"), "expected_revision": .string(rev)]
        await rejects { _ = try await self.call("edit_file", args) }
        var all = args; all["replace_all"] = .bool(true)
        _ = try await call("edit_file", all)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("edit"), encoding: .utf8), "two two")
        await rejects { _ = try await self.call("edit_file", all) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".keylane-ai-") })
    }
    func testDirectoryCreationAndHardlinkReplacement() async throws {
        _ = try await call("create_directory", ["path": .string("folder")])
        await rejects { _ = try await self.call("create_directory", ["path": .string("folder")]) }
        await rejects { _ = try await self.call("create_directory", ["path": .string(".")]) }
        try file("original", "unchanged")
        try FileManager.default.linkItem(at: root.appendingPathComponent("original"), to: root.appendingPathComponent("alias"))
        let rev = try await revision("alias")
        _ = try await call("write_file", ["path": .string("alias"), "mode": .string("replace"), "content": .string("changed"), "expected_revision": .string(rev)])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("original"), encoding: .utf8), "unchanged")
    }
    func testRevocationCancelsBeforeEffectsAndInvalidBookmarkRefusesAccess() async throws {
        let lease = AIFileAccessLease(); lease.revoke()
        await rejects { _ = try await self.call("write_file", ["path": .string("blocked"), "content": .string("data")], lease: lease) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("blocked").path))
        await rejects {
            _ = try await self.service.execute("keylane_read_file", arguments: ["path": .string(self.root.path)], scopes: [.init(path: self.root.path, bookmark: Data([1, 2, 3]))])
        }
    }
    func testCancellationDuringStagingPreservesFileAndRemovesTemporary() async throws {
        try file("original", "preserved")
        let rev = try await revision("original"), path = root.path
        await rejects {
            _ = try await self.service.execute("keylane_write_file", arguments: ["path": .string("original"), "mode": .string("replace"), "content": .string("changed"), "expected_revision": .string(rev)], scopes: [.init(path: path)], check: {
                if (try? FileManager.default.contentsOfDirectory(atPath: path).contains { $0.hasPrefix(".keylane-ai-") }) == true { throw CancellationError() }
            })
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("original"), encoding: .utf8), "preserved")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".keylane-ai-") })
    }
}
