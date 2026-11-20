import XCTest
@testable import KeylaneCore

final class FocusApplicationExitsTests: XCTestCase {
    let process = FocusApplicationExits.Process(pid: 12, launched: Date(timeIntervalSince1970: 123))
    let application = FocusApplication(id: "fixture.app", name: "Fixture")
    let url = URL(fileURLWithPath: "/tmp/FocusFixture.app")
    func testDelayedExitSurvivesSessionSwitchAndRoundTrip() throws {
        var ledger = FocusApplicationExits(); let first = UUID(), second = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: first))
        ledger.finish(first, restore: true)
        ledger = try JSONDecoder().decode(FocusApplicationExits.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(ledger.request(process, application: application, url: url, session: second))
        XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
        ledger.observedExit(process)
        XCTAssertTrue(ledger.restorable(blocked: { _ in true }).isEmpty)
        XCTAssertEqual(ledger.restorable(blocked: { _ in false }).map(\.url), [url])
        // Failed/blocked reopen attempts do not consume the durable receipt.
        XCTAssertEqual(ledger.receipts.count, 1)
        ledger.restored(process); XCTAssertTrue(ledger.receipts.isEmpty)
    }
    func testRejectedExitIsNotRepeatedForSameProcessButRelaunchIsIndependent() {
        var ledger = FocusApplicationExits(); let session = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: session))
        ledger.rejected(process)
        XCTAssertFalse(ledger.request(process, application: application, url: url, session: UUID()))
        ledger.finish(session, restore: true)
        XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
        let relaunched = FocusApplicationExits.Process(pid: process.pid, launched: process.launched.addingTimeInterval(10))
        XCTAssertTrue(ledger.request(relaunched, application: application, url: url, session: UUID()))
    }
    func testMissingLaunchMetadataIsNotAnExitOrPermissionToRetry() {
        var ledger = FocusApplicationExits()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: UUID()))
        ledger.reconcile(process, running: true, launched: nil)
        XCTAssertFalse(ledger.receipts[0].exited)
        XCTAssertFalse(ledger.request(process, application: application, url: url, session: UUID()))
        ledger.reconcile(process, running: true, launched: process.launched.addingTimeInterval(1))
        XCTAssertTrue(ledger.receipts[0].exited)
    }
    func testNoRestorePreferenceAndRestartOwnership() {
        var ledger = FocusApplicationExits(); let old = UUID(), new = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: old))
        ledger.transfer(old, to: new); ledger.finish(old, restore: true)
        ledger.observedExit(process)
        XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
        ledger.finish(new, restore: false)
        XCTAssertTrue(ledger.receipts.isEmpty)
    }
}
