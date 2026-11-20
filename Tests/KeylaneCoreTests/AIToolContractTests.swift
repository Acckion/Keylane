import Foundation
import KeylaneCore
import XCTest

final class AIToolContractTests: XCTestCase {
    func testStrictArgumentsRejectExtraMissingAndWrongTypes() throws {
        let tool = try AIToolDefinition(name: "fixture_lookup", title: "查询", description: "Synthetic lookup", parameters: [
            .init("query", description: "Text", kind: .string(maximumLength: 12)),
            .init("limit", description: "Count", kind: .integer(minimum: 1, maximum: 5), required: false),
        ])
        try tool.validate(AIToolValue.arguments(#"{"query":"测试","limit":3}"#))
        for invalid in [#"{}"#, #"{"query":"ok","path":"/private"}"#, #"{"query":true}"#,
                        #"{"query":"ok","limit":1.5}"#, #"{"query":"ok","limit":9}"#,
                        #"{"query":"中文中文中文"}"#] {
            XCTAssertThrowsError(try tool.validate(AIToolValue.arguments(invalid)))
        }
        XCTAssertThrowsError(try AIToolValue.arguments("[]"))
        XCTAssertThrowsError(try AIToolValue.arguments(String(repeating: " ", count: 16_385)))
    }

    func testSchemaMatchesOptionalAndEnumArguments() throws {
        let tool = try AIToolDefinition(name: "fixture", title: "示例", description: "Test", parameters: [
            .init("format", description: "Format", kind: .choice(["short", "long"])),
            .init("details", description: "Details", kind: .boolean, required: false),
        ])
        try tool.validate(["format": .string("short")])
        XCTAssertThrowsError(try tool.validate(["format": .string("unknown")]))
        guard case .object(let schema) = tool.inputSchema else { return XCTFail("Object schema required") }
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["required"], .array([.string("format")]))
    }

    func testDefinitionAndResultLimitsAreExplicit() throws {
        XCTAssertThrowsError(try AIToolDefinition(name: "invalid.name", title: "Test", description: "Test"))
        XCTAssertThrowsError(try AIToolDefinition(name: "test", title: "Test", description: "Test", parameters: [
            .init("q", description: "", kind: .boolean), .init("q", description: "", kind: .boolean),
        ]))
        XCTAssertThrowsError(try AIToolCall(id: "bad\nid", name: "test", arguments: [:]))
        XCTAssertThrowsError(try AIToolResult(text: String(repeating: "字", count: 11_000)))
        let result = try AIToolResult(text: "Synthetic tool failure", isError: true)
        XCTAssertEqual(try JSONDecoder().decode(AIToolResult.self, from: JSONEncoder().encode(result)), result)
    }

    func testDeepOrNonJSONArgumentsAreRejected() {
        XCTAssertThrowsError(try AIToolValue.arguments("{\"nested\":" + String(repeating: "[", count: 20) + "0" + String(repeating: "]", count: 20) + "}"))
        XCTAssertThrowsError(try AIToolValue.arguments(#"{"value":NaN}"#))
    }
    func testCatalogRejectsDuplicatesUnknownToolsAndInvalidCalls() throws {
        let definition = try AIToolDefinition(name: "fixture", title: "Test", description: "Synthetic tool")
        XCTAssertThrowsError(try AIToolCatalog([definition, definition]))
        let catalog = try AIToolCatalog([definition])
        try catalog.validate(AIToolCall(id: "one", name: "fixture", arguments: [:]))
        XCTAssertThrowsError(try catalog.validate(AIToolCall(id: "two", name: "unregistered", arguments: [:])))
        XCTAssertThrowsError(try catalog.validate(AIToolCall(id: "three", name: "fixture", arguments: ["extra": .bool(true)])))
    }

    func testBudgetRejectsReplayWithoutPartialAdmission() throws {
        var budget = AIToolRunBudget()
        let call = try AIToolCall(id: "one", name: "fixture", arguments: [:])
        try budget.admit([call])
        XCTAssertThrowsError(try budget.admit([call]))
        XCTAssertEqual(budget.callCount, 1)
        for _ in 0..<6 { try budget.beginRound() }
        XCTAssertThrowsError(try budget.beginRound())
        try budget.record(AIToolResult(text: "fixture"), for: "one")
        XCTAssertThrowsError(try budget.record(AIToolResult(text: "duplicate"), for: "one"))
        let excessive = try (0..<12).map { try AIToolCall(id: "extra-\($0)", name: "fixture", arguments: [:]) }
        XCTAssertThrowsError(try budget.admit(excessive))
        XCTAssertEqual(budget.callCount, 1)
    }

}
