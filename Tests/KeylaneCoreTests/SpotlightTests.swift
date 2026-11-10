import XCTest
@testable import KeylaneCore

final class SpotlightTests: XCTestCase {
    func testNamesAreLiteralAndUnicodeAware() throws {
        let predicate = try XCTUnwrap(SpotlightSearch.predicate(for: "预算 '2026'"))
        XCTAssertTrue(predicate.evaluate(with: [NSMetadataItemFSNameKey: "团队预算 '2026'.pdf"]))
        XCTAssertFalse(predicate.evaluate(with: [NSMetadataItemFSNameKey: "其他文件.pdf"]))
        let wildcard = try XCTUnwrap(SpotlightSearch.predicate(for: "a*b"))
        XCTAssertTrue(wildcard.evaluate(with: [NSMetadataItemFSNameKey: "a*b.txt"]))
        XCTAssertFalse(wildcard.evaluate(with: [NSMetadataItemFSNameKey: "axb.txt"]))
        let injection = try XCTUnwrap(SpotlightSearch.predicate(for: "' OR TRUEPREDICATE"))
        XCTAssertFalse(injection.evaluate(with: [NSMetadataItemFSNameKey: "private.txt"]))
    }
    func testEmptyAndOversizedSearchDoNotCreateQueries() {
        XCTAssertNil(SpotlightSearch.predicate(for: "  \n"))
        XCTAssertNil(SpotlightSearch.predicate(for: String(repeating: "a", count: 257)))
        XCTAssertNotNil(SpotlightSearch.predicate(for: "文件"))
    }
}
