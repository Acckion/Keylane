import XCTest
@testable import KeylaneCore

final class AIActionImpactTests: XCTestCase {
    func testDeclaredEffectsAreStableAndPreparationCannotDowngradeThem() throws {
        let privateRead = AIActionImpact.privateRead
        XCTAssertTrue(privateRead.containsSensitiveEffects)
        XCTAssertFalse(AIActionImpact.computation.containsSensitiveEffects)
        XCTAssertFalse(AIActionImpact.publicRead.containsSensitiveEffects)
        XCTAssertTrue(privateRead.merging(.computation).effects.isSuperset(of: privateRead.effects))
        XCTAssertEqual(privateRead.summary, "读取私人数据 · 发送给所选模型")
        XCTAssertEqual(try JSONDecoder().decode(AIActionImpact.self, from: JSONEncoder().encode(privateRead)), privateRead)
    }
    func testUnknownMetadataCannotClaimPublicOrPureEffects() {
        XCTAssertTrue(AIActionImpact.unspecified.effects.isEmpty)
        XCTAssertNotEqual(AIActionImpact.unspecified, .computation)
        XCTAssertTrue(AIActionImpact.createFile.containsSensitiveEffects)
        XCTAssertTrue(AIActionImpact.createDirectory.containsSensitiveEffects)
        XCTAssertTrue(AIActionImpact.openApplication.containsSensitiveEffects)
    }
}
