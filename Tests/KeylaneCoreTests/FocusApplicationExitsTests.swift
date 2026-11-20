import XCTest
@testable import KeylaneCore

final class FocusApplicationExitsTests: XCTestCase {
    let process = FocusApplicationExits.Process(pid: 12, launched: Date(timeIntervalSince1970: 123))
    let application = FocusApplication(id: "fixture.app", name: "Fixture")
    let url = URL(fileURLWithPath: "/tmp/FocusFixture.app")
    func testConfirmedExitSurvivesSessionSwitchAndRoundTrip() throws {
        var ledger = FocusApplicationExits(); let first = UUID(), second = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: first))
        let sentAt = Date(timeIntervalSince1970: 1000)
        ledger.sent(process, now: sentAt)
        ledger.observedExit(process, now: sentAt.addingTimeInterval(0.25))
        XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
        ledger.finish(first, restore: true)
        ledger = try JSONDecoder().decode(FocusApplicationExits.self, from: JSONEncoder().encode(ledger))
        ledger.discardUnconfirmed()
        XCTAssertTrue(ledger.restorable(blocked: { _ in true }).isEmpty)
        XCTAssertEqual(ledger.restorable(blocked: { _ in false }).map(\.url), [url])
        XCTAssertTrue(ledger.request(.init(pid: 13, launched: process.launched), application: application, url: url, session: second))
        ledger.restored(process)
        XCTAssertEqual(ledger.receipts.count, 1)
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
        ledger.sent(process)
        ledger.reconcile(process, running: true, launched: nil)
        XCTAssertFalse(ledger.receipts[0].exited)
        XCTAssertFalse(ledger.request(process, application: application, url: url, session: UUID()))
        ledger.reconcile(process, running: true, launched: process.launched.addingTimeInterval(1))
        XCTAssertTrue(ledger.receipts.isEmpty)
    }
    func testAcceptedRequestThenSaveDialogCanceledAndManualQuitIsNotAttributed() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var ledger = FocusApplicationExits(); let session = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: session))
        ledger.sent(process, now: now) // terminate() returned true, but no confirmed quit.
        ledger.reconcile(process, running: true, launched: process.launched, now: now.addingTimeInterval(0.1))
        XCTAssertFalse(ledger.request(process, application: application, url: url, session: session))
        ledger = try JSONDecoder().decode(FocusApplicationExits.self, from: JSONEncoder().encode(ledger))
        // The user manually quits while the same Focus session is still active,
        // even inside the short deadline. This must not turn into a reopen ticket.
        ledger.observedExit(process, now: now.addingTimeInterval(0.2))
        ledger.finish(session, restore: true)
        XCTAssertTrue(ledger.receipts.isEmpty)
        XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
    }
    func testDelayedUncertainExitExpiresEvenWhenFocusSessionRemainsActive() {
        let now = Date(timeIntervalSince1970: 1000)
        var ledger = FocusApplicationExits(); let session = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: session))
        ledger.sent(process, now: now)
        ledger.observedExit(process, now: now.addingTimeInterval(1.1))
        ledger.finish(session, restore: true)
        XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
    }
    func testManualQuitAfterCanceledSessionIsNotRestoredInsideOrOutsideWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        for delay: TimeInterval in [1, 45] {
            var ledger = FocusApplicationExits(); let session = UUID()
            XCTAssertTrue(ledger.request(process, application: application, url: url, session: session))
            ledger.sent(process, now: now)
            ledger.finish(session, restore: true)
            XCTAssertFalse(ledger.request(process, application: application, url: url, session: UUID()))
            ledger.observedExit(process, now: now.addingTimeInterval(delay))
            XCTAssertTrue(ledger.receipts.isEmpty)
            XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
        }
    }
    func testUnobservedExitWhileAppWasDownCannotAuthorizeReopen() {
        var ledger = FocusApplicationExits(); let session = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: session))
        ledger.sent(process); ledger.discardUnconfirmed()
        ledger.observedExit(process); ledger.finish(session, restore: true)
        XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
    }
    func testUnacknowledgedQuitCannotAuthorizeReopen() {
        var ledger = FocusApplicationExits(); let session = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: session))
        ledger.finish(session, restore: true)
        ledger.observedExit(process)
        XCTAssertTrue(ledger.receipts.isEmpty)
    }
    func testNoRestorePreferenceAndRestartOwnership() {
        var ledger = FocusApplicationExits(); let old = UUID(), new = UUID()
        XCTAssertTrue(ledger.request(process, application: application, url: url, session: old))
        ledger.sent(process)
        ledger.transfer(old, to: new); ledger.finish(old, restore: true)
        ledger.observedExit(process)
        XCTAssertTrue(ledger.restorable(blocked: { _ in false }).isEmpty)
        ledger.finish(new, restore: false)
        XCTAssertTrue(ledger.receipts.isEmpty)
    }
}
