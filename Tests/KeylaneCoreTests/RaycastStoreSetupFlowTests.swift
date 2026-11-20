import XCTest
@testable import KeylaneCore

final class RaycastStoreSetupFlowTests: XCTestCase {
    func testReadinessDoesNotStartWritesOrActivationAndRequiresTwoExplicitActions() {
        var setup = RaycastStoreSetupFlow()
        XCTAssertNil(setup.action)
        setup.observe(nil, fresh: nil)
        XCTAssertEqual(setup.state, .browseOnly)
        XCTAssertFalse(setup.begin(.createEmpty))
        XCTAssertFalse(setup.begin(.activate))

        setup.observe(.setupRequired, fresh: .independentlyVerifiedFresh)
        XCTAssertEqual(setup.action, .createEmpty)
        XCTAssertFalse(setup.begin(.activate))
        XCTAssertTrue(setup.begin(.createEmpty))
        XCTAssertFalse(setup.begin(.createEmpty))
        setup.finishActivate(true) // A mismatched terminal result is ignored.
        setup.observe(.ready, fresh: nil)
        XCTAssertEqual(setup.state, .busy)
        setup.finishCreate(.ready)
        XCTAssertEqual(setup.action, .activate)
        XCTAssertFalse(setup.begin(.createEmpty))
        XCTAssertTrue(setup.begin(.activate))
        XCTAssertNil(setup.action)
        setup.finishActivate(true)
        XCTAssertEqual(setup.state, .active)
    }

    func testExistingAmbiguousAndIndeterminateProfilesNeverOfferResetOrRepeat() {
        for observation in [RaycastStoreReceiptEnrollment.Observation.existingInstallation, .ambiguous] {
            var setup = RaycastStoreSetupFlow()
            setup.observe(.setupRequired, fresh: observation)
            XCTAssertEqual(setup.state, .review)
            XCTAssertNil(setup.action)
        }
        var setup = RaycastStoreSetupFlow()
        setup.observe(.setupRequired, fresh: .independentlyVerifiedFresh)
        XCTAssertTrue(setup.begin(.createEmpty))
        setup.finishCreate(.protectedWriteIndeterminate)
        setup.observe(.setupRequired, fresh: .independentlyVerifiedFresh)
        XCTAssertEqual(setup.state, .review)
        XCTAssertFalse(setup.begin(.createEmpty))
        XCTAssertFalse(setup.begin(.activate))
    }

    func testExistingReadyProfileOffersActivationOnlyAndFailureStaysClosed() {
        var setup = RaycastStoreSetupFlow()
        setup.observe(.ready, fresh: .existingInstallation)
        XCTAssertEqual(setup.action, .activate)
        XCTAssertFalse(setup.begin(.createEmpty))
        XCTAssertTrue(setup.begin(.activate))
        setup.finishActivate(false)
        XCTAssertEqual(setup.state, .review)
        XCTAssertNil(setup.action)
    }
}
