import XCTest
@testable import KeylaneCore

final class NativeUtilityTests: XCTestCase {
    func testCalculatorPrecedenceAndFullWidthInput() {
        XCTAssertEqual(Calculator.evaluate("＝２×（３＋４）"), 14)
        XCTAssertEqual(Calculator.evaluate("-2^2"), -4)
        XCTAssertEqual(Calculator.evaluate("2^3^2"), 512)
        XCTAssertEqual(Calculator.evaluate("2^-2"), 0.25)
        XCTAssertEqual(Calculator.evaluate("200 × 10%"), 20)
        XCTAssertEqual(Calculator.evaluate("sqrt(16) + 1e-3"), 4.001)
        for invalid in ["1 2", "sqrt(-1)", "2^", "2^99999", "1e+", "unknown(2)", "1/0"] {
            XCTAssertNil(Calculator.evaluate(invalid), invalid)
        }
    }

    func testSystemShortcutIdentifierSurvivesRenameAndDuplicateTitles() {
        let one = "B8EF8560-C860-4BE9-9C44-3D01232853C1"
        let two = "341A2AF4-4AC7-48CE-81DD-41BF967C7A58"
        let entries = SystemShortcut.parse("测试 (本机) (\(one))\n测试 (本机) (\(two))\n无效行\n测试 (本机) (\(one))")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.name)), ["测试 (本机)"])
        XCTAssertEqual(SystemShortcut.parse("改名 (\(one.lowercased()))").first?.commandID, "shortcut:" + one)
    }
}
