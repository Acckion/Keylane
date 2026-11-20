import XCTest
@testable import KeylaneCore

final class FileIndexAIQueryTests: XCTestCase {
    func testIndexQueryIsBoundedByBothAuthorizedOwnershipAndLiteralPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneIndexScope-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let root = "/synthetic/index-root", selected = root + "/selected's [folder]"
        for (path, owner) in [(selected + "/match.txt", root), (selected + "-sibling/match.txt", root),
                              (root + "/other/match.txt", root), (selected + "/ungranted-match.txt", "/ungranted")] {
            try index.put(.init(path: path, name: URL(fileURLWithPath: path).lastPathComponent, volume: "/synthetic", modified: 1, directory: false, symlink: false), root: owner, epoch: "n:fixture")
        }
        let options = FileSearchOptions(roots: [root])
        let result = try index.search("match", options: options, within: selected)
        XCTAssertEqual(result.map(\.url.path), [selected + "/match.txt"])
        XCTAssertTrue(try index.search("match", options: options, within: "relative/path").isEmpty)
    }
    func testSystemAliasesRemainInTheSameBoundedSubtree() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneIndexAlias-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        let root = "/synthetic/owner"
        for path in ["/private/tmp/owned/match.txt", "/tmp/owned/match2.txt", "/tmp/owned-other/match.txt"] {
            try index.put(.init(path: path, name: URL(fileURLWithPath: path).lastPathComponent, volume: "/synthetic", modified: 1, directory: false, symlink: false), root: root, epoch: "n:fixture")
        }
        var options = FileSearchOptions(roots: [root]); options.ignorePatterns = []
        XCTAssertEqual(try index.search("match", options: options, within: "/private/tmp/owned").count, 2)
    }
}
