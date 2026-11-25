import XCTest
import Darwin
@testable import KeylaneCore
final class IgnoreRuleIOTests: XCTestCase {
    func testBoundedNativeIgnoreReadsPreserveFormatsAndOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"), withIntermediateDirectories: true)
        for (name,text) in [(".gitignore","# comment\n*.log\n!keep.log\n"),(".ignore","临时/\n"),(".rayignore","*.tmp\n"),(".git/info/exclude","local.txt\n")] {
            try Data(text.utf8).write(to: root.appendingPathComponent(name))
        }
        let rules = FileSearchRules.readIgnoreRules(in: root)
        XCTAssertEqual(rules.map(\.pattern),["*.log","keep.log","临时/","*.tmp","local.txt"])
        XCTAssertEqual(rules.map(\.negated), [false,true,false,false,false])
        XCTAssertTrue(rules.allSatisfy { $0.base == root.path })
        try Data(repeating: 65,count:262_145).write(to: root.appendingPathComponent(".gitignore"))
        XCTAssertEqual(FileSearchRules.readIgnoreRules(in: root).map(\.pattern),["临时/","*.tmp","local.txt"])
    }
    func testIgnoreRulesNeverReadLeafOrIntermediateUserLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = root.appendingPathComponent("scope"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: scope,withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("info"),withIntermediateDirectories: true)
        try Data("outside-rule".utf8).write(to: outside.appendingPathComponent("info/exclude"))
        try FileManager.default.createSymbolicLink(at: scope.appendingPathComponent(".git"),withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: scope.appendingPathComponent(".ignore"),withDestinationURL: outside.appendingPathComponent("info/exclude"))
        XCTAssertTrue(FileSearchRules.readIgnoreRules(in: scope).isEmpty)
    }
    func testCallerSelectedDirectoryAliasKeepsExistingRuleSemantics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real"), alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real,withIntermediateDirectories: true)
        try Data("*.log".utf8).write(to: real.appendingPathComponent(".gitignore"))
        try FileManager.default.createSymbolicLink(at: alias,withDestinationURL: real)
        let rules = FileSearchRules.readIgnoreRules(in: alias)
        XCTAssertEqual(rules.map(\.pattern),["*.log"])
        XCTAssertEqual(rules.first?.base,alias.path)
    }
    func testNamedPipeRuleDoesNotWaitForWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(root.appendingPathComponent(".gitignore").path,0o600),0)
        let done = expectation(description: "special file must be skipped")
        DispatchQueue.global(qos:.utility).async {
            XCTAssertTrue(FileSearchRules.readIgnoreRules(in: root).isEmpty)
            done.fulfill()
        }
        wait(for:[done],timeout:3)
    }
}
