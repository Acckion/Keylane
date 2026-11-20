import XCTest
@testable import KeylaneCore

final class ShortcutBindingConfirmationTests: XCTestCase {
    private let target = Shortcut(key: 37, modifiers: 256)
    private let previous = Shortcut(key: 2, modifiers: 2048)
    private var original: [String: Shortcut] { ["old-owner": target, "new-owner": previous] }
    private var overlap: [ShortcutMapEntry] {
        [.init(id: "app:location", shortcut: target, title: "Location", source: .application, applicationID: "fixture")]
    }

    private func begin(_ state: inout ShortcutBindingConfirmation) -> UUID {
        state.begin(target: target, commandID: "new-owner", previous: previous,
                    displaced: "old-owner", evidence: overlap)
        return state.proposal!.id
    }

    // The simulated asynchronous completion uses the same decision that the UI
    // consumes; only .save may replace persisted bindings.
    private func deliver(_ state: inout ShortcutBindingConfirmation, id: UUID,
                         evidence: [ShortcutMapEntry], persisted: inout [String: Shortcut]) -> ShortcutBindingConfirmation.Completion {
        let result = state.complete(id, evidence: evidence, bindings: persisted)
        if case .save(let updated) = result { persisted = updated }
        return result
    }

    func testCancelThenLateMatchingScanDoesNotWriteOrRemoveOriginalOwner() {
        var state = ShortcutBindingConfirmation()
        let id = begin(&state)
        var persisted = original
        state.cancel()
        XCTAssertEqual(deliver(&state, id: id, evidence: overlap, persisted: &persisted), .ignored)
        XCTAssertEqual(persisted, original)
        XCTAssertNil(state.proposal)
    }

    func testCancelThenLateDifferentScanDoesNotReopenConfirmation() {
        var state = ShortcutBindingConfirmation()
        let id = begin(&state)
        var persisted = original
        state.cancel()
        XCTAssertEqual(deliver(&state, id: id, evidence: [], persisted: &persisted), .ignored)
        XCTAssertNil(state.proposal)
        XCTAssertEqual(persisted, original)
    }

    func testNormalConfirmationSavesOnceAndDisplacesOnlyTheOldOwner() {
        var state = ShortcutBindingConfirmation()
        let id = begin(&state)
        var persisted = original
        XCTAssertEqual(deliver(&state, id: id, evidence: overlap, persisted: &persisted), .save(["new-owner": target]))
        XCTAssertEqual(persisted, ["new-owner": target])
        XCTAssertNil(state.proposal)
        XCTAssertEqual(deliver(&state, id: id, evidence: overlap, persisted: &persisted), .ignored)
    }

    func testReopeningTheSameChangeDoesNotReviveAnOldCompletion() {
        var state = ShortcutBindingConfirmation()
        let oldID = begin(&state)
        state.cancel()
        let newID = begin(&state)
        var persisted = original
        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(deliver(&state, id: oldID, evidence: [], persisted: &persisted), .ignored)
        XCTAssertTrue(state.isCurrent(newID))
        XCTAssertEqual(persisted, original)
        XCTAssertEqual(deliver(&state, id: newID, evidence: overlap, persisted: &persisted), .save(["new-owner": target]))
    }

    func testChangedEvidenceRequiresANewConfirmationAndOldCallbackCannotSave() {
        var state = ShortcutBindingConfirmation()
        let id = begin(&state)
        var persisted = original
        XCTAssertEqual(deliver(&state, id: id, evidence: [], persisted: &persisted), .needsConfirmation)
        let reviewedID = state.proposal!.id
        XCTAssertNotEqual(id, reviewedID)
        XCTAssertEqual(persisted, original)
        XCTAssertEqual(deliver(&state, id: id, evidence: overlap, persisted: &persisted), .ignored)
        XCTAssertTrue(state.isCurrent(reviewedID))
        XCTAssertEqual(deliver(&state, id: reviewedID, evidence: [], persisted: &persisted), .save(["new-owner": target]))
    }

    func testBindingsChangedDuringScanAreNotOverwritten() {
        var state = ShortcutBindingConfirmation()
        let id = begin(&state)
        var persisted = original
        persisted["new-owner"] = .launcher
        let changed = persisted
        XCTAssertEqual(deliver(&state, id: id, evidence: overlap, persisted: &persisted), .invalid)
        XCTAssertEqual(persisted, changed)
        XCTAssertNil(state.proposal)
    }
}
