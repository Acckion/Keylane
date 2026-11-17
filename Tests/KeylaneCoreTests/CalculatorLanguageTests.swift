import Foundation
import KeylaneCore
import XCTest

final class CalculatorLanguageTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    private func result(_ query: String, pixels: Double = 16) -> String? {
        CalculatorLanguage.evaluate(query, locale: locale, pixelsPerEm: pixels)
    }

    func testFunctionsAndMoney() {
        let examples = [
            ("square root of 625", "25"), ("2 power 10", "1024"), ("sum(1, 2, 3)", "6"),
            ("round(23.456, 1)", "23.5"), ("round(123.456, -1)", "120"), ("gcd(48, 18)", "6"),
            ("acos(1)", "0"), ("sinh(0)", "0"), ("csc(pi / 2)", "1"),
            ("52% of 900", "468"), ("20% off 80", "64"), ("15% decrease from 813", "691.05"),
            ("15% tip on $80", "$92.00"), ("20% vat in 120", "20"),
            ("25% off $60 split 3", "$15.00"), ("$1000 at 5% for 10 years compounded annually", "$1,628.89"),
            ("750 m as % of 3 km", "25%"), ("1/8 is what %", "12.5%"),
            ("1.75 as improper", "7/4"), ("7/4 as mixed", "1 3/4"),
            ("255 to base 7", "513"), ("0xFF to base 36", "73"), ("3.3 to nearest quarter", "3.25"),
            ("first 3 characters of \"你好Apple\"", "你好A"), ("1,000+2", "1002")
        ]
        for (query, expected) in examples { XCTAssertEqual(result(query), expected, query) }
        XCTAssertNil(result("42"))
        XCTAssertNil(result("a red apple"))
        XCTAssertNil(result("1% vat in 9 split 0"))
        XCTAssertNil(result("sqrt(-1)"))
        XCTAssertEqual(Calculator.evaluate("sum(1,5; 2,5)", locale: Locale(identifier: "de_DE")), 4)
        XCTAssertEqual(Calculator.evaluate("1.234,5 + 2", locale: Locale(identifier: "de_DE")), 1236.5)
    }

    func testExtendedUnitsAndChemistry() {
        let examples = [
            ("2 inches in px at 72 ppi", "144 px"), ("32px in rem", "2 rem"),
            ("workhours in 2023", "2080 h"), ("1 chain in yards", "22 yards"), ("491.67 rankine in celsius", "0 °C"),
            ("30 dBm in watts", "1 W"), ("1 US legal cup in milliliters", "240 milliliters"),
            ("1 nibble in bits", "4 bits"), ("6′2″ to m", "1.8796 m"), ("−6′2″ to m", "-1.8796 m"),
            ("5:00 min/km in km/h", "12 km/h"), ("3 kg * 2 m", "6 kg·m"),
            ("5 N in kg*m/s^2", "5 kg*m/s^2"), ("90 seconds to mixed", "1 min 30 s"),
            ("145 mins to timespan", "2 h 25 min"), ("55h in workdays", "6.875 workdays"),
            ("100 months in years and months", "8 y 4 mo"), ("max(2 hours 30 min, 200 min)", "3 h 20 min"),
            ("transfer 1 TB at 100 Mbps", "22 h 13 min 20 s"), ("c4 to hz", "261.625565301 Hz"),
            ("molar mass of C6H12O6", "180.156 g/mol"), ("molar mass of Ca(OH)2", "74.092 g/mol"),
            ("speed of light in km/s", "299792.458 km/s"), ("1 astronomical unit / speed of light in minutes", "8.31674639727 minutes"),
            ("100 EUR in euro cents", "10000 euro cents")
        ]
        for (query, expected) in examples { XCTAssertEqual(result(query), expected, query) }
        XCTAssertEqual(result("2 rem in px", pixels: 20), "40 px")
        XCTAssertNil(result("transfer 1 TB at 0 Mbps"))
        XCTAssertNil(result("molar mass of (OH"))
        XCTAssertEqual(CalculatorConversion("USD1K in won")?.amount, 1000)
        XCTAssertEqual(CalculatorConversion("USD1K in won")?.currencies?.target, "KRW")
    }

    func testCalendarAndDestinationDateAcrossTimeZones() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T00:30:00Z"))
        func date(_ query: String) -> String? {
            CalculatorLanguage.evaluate(query, locale: Locale(identifier: "en_US"), now: now, timeZone: .gmt)
        }
        XCTAssertTrue(date("week 44 2026")?.contains("Oct 26") == true)
        XCTAssertTrue(date("monday in 3 weeks")?.contains("Nov 9") == true)
        XCTAssertTrue(date("week 53 2026")?.contains("Dec 28") == true)
        XCTAssertNil(date("week 53 2025"))
        XCTAssertEqual(date("10pm to 2am"), "4 h")
        XCTAssertEqual(date("from 1700000000 to 1700003600"), "1 h")
        XCTAssertEqual(date("days since march"), "238 天")
        XCTAssertEqual(date("days until 2026-10-26"), "1 天")
        XCTAssertTrue(date("August 5 + 5")?.contains("Aug 10") == true)
        XCTAssertTrue(date("3:45pm + 5")?.contains("8:45") == true)
        XCTAssertTrue(date("time in SF")?.contains("Oct 24") == true)
        XCTAssertTrue(date("time in Chamonix + 4 hours")?.contains("Oct 25") == true)
        XCTAssertTrue(date("time in Brisbane + 4")?.contains("2:30") == true)
        XCTAssertTrue(date("4:00 PT in UTC")?.contains("11:00") == true)
        XCTAssertTrue(date("2024-03-15T14:30:00Z")?.contains("Mar 15") == true)
        XCTAssertNil(date("time in a nonexistent place"))
        XCTAssertTrue(date("distance from Chamonix to Paris")?.hasSuffix(" km") == true)
        XCTAssertNil(date("distance from Chamonix to a nonexistent place"))
    }

    func testColorInputsAndConversions() throws {
        XCTAssertNil(CalculatorColor("red"))
        XCTAssertEqual(CalculatorColor("#fa38")?.hexLabel, "#FFAA3388")
        XCTAssertEqual(CalculatorColor("rgb(255 99 99 / 50%)")?.hexLabel, "#FF636380")
        XCTAssertEqual(CalculatorColor("hsl(120 100% 50%)")?.hexLabel, "#00FF00")
        XCTAssertEqual(CalculatorColor("hwb(240 0% 0%)")?.hexLabel, "#0000FF")
        let red = try XCTUnwrap(CalculatorColor("#ff0000"))
        for format in red.formats where ["Lab", "LCH", "Oklab", "Oklch"].contains(format.title) {
            XCTAssertEqual(CalculatorColor(format.text)?.hexLabel, red.hexLabel, format.title)
        }
        XCTAssertNil(CalculatorColor("oklab(1 1e100 0)"))
    }
}
