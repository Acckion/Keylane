import Foundation
import KeylaneCore
import XCTest

final class CalculatorReviewRegressionTests: XCTestCase {
    func testISODateOffsetsPrecedeArithmetic() {
        let locale = Locale(identifier: "en_US")
        let zone = TimeZone.gmt
        for (query, explicit) in [("2026-11-17 + 2", "2026-11-17 + 2 days"),
                                  ("=2026-11-17 - 2", "2026-11-17 - 2 days")] {
            let expected = CalculatorLanguage.evaluate(explicit, locale: locale, timeZone: zone)
            XCTAssertNotNil(expected)
            XCTAssertEqual(CalculatorLanguage.evaluate(query, locale: locale, timeZone: zone), expected)
        }
        XCTAssertEqual(CalculatorLanguage.evaluate("2026 - 11 - 17 + 2", locale: locale), "2000")
    }

    func testExplicitDollarCodesAcrossLocales() {
        for identifier in ["en_US", "en_CA", "en_AU"] {
            let locale = Locale(identifier: identifier)
            for code in ["USD", "CAD", "AUD"] {
                XCTAssertEqual(CalculatorLanguage.evaluate("100 \(code) in cents", locale: locale), "10000 cents")
                XCTAssertEqual(CalculatorLanguage.evaluate("100 cents in \(code)", locale: locale), "1 \(code.lowercased())")
            }
            XCTAssertEqual(CalculatorLanguage.evaluate("2 dollars in cents", locale: locale), "200 cents")
        }
    }

    func testGroupedNumbersAndFunctionSeparators() {
        let locale = Locale(identifier: "en_US")
        for (query, expected) in [("(1,000 + 2)", 1002.0), ("1,000 * (2 + 3)", 5000),
                                   ("sum(1,000)", 1), ("max(2,300)", 300),
                                   ("sum((1,000 + 2),3)", 1005),
                                   ("1,000 + max(2,300)", 1300)] {
            XCTAssertEqual(Calculator.evaluate(query, locale: locale), expected, query)
        }
        XCTAssertEqual(Calculator.evaluate("(1.234,5 + 2)", locale: Locale(identifier: "de_DE")), 1236.5)
        XCTAssertEqual(Calculator.evaluate("sum(1,5; 2,5)", locale: Locale(identifier: "de_DE")), 4)
    }

    func testPercentageKeepsDataUnitCase() {
        for (query, expected) in [("1 MB as % of 1 GB", "0.1%"), ("1 MB AS % OF 8 Mb", "100%"),
                                   ("1 Mb as % of 1 MB", "12.5%"), ("750 m as % of 3 km", "25%"),
                                   ("1 as % of 4", "25%")] {
            XCTAssertEqual(CalculatorLanguage.evaluate(query, locale: Locale(identifier: "en_US")), expected, query)
        }
    }
}
