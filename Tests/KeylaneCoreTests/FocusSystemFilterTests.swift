import XCTest
@testable import KeylaneCore

final class FocusSystemFilterTests: XCTestCase {
    func testSelectedCategoriesMergeAndRejectDeletedAllowCategory() throws {
        let a = FocusCategory(name: "工作", applications: [.init(id: "work.app", name: "Work")], websites: ["work.example.com"])
        let b = FocusCategory(name: "资料", websites: ["www.example.com", "work.example.com"])
        let request = FocusSystemFilter(categories: [b.id, a.id, a.id], mode: .allow, goal: " 深度工作 ")
        XCTAssertEqual(request.categories.count, 2)
        let config = try request.configuration(available: [a, b])
        XCTAssertEqual(config.goal, "深度工作"); XCTAssertEqual(config.mode, .allow); XCTAssertNil(config.duration)
        XCTAssertEqual(config.applications.map(\.id), ["work.app"])
        XCTAssertEqual(Set(config.websites), ["example.com", "work.example.com"])
        XCTAssertThrowsError(try request.configuration(available: [a]))
        XCTAssertThrowsError(try FocusSystemFilter().configuration(available: [a, b]))
    }
    func testManualSessionAlwaysWinsAndDuplicateDeliveryDoesNotRestart() {
        let request = FocusSystemFilter(categories: [UUID()])
        let manual = FocusSession(configuration: .init(), now: Date())
        var link = FocusSystemLink()
        XCTAssertEqual(link.decision(for: request, session: manual), .preserveManual)
        link.selection = request
        XCTAssertEqual(link.decision(for: .init(), session: manual), .preserveManual)
        XCTAssertEqual(link.decision(for: request, session: nil), .unchanged)
        XCTAssertEqual(link.decision(for: .init(categories: [UUID()]), session: nil), .start)
    }
    func testOnlyOwnedSessionCanReplaceFinishOrRecover() {
        let request = FocusSystemFilter(categories: [UUID()])
        var session = FocusSession(configuration: .init(), now: Date())
        session.pause(at: Date())
        var link = FocusSystemLink(); link.selection = request; link.sessionID = session.id
        XCTAssertEqual(link.decision(for: request, session: session), .unchanged)
        XCTAssertEqual(link.decision(for: request, session: session, recovering: true), .resume)
        link.userPaused = true
        XCTAssertEqual(link.decision(for: request, session: session, recovering: true), .unchanged)
        XCTAssertEqual(link.decision(for: .init(), session: session), .finish)
        XCTAssertEqual(link.decision(for: .init(categories: [UUID()]), session: session), .replace)
        let manual = FocusSession(configuration: .init(), now: Date())
        XCTAssertEqual(link.decision(for: .init(), session: manual), .preserveManual)
    }
    func testOverlappingRefreshRetainsRecoveryUntilCurrentLookupCompletes() {
        var state = FocusFilterRefreshState()
        let startup = state.begin(recovering: true)
        let activation = state.begin(recovering: false)
        XCTAssertTrue(state.recovering)
        state.complete(startup)
        XCTAssertTrue(state.recovering); XCTAssertFalse(state.isCurrent(startup))
        state.complete(activation)
        XCTAssertFalse(state.recovering)
        let wake = state.begin(recovering: true)
        state.reset(); state.complete(wake)
        XCTAssertFalse(state.recovering); XCTAssertFalse(state.isCurrent(wake))
    }
    func testArchiveMigrationAndOwnershipRoundTrip() throws {
        let old = try JSONDecoder().decode(FocusArchive.self, from: Data("{}".utf8))
        XCTAssertEqual(old.systemLink, .init())
        var archive = old
        archive.systemLink.selection = .init(categories: [UUID()], mode: .allow, goal: "学习")
        archive.session = FocusSession(configuration: .init(), now: Date())
        archive.systemLink.sessionID = archive.session?.id; archive.systemLink.userPaused = true
        XCTAssertEqual(try JSONDecoder().decode(FocusArchive.self, from: JSONEncoder().encode(archive)), archive)
    }
}
