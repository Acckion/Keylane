import Foundation
import XCTest
import KeylaneCore

final class FileIndexExclusionPolicyTests: XCTestCase {
    func testNestedWritesResolveToNearestBuildDirectoryWithinScope() {
        let scope = "/project"
        let file = "/project/output/report/raw/data.json"
        XCTAssertEqual(FileIndexExclusionPolicy.changeCandidate(
            for: file, scopes: [scope], restored: [], includeHidden: false
        ), "/project/output")
        XCTAssertNil(FileIndexExclusionPolicy.changeCandidate(
            for: file, scopes: [scope, "/project/output/report"], restored: [], includeHidden: false
        ))
        XCTAssertNil(FileIndexExclusionPolicy.changeCandidate(
            for: file, scopes: [scope], restored: ["/project/output/report"], includeHidden: false
        ))
        XCTAssertNil(FileIndexExclusionPolicy.changeCandidate(
            for: "/project/documents/raw/data.json", scopes: [scope], restored: [], includeHidden: false
        ))
    }

    func testIgnoredAncestorsDoNotContributeToIndexChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ignored/\n".utf8).write(to: output.appendingPathComponent(".rayignore"))
        var options = FileSearchOptions(roots: [root.path])
        options.ignorePatterns = ["generated"]
        options.useIgnoreFiles = true
        var locations = FileSearchLocation(options: options, automaticExclusions: [])
        XCTAssertFalse(locations.includesIndexChange(at: output.appendingPathComponent("generated/raw/data").path, directory: false))
        XCTAssertFalse(locations.includesIndexChange(at: output.appendingPathComponent("ignored/raw/data").path, directory: false))
        XCTAssertTrue(locations.includesIndexChange(at: output.appendingPathComponent("reports/data").path, directory: false))
        options.useIgnoreFiles = false
        var withoutIgnoreFiles = FileSearchLocation(options: options, automaticExclusions: [])
        XCTAssertTrue(withoutIgnoreFiles.includesIndexChange(at: output.appendingPathComponent("ignored/raw/data").path, directory: false))
    }

    func testKnownCachesDoNotMatchUnrelatedDirectories() {
        for path in ["/project/.venv", "/home/.cargo/global-cache"] {
            XCTAssertTrue(FileIndexExclusionPolicy.isKnownCache(URL(fileURLWithPath: path)))
        }
        for path in ["/project/registry", "/project/__pycache__", "/project/output", "/home/.cargo/config"] {
            XCTAssertFalse(FileIndexExclusionPolicy.isKnownCache(URL(fileURLWithPath: path)))
        }
    }

    func testPythonCachesUseAnEditableDefaultRuleInsteadOfAutomaticExclusion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cache = root.appendingPathComponent("package/__pycache__", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var options = FileSearchOptions(roots: [root.path])
        XCTAssertEqual(options.ignorePatterns.filter { $0 == "__pycache__" }.count, 1)
        XCTAssertTrue(FileSearchRules.ignored(cache, directory: true, patterns: options.ignorePatterns, rules: []))
        var locations = FileSearchLocation(options: options, automaticExclusions: [])
        XCTAssertFalse(locations.includesIndexChange(at: cache.appendingPathComponent("module.cpython-314.pyc").path, directory: false))
        XCTAssertFalse(FileSearchRules.ignored(root.appendingPathComponent("package/pycache-notes"), directory: true,
                                               patterns: options.ignorePatterns, rules: []))
        options.ignorePatterns.removeAll { $0 == "__pycache__" }
        var restored = FileSearchLocation(options: options, automaticExclusions: [])
        XCTAssertTrue(restored.includesIndexChange(at: cache.appendingPathComponent("module.pyc").path, directory: false))
    }

}
