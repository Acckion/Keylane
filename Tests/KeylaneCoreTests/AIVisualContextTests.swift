import XCTest
import CoreGraphics
import ImageIO
@testable import KeylaneCore

final class AIVisualContextTests: XCTestCase {
    func raster() throws -> Data {
        let context = CGContext(data: nil, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let data = NSMutableData()
        let encoder = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(encoder, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(encoder)); return data as Data
    }
    func testImageValidationAndPersistence() throws {
        let image = try AIImageInput(data: raster(), mediaType: "image/png", width: 16, height: 12)
        XCTAssertEqual(try JSONDecoder().decode(AIImageInput.self, from: JSONEncoder().encode(image)), image)
        XCTAssertThrowsError(try AIImageInput(data: image.data, mediaType: "image/jpeg", width: 16, height: 12))
        XCTAssertThrowsError(try AIImageInput(data: image.data, mediaType: "image/png", width: 17, height: 12))
        XCTAssertThrowsError(try AIImageInput(data: Data([0xff, 0xd8, 0xff]), mediaType: "image/jpeg", width: 1, height: 1))
        XCTAssertThrowsError(try AIImageInput(data: image.data, mediaType: "image/png", width: 2049, height: 12))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(image)) as! [String: Any]
        object["width"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(AIImageInput.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testMergeRetainsSourceLabelsAndBoundsUnicode() {
        let merged = AIVisualText.merge(accessibility: ["Sales Chart", "Revenue 100", "Sales Chart"], ocr: "sales chart\nRevenue 100\n增长 20%")
        XCTAssertEqual(merged.components(separatedBy: "Sales Chart").count, 2)
        XCTAssertTrue(merged.contains("辅助功能文字")); XCTAssertTrue(merged.contains("增长 20%"))
        XCTAssertFalse(merged.contains("sales chart\n"))
        let limited = AIVisualText.merge(accessibility: [String(repeating: "中", count: 10_000)], ocr: "ignored", maximumBytes: 67)
        XCTAssertLessThanOrEqual(limited.utf8.count, 67)
        XCTAssertFalse(AIVisualText.merge(accessibility: [], ocr: "").isEmpty)
    }
    func testRegionNeverRoundsOutsideSelection() throws {
        let selection = CGRect(x: 0.101, y: 0.202, width: 0.501, height: 0.601)
        let rect = try AIVisualRegion.pixelRect(selection, width: 100, height: 100)
        XCTAssertGreaterThanOrEqual(rect.minX, 10.1); XCTAssertLessThanOrEqual(rect.maxX, 60.2)
        XCTAssertGreaterThanOrEqual(rect.minY, 20.2); XCTAssertLessThanOrEqual(rect.maxY, 80.3)
        XCTAssertThrowsError(try AIVisualRegion.pixelRect(CGRect(x: -0.1, y: 0, width: 1, height: 1), width: 100, height: 100))
        XCTAssertThrowsError(try AIVisualRegion.pixelRect(CGRect(x: 0, y: 0, width: 0.01, height: 0.01), width: 100, height: 100))
        let global = AIVisualRegion.globalRect(.init(x: 0.5, y: 0, width: 0.5, height: 1), window: .init(x: -600, y: -200, width: 400, height: 300))
        XCTAssertEqual(global, CGRect(x: -400, y: -200, width: 200, height: 300))
        XCTAssertFalse(global.contains(CGRect(x: -599, y: -199, width: 50, height: 20)))
    }
    func testAccessibilityNeverReadsProtectedOrContainerValues() {
        XCTAssertFalse(AIVisualAccessibilityPolicy.canVisit(role: "AXTextField", subrole: "AXSecureTextField", hidden: false, protected: false))
        XCTAssertFalse(AIVisualAccessibilityPolicy.canVisit(role: "AXStaticText", subrole: "", hidden: true, protected: false))
        XCTAssertFalse(AIVisualAccessibilityPolicy.canVisit(role: "AXGroup", subrole: "", hidden: false, protected: true))
        XCTAssertFalse(AIVisualAccessibilityPolicy.canReadValue(role: "AXWebArea"))
        XCTAssertFalse(AIVisualAccessibilityPolicy.canReadValue(role: "AXGroup"))
        XCTAssertTrue(AIVisualAccessibilityPolicy.canReadValue(role: "AXTextArea"))
    }
}
