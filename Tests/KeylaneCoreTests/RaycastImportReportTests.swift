import XCTest
@testable import KeylaneCore

final class RaycastImportReportTests: XCTestCase {
    func testDataOnlyExportIsInventoriedWithoutPretendingToImportIt() throws {
        let payload: [String: Any] = ["snippets": ["schemaVersion": 1, "snippets": [["name": "Synthetic", "text": "value"]]],
                                    "future": ["schemaVersion": 9, "records": [1, 2]]]
        let preview = try RaycastConfiguration.decode(JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(preview.categories.map(\.source), ["future", "snippets"])
        XCTAssertEqual(preview.categories.map(\.status), [.unsupported, .partial])
        XCTAssertEqual(preview.categories.map(\.arrayRecordCount), [2, 1])
        XCTAssertTrue(try preview.archive.plan(current: [:], overwrite: false).changes.isEmpty)
        XCTAssertFalse(preview.warnings.joined().contains("Synthetic"))
        XCTAssertFalse(preview.warnings.joined().contains("value"))
    }
    func testSupportedCategoryNeverClaimsWholeCategoryWasImported() throws {
        let data = try JSONSerialization.data(withJSONObject: ["settings": ["schemaVersion": 1, "commands": []]])
        let preview = try RaycastConfiguration.decode(data)
        XCTAssertEqual(preview.categories.first?.status, .partial)
        XCTAssertTrue(preview.categories.first?.summary.contains("部分可迁移") == true)
    }
    func testBadKnownCategoryIsReportedWithoutWriting() throws {
        let payload: [String: Any] = ["settings": ["schemaVersion": 99, "commands": []], "quicklinks": ["schemaVersion": 1, "quicklinks": "bad"]]
        let preview = try RaycastConfiguration.decode(JSONSerialization.data(withJSONObject: payload))
        XCTAssertEqual(preview.categories.map(\.status), [.invalid, .invalid])
        XCTAssertTrue(try preview.archive.plan(current: [:], overwrite: true).changes.isEmpty)
    }
}
