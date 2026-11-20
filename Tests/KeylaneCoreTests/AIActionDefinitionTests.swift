import XCTest
@testable import KeylaneCore

final class AIActionDefinitionTests: XCTestCase {
    func testUTF8BudgetDoesNotTreatCharactersAsBytes() throws {
        try AIActionContext(sourceID: "one", title: "", text: "😀").validate(maximumBytes: 4)
        XCTAssertThrowsError(try AIActionContext(sourceID: "two", title: "", text: "😀😀").validate(maximumBytes: 4))
        XCTAssertThrowsError(try AIActionContext(sourceID: "empty", title: "", text: " \n").validate(maximumBytes: 4))
    }
    func testContentVersionDistinguishesExactSourceBytes() {
        XCTAssertNotEqual(AIActionContext.digest("é"), AIActionContext.digest("e\u{301}"))
        XCTAssertNotEqual(AIActionContext.digest("original"), AIActionContext.digest("edited"))
    }
    func testModuleDeclarationRejectsUnboundedInputs() {
        XCTAssertThrowsError(try AIActionDefinition(commandID: .init(rawValue: "sample"), title: "", instructions: "task").validate())
        XCTAssertThrowsError(try AIActionDefinition(commandID: .init(rawValue: "sample"), title: "Sample", instructions: "task", maximumInputBytes: .max).validate())
    }
}
