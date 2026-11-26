import XCTest
@testable import KeylaneCore

final class AIInstructionDefinitionTests: XCTestCase {
    func testDeterministicDeduplicationAndBasePreservation() throws {
        let a = AIInstructionSection(moduleID: .init(rawValue: "a"), definition: .init("A guidance"))
        let b = AIInstructionSection(moduleID: .init(rawValue: "b"), definition: .init("B guidance"))
        let text = try XCTUnwrap(AIInstructionSection.compose(base: "Keep\nthese instructions.", sections: [b,a,a]))
        XCTAssertEqual(text.components(separatedBy: "A guidance").count, 2)
        XCTAssertTrue(text.range(of: "A guidance")!.lowerBound < text.range(of: "B guidance")!.lowerBound)
        XCTAssertTrue(text.hasSuffix("Keep\nthese instructions."))
        XCTAssertEqual(try AIInstructionSection.compose(base: "unchanged", sections: []), "unchanged")
        XCTAssertNil(try AIInstructionSection.compose(base: nil, sections: []))
    }
    func testInvalidConflictingAndOversizedGuidanceRejected() throws {
        XCTAssertThrowsError(try AIInstructionDefinition("  ").validate())
        XCTAssertThrowsError(try AIInstructionDefinition(String(repeating: "x", count: 4097)).validate())
        let owner = ModuleID(rawValue: "a")
        XCTAssertThrowsError(try AIInstructionSection.compose(base: nil, sections: [
            .init(moduleID: owner, definition: .init("A")), .init(moduleID: owner, definition: .init("B"))]))
        XCTAssertThrowsError(try AIInstructionSection.compose(base: nil, sections: (0..<5).map {
            .init(moduleID: .init(rawValue: "fixture.\($0)"), definition: .init(String(repeating: "x", count: 4096)))
        }))
    }
}
