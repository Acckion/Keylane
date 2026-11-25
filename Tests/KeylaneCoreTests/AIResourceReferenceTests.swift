import XCTest
@testable import KeylaneCore

final class AIResourceReferenceTests: XCTestCase {
    func testStableIdentityIsScopedAndDoesNotExposeSourceID() throws {
        let source = "/synthetic/private/folder/文稿.txt"
        let first = try AIResourceReference(moduleID: .init(rawValue: "fixture.files"), sourceID: source)
        XCTAssertEqual(first, try AIResourceReference(moduleID: .init(rawValue: "fixture.files"), sourceID: source))
        XCTAssertNotEqual(first, try AIResourceReference(moduleID: .init(rawValue: "fixture.clipboard"), sourceID: source))
        XCTAssertFalse(first.uri.contains("private"))
        XCTAssertEqual(try AIResourceReference(uri: first.uri), first)
        XCTAssertEqual(try JSONDecoder().decode(AIResourceReference.self, from: JSONEncoder().encode(first)), first)
    }
    func testMalformedOrNoncanonicalURIRejected() throws {
        let valid = try AIResourceReference(moduleID: .init(rawValue: "fixture"), sourceID: "record").uri
        for invalid in ["file:///synthetic/data", valid + "?read=true", valid + "#fragment", valid + "/", valid.uppercased(), "keylane-resource://v1/invalid/id"] {
            XCTAssertThrowsError(try AIResourceReference(uri: invalid))
        }
    }
    func testSnapshotsRetainIdentityButSeparateVersionAndCapturedContent() throws {
        let reference = try AIResourceReference(moduleID: .init(rawValue: "fixture"), sourceID: "record")
        let first = AIResourceSnapshot(reference: reference, revision: "v1", text: "before")
        let second = AIResourceSnapshot(reference: reference, revision: "v2", text: "after")
        XCTAssertEqual(first.reference, second.reference)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.matches("before")); XCTAssertFalse(first.matches("after"))
        XCTAssertEqual(try JSONDecoder().decode(AIResourceSnapshot.self, from: JSONEncoder().encode(first)), first)
    }
    func testToolMetadataCannotClaimDifferentContentOrBecomeReadAuthority() throws {
        let reference = try AIResourceReference(moduleID: .init(rawValue: "fixture"), sourceID: "record")
        let snapshot = AIResourceSnapshot(reference: reference, revision: "v1", text: "data")
        let result = try AIToolResult(text: "data", resourceSnapshot: snapshot)
        XCTAssertEqual(try JSONDecoder().decode(AIToolResult.self, from: JSONEncoder().encode(result)), result)
        XCTAssertThrowsError(try AIToolResult(text: "changed", resourceSnapshot: snapshot))
        XCTAssertThrowsError(try AIToolResult(text: "data", isError: true, resourceSnapshot: snapshot))
        let legacy = try JSONDecoder().decode(AIToolResult.self, from: Data("{\"text\":\"old\",\"isError\":false}".utf8))
        XCTAssertNil(legacy.resourceSnapshot)
    }

}
