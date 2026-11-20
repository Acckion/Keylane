import Foundation
import XCTest
@testable import KeylaneCore

final class RaycastStoreToastStateTests: XCTestCase {
    private func payload(_ operation: String = "show", _ id: Int = 1, title: String = "fixture") -> String {
        #"{"operation":"\#(operation)","id":\#(id),"title":"\#(title)","style":"SUCCESS"}"#
    }

    func testExplicitShowUpdateAndRetirementAreScopedToTheTicket() throws {
        var state = RaycastStoreToastState()
        let a = UUID(), b = UUID()
        XCTAssertThrowsError(try state.apply(payload("update"), from: a))
        XCTAssertEqual(try state.apply(payload(), from: a).title, "fixture")
        XCTAssertEqual(try state.apply(payload("update", title: "updated"), from: a).title, "updated")
        XCTAssertThrowsError(try state.apply(payload(), from: a))
        XCTAssertThrowsError(try state.apply(payload("update"), from: b))
        _ = try state.apply(payload(), from: b)
        XCTAssertThrowsError(try state.apply(payload(), from: a))
        XCTAssertThrowsError(try state.apply(payload("update"), from: a))
        XCTAssertFalse(state.finish(a))
        XCTAssertEqual(try state.apply(payload("update"), from: b).style, .success)
        XCTAssertTrue(state.finish(b))
        XCTAssertFalse(state.finish(b))
        XCTAssertThrowsError(try state.apply(payload("update"), from: b))
    }

    func testRejectsUnsupportedOperationsCallbacksStylesAndOversizeBeforeMutating() throws {
        var state = RaycastStoreToastState()
        let id = UUID()
        for input in [payload("hide"), payload("show", 0), payload(title: String(repeating: "界", count: 700)),
                      #"{"operation":"show","id":1,"title":"bad","style":"NO"}"#,
                      #"{"operation":"show","id":1,"title":"bad","style":"SUCCESS","interaction":{"token":"x"}}"#,
                      #"{"operation":"show","id":1,"title":"bad","style":"SUCCESS","feedbackAction":{"title":"x"}}"#] {
            XCTAssertThrowsError(try state.apply(input, from: id))
        }
        XCTAssertEqual(try state.apply(payload(), from: id).title, "fixture")
    }
}
