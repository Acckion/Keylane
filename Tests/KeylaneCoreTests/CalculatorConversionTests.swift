import XCTest
import KeylaneCore

final class CalculatorConversionTests: XCTestCase {
    func testUnitConversion() {
        XCTAssertEqual(CalculatorConversion("5 in to cm")?.unitResult, "12.7 cm")
        XCTAssertEqual(CalculatorConversion("３公里转米")?.unitResult, "3000 m")
        XCTAssertEqual(CalculatorConversion("−40 ℃ to °F")?.unitResult, "-40 °F")
        XCTAssertNil(CalculatorConversion("3 km to kg")?.unitResult)
        XCTAssertNil(CalculatorConversion("1+2"))
    }

    func testReferenceRatesAndStaleness() throws {
        let xml = Data("""
        <Cube><Cube time="2026-11-11">
          <Cube currency="USD" rate="2"/><Cube currency="CNY" rate="8"/>
          <Cube currency="JPY" rate="0"/>
        </Cube></Cube>
        """.utf8)
        let rates = try XCTUnwrap(ECBReferenceRates(xml: xml))
        let pair = try XCTUnwrap(CalculatorConversion("100 美元转人民币")?.currencies)
        XCTAssertEqual(rates.date, "2026-11-11")
        XCTAssertEqual(rates.convert(100, from: pair.source, to: pair.target), 400)
        XCTAssertEqual(rates.convert(100, from: "USD", to: "EUR"), 50)
        XCTAssertNil(rates.convert(1, from: "JPY", to: "USD"))
        XCTAssertFalse(rates.isStale(at: Date(timeIntervalSince1970: 1794657600)))
        XCTAssertTrue(rates.isStale(at: Date(timeIntervalSince1970: 1794916800)))
        XCTAssertNil(ECBReferenceRates(xml: Data("<Cube/>".utf8)))
    }

    func testRatesExpireAtGermanMidnightInSummerAndWinter() throws {
        let dates = [
            ("2026-07-01", "2026-07-04T21:59:59Z", "2026-07-04T22:00:00Z"),
            ("2026-01-01", "2026-01-04T22:59:59Z", "2026-01-04T23:00:00Z")
        ]
        let formatter = ISO8601DateFormatter()
        for (published, before, cutoff) in dates {
            let xml = Data("""
                <Cube><Cube time="\(published)"><Cube currency="USD" rate="2"/></Cube></Cube>
                """.utf8)
            let rates = try XCTUnwrap(ECBReferenceRates(xml: xml))
            XCTAssertFalse(rates.isStale(at: try XCTUnwrap(formatter.date(from: before))), published)
            XCTAssertTrue(rates.isStale(at: try XCTUnwrap(formatter.date(from: cutoff))), published)
        }
    }
}
