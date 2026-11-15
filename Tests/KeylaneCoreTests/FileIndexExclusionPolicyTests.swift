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

    func testKnownCachesDoNotMatchUnrelatedDirectories() {
        for path in ["/project/.venv", "/project/__pycache__", "/home/.cargo/global-cache"] {
            XCTAssertTrue(FileIndexExclusionPolicy.isKnownCache(URL(fileURLWithPath: path)))
        }
        for path in ["/project/registry", "/project/output", "/home/.cargo/config"] {
            XCTAssertFalse(FileIndexExclusionPolicy.isKnownCache(URL(fileURLWithPath: path)))
        }
    }
}
