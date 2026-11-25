import Foundation
import XCTest
import KeylaneCore

final class FileIndexExclusionPolicyTests: XCTestCase {
    func testRoutineLibraryEventsDoNotDelayExplicitScopesOrOrdinaryFiles() {
        let library = "/fixture/Library"
        let file = library + "/Biome/streams/telemetry.db-shm"
        func routine(_ path: String, scopes: [String] = ["/fixture", "/fixture/Library"]) -> Bool {
            FileIndexExclusionPolicy.isRoutineLibraryChange(path, scopes: scopes, library: library)
        }
        XCTAssertTrue(routine(file))
        XCTAssertTrue(routine(library + "/Preferences/fixture.plist"))
        XCTAssertFalse(routine(file, scopes: [library, library + "/Biome/streams"]))
        XCTAssertTrue(routine(file, scopes: [library, library + "/Biome/unrelated"]))
        XCTAssertFalse(routine(library + "/Biome Backup/notes.txt"))
        XCTAssertFalse(routine(library + "/Group Containers/document.txt"))
    }

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


    func testSavedResultsUseAncestorRulesWithoutRequiringOnlineFilesAndAcceptResolvedScopes() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let target = fixture.appendingPathComponent("scope")
        let alias = fixture.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let resolved = try XCTUnwrap(FileSearchLocation.canonicalPath(target.path))
        var options = FileSearchOptions(roots: [alias.path])
        options.ignorePatterns = ["__pycache__", "custom-excluded"]
        var locations = FileSearchLocation(options: options, automaticExclusions: [])
        XCTAssertTrue(locations.includesSavedResult(at: resolved + "/missing-document.txt", directory: false))
        XCTAssertFalse(locations.includesSavedResult(at: resolved + "/package/__pycache__/nested/missing.pyc", directory: false))
        XCTAssertFalse(locations.includesSavedResult(at: resolved + "/custom-excluded/missing.txt", directory: false))
        XCTAssertFalse(locations.includesSavedResult(at: resolved + "-outside/missing.txt", directory: false))
        options.ignorePatterns.removeAll { $0 == "__pycache__" }
        var removed = FileSearchLocation(options: options, automaticExclusions: [])
        XCTAssertTrue(removed.includesSavedResult(at: resolved + "/package/__pycache__/nested/missing.pyc", directory: false))
    }

}
