import Foundation
import XCTest
@testable import KeylaneCore

final class ExtensionPrototypeSessionTests: XCTestCase {
    func testViewPreferenceSnapshotLimitIsIndependentOfOtherViewInput() throws {
        XCTAssertNil(try ExtensionViewPreferencesTransport.snapshot(in: ["query": "hello"]))
        let large = String(repeating: "字", count: 3_000)
        let request: [String: Any] = ["query": "hello", "preferences": ["name": large]]
        let snapshot = try XCTUnwrap(ExtensionViewPreferencesTransport.snapshot(in: request))
        XCTAssertTrue(ExtensionViewIDTransport.requestBaseFits(
            try JSONSerialization.data(withJSONObject: request), within: 2_048))
        XCTAssertGreaterThan(snapshot.count, ExtensionViewPreferencesTransport.chunkBytes)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot) as? [String: [String: String]])
        XCTAssertEqual(object, ["preferences": ["name": large]])
        XCTAssertThrowsError(try ExtensionViewPreferencesTransport.snapshot(in:
            ["preferences": ["name": String(repeating: "a", count: ExtensionViewPreferencesTransport.maximumBytes + 1)]]))
    }

    func testReviewedViewCatalogRejectsAliasesAndInvalidIdentities() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("view-catalog.json")
        let valid = ["slug": "fixture-view", "owner": "fixture_owner", "command": "firstCommand",
                     "title": "预览", "description": "Synthetic view", "revision": String(repeating: "a", count: 40)]
        func write(_ rows: [[String: String]]) throws {
            try JSONEncoder().encode(rows).write(to: file)
        }
        try write([valid])
        XCTAssertEqual(ReviewedViewArtifact.loadCatalog(in: directory).map(\.artifactName), ["view-fixture-view"])
        XCTAssertTrue(ReviewedViewArtifact.isViewImage("view.cpio"))
        XCTAssertTrue(ReviewedViewArtifact.isViewImage("view-fixture-view.cpio"))
        XCTAssertFalse(ReviewedViewArtifact.isViewImage("menu-bar.cpio"))
        XCTAssertFalse(ReviewedViewArtifact.isViewImage("view-../fixture.cpio"))
        try write([valid, valid])
        XCTAssertTrue(ReviewedViewArtifact.loadCatalog(in: directory).isEmpty)
        for slug in ["../outside", "uuid-generator", "Fixture-view"] {
            try write([valid.merging(["slug": slug]) { _, new in new }])
            XCTAssertTrue(ReviewedViewArtifact.loadCatalog(in: directory).isEmpty)
        }
        try write([valid])
        let original = directory.appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: file, to: original)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        XCTAssertTrue(ReviewedViewArtifact.loadCatalog(in: directory).isEmpty)
    }

    func testReviewedViewCatalogSelectsNamedCommandsAndRetainsLegacyDefault() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("view-catalog.json")
        let revision = String(repeating: "a", count: 40)
        let legacy: [String: Any] = ["slug": "legacy", "owner": "author", "title": "Legacy", "description": "",
                                     "command": "legacyCommand", "revision": revision]
        let first = ["name": "first", "title": "First", "description": ""]
        let second = ["name": "second", "title": "Second", "description": "", "mode": "no-view"]
        var named: [String: Any] = ["slug": "named", "owner": "author", "title": "Named", "description": "",
                                    "commands": [first, second], "revision": revision]
        func write() throws { try JSONSerialization.data(withJSONObject: [legacy, named]).write(to: file) }
        try write()
        let artifacts = ReviewedViewArtifact.loadCatalog(in: directory)
        XCTAssertEqual(artifacts.map(\.usesNamedEntryPoints), [false, true])
        XCTAssertEqual(artifacts.map { $0.entryPoints.map(\.name) }, [["legacyCommand"], ["first", "second"]])
        XCTAssertEqual(artifacts.map { $0.entryPoints.map(\.entryMode) }, [[.view], [.view, .noView]])
        named["commands"] = [first, first]
        try write()
        XCTAssertTrue(ReviewedViewArtifact.loadCatalog(in: directory).isEmpty)
        named["commands"] = [first, second]
        named["command"] = "ambiguous"
        try write()
        XCTAssertTrue(ReviewedViewArtifact.loadCatalog(in: directory).isEmpty)
    }

    func testFinderMapsOnlyTheReservedGuestHomeAlias() {
        let home = URL(fileURLWithPath: "/test-home", isDirectory: true)
        func path(_ input: String) -> String? {
            ExtensionFinderRevealEvent.hostURL(for: input, homeDirectory: home)?.path
        }
        XCTAssertEqual(path("/keylane-host-home"), "/test-home")
        XCTAssertEqual(path("/keylane-host-home/Downloads/中文 文件"), "/test-home/Downloads/中文 文件")
        XCTAssertEqual(path("/keylane-host-home-other/file"), "/keylane-host-home-other/file")
        XCTAssertEqual(path("/private/tmp/fixture"), "/private/tmp/fixture")
        XCTAssertNil(path("/keylane-host-home/../private"))
        XCTAssertNil(path("//remote/fixture"))
        XCTAssertNil(path("/tmp/line\nbreak"))
    }

    private func frame(
        _ session: ExtensionPrototypeSession,
        _ fields: [String: Any]
    ) throws -> Data {
        var values = fields
        values["session"] = values["session"] ?? session.id.uuidString
        values["generation"] = values["generation"] ?? session.generation
        return try JSONSerialization.data(withJSONObject: values)
    }

    private func request(_ id: Int, capability: String = "echo") -> [String: Any] {
        ["kind": "request", "version": 1, "requestID": id, "capability": capability, "text": "中文"]
    }

    func testNegotiatesAndChecksHostOwnedGrants() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [.echo])
        XCTAssertEqual(try session.receive(frame(session, ["kind": "hello", "versions": [2, 1]])), .ready(version: 1))
        XCTAssertEqual(try session.receive(frame(session, request(1))), .result(requestID: 1, text: "中文"))
        var forged = request(2, capability: "clipboard.read")
        forged["extensionID"] = "trusted"
        XCTAssertEqual(try session.receive(frame(session, forged)), .denied(requestID: 2))

        var ungranted = ExtensionPrototypeSession(generation: 1, grants: [])
        _ = try ungranted.receive(frame(ungranted, ["kind": "hello", "versions": [1]]))
        XCTAssertEqual(try ungranted.receive(frame(ungranted, request(1))), .denied(requestID: 1))
    }

    func testChargesExtendedStorageOnlyToAuthorizedCurrentFrames() throws {
        let storageName = ExtensionPrototypeSession.Capability.localStorage.rawValue
        var session = ExtensionPrototypeSession(generation: 2, grants: [.echo, .localStorage]) { _, text in text }
        var stale = request(1, capability: storageName)
        stale["generation"] = 1
        let frames = try [
            frame(session, ["kind": "hello", "versions": [1]]),
            frame(session, stale),
            frame(session, request(1, capability: storageName)),
            frame(session, request(2, capability: "clipboard.read")),
            frame(session, request(3)),
        ]
        var bytes: [Int] = []
        var charged: [ExtensionPrototypeSession.Capability?] = []
        var emitted: [ExtensionPrototypeSession.Reply] = []
        let stream = frames.reduce(into: Data()) { $0.append($1 + Data([10])) }
        try session.receiveBytes(stream, charge: { count, capability in
            bytes.append(count)
            charged.append(capability)
        }) { emitted.append($0) }
        XCTAssertEqual(bytes, frames.map { $0.count + 1 })
        XCTAssertEqual(charged, [nil, nil, .localStorage, nil, .echo])
        XCTAssertEqual(emitted, [.ready(version: 1), .result(requestID: 1, text: "中文"),
                                 .denied(requestID: 2), .result(requestID: 3, text: "中文")])
    }

    func testViewSessionGrantsOnlyViewCapabilities() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [.viewInput, .viewResult]) { _, _ in "" }
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]))
        XCTAssertEqual(try session.receive(frame(session, request(1, capability: "view.input"))), .result(requestID: 1, text: ""))
        XCTAssertEqual(try session.receive(frame(session, request(2, capability: "clipboard.copy"))), .denied(requestID: 2))
        XCTAssertEqual(try session.receive(frame(session, request(3, capability: "view.result"))), .result(requestID: 3, text: ""))
    }

    func testIgnoresEarlierInstallationAndCancelledSession() throws {
        var session = ExtensionPrototypeSession(generation: 2, grants: [.echo])
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]))
        var old = request(1)
        old["generation"] = 1
        assertRejection(.stale, try session.receive(frame(session, old)))
        old["generation"] = 2
        old["session"] = UUID().uuidString
        assertRejection(.stale, try session.receive(frame(session, old)))
        XCTAssertEqual(try session.receive(frame(session, request(1))), .result(requestID: 1, text: "中文"))
        session.cancel()
        assertRejection(.closed, try session.receive(frame(session, request(2))))
    }

    func testRejectsMalformedNegotiationAndReplay() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [.echo])
        assertRejection(.unsupportedVersion, try session.receive(frame(session, ["kind": "hello", "versions": [2]])))
        assertRejection(.closed, try session.receive(frame(session, request(1))))

        var malformed = ExtensionPrototypeSession(generation: 1, grants: [.echo])
        assertRejection(.malformed, try malformed.receive(Data("{".utf8)))

        var replay = ExtensionPrototypeSession(generation: 1, grants: [.echo])
        _ = try replay.receive(frame(replay, ["kind": "hello", "versions": [1]]))
        _ = try replay.receive(frame(replay, request(1)))
        assertRejection(.malformed, try replay.receive(frame(replay, request(1))))
    }

    func testBoundsFramesAndTotalMessages() throws {
        var large = ExtensionPrototypeSession(generation: 1, grants: [])
        assertRejection(.limit, try large.receive(Data(repeating: 0, count: ExtensionPrototypeSession.maxFrameBytes + 1)))

        var busy = ExtensionPrototypeSession(generation: 1, grants: [])
        let start = ContinuousClock.now
        _ = try busy.receive(frame(busy, ["kind": "hello", "versions": [1]]), now: start)
        for id in 1..<ExtensionPrototypeSession.messageBudget {
            let now = start.advanced(by: .seconds(id / ExtensionPrototypeSession.messagesPerSecond))
            _ = try busy.receive(frame(busy, request(id)), now: now)
        }
        assertRejection(.limit, try busy.receive(frame(busy, request(ExtensionPrototypeSession.messageBudget))))
    }

    func testStreamChunksDropStaleFramesAndBoundUnterminatedInput() throws {
        var session = ExtensionPrototypeSession(generation: 2, grants: [.echo])
        let hello = try frame(session, ["kind": "hello", "versions": [1]])
        var replies: [ExtensionPrototypeSession.Reply] = []
        try session.receiveBytes(Data(hello.prefix(7))) { replies.append($0) }
        XCTAssertTrue(replies.isEmpty)
        var chunk = Data(hello.dropFirst(7)) + Data([10])
        var stale = request(1)
        stale["generation"] = 1
        chunk += try frame(session, stale) + Data([10])
        chunk += try frame(session, request(1)) + Data([10])
        try session.receiveBytes(chunk) { replies.append($0) }
        XCTAssertEqual(replies, [.ready(version: 1), .result(requestID: 1, text: "中文")])
        XCTAssertThrowsError(try session.receiveBytes(Data(repeating: 65, count: ExtensionPrototypeSession.maxFrameBytes + 1), emit: { _ in })) {
            XCTAssertEqual($0 as? ExtensionPrototypeSession.Rejection, .limit)
        }
    }

    func testCommitsRepliesBeforeInvalidFrameRegardlessOfReadBoundary() throws {
        let id = UUID()
        let initial = ExtensionPrototypeSession(id: id, generation: 1, grants: [.echo])
        let hello = try frame(initial, ["kind": "hello", "versions": [1]]) + Data([10])
        let valid = hello + (try frame(initial, request(1))) + Data([10])
        let input = valid + Data("{bad}\n".utf8)
        for offset in 0...input.count {
            var session = initial
            var replies: [ExtensionPrototypeSession.Reply] = []
            XCTAssertThrowsError(try {
                for chunk in [input.prefix(offset), input.dropFirst(offset)] {
                    try session.receiveBytes(Data(chunk)) { replies.append($0) }
                }
            }()) {
                XCTAssertEqual($0 as? ExtensionPrototypeSession.Rejection, .malformed)
            }
            XCTAssertEqual(replies, [.ready(version: 1), .result(requestID: 1, text: "中文")])
        }
    }

    func testRejectsPartialFrameAtEOF() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [])
        let hello = try frame(session, ["kind": "hello", "versions": [1]]) + Data([10])
        try session.receiveBytes(hello + Data("{".utf8)) { _ in }
        XCTAssertThrowsError(try session.finishInput()) {
            XCTAssertEqual($0 as? ExtensionPrototypeSession.Rejection, .malformed)
        }
        assertRejection(.closed, try session.receive(frame(session, request(1))))
    }

    func testRejectsMessageBurstWithinOneSecond() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [])
        let now = ContinuousClock.now
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]), now: now)
        for id in 1..<ExtensionPrototypeSession.messagesPerSecond {
            _ = try session.receive(frame(session, request(id)), now: now)
        }
        assertRejection(.limit, try session.receive(frame(session, request(32)), now: now))
    }

    func testClipboardContinuationsHaveTheirOwnFiniteBudget() throws {
        let capability = ExtensionPrototypeSession.Capability.clipboardReadChunk
        var session = ExtensionPrototypeSession(generation: 1, grants: [.echo, capability]) { _, text in text }
        let now = ContinuousClock.now
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]), now: now)
        let chunks = ExtensionClipboardReadTransport.maximumChunks
        for id in 1...chunks {
            XCTAssertEqual(try session.receive(frame(session, request(id, capability: capability.rawValue)), now: now),
                           .result(requestID: UInt64(id), text: "中文"))
        }
        XCTAssertEqual(try session.receive(frame(session, request(chunks + 1)), now: now),
                       .result(requestID: UInt64(chunks + 1), text: "中文"))
        assertRejection(.limit, try session.receive(frame(session, request(chunks + 2, capability: capability.rawValue)), now: now))
    }

    func testUngrantedClipboardContinuationsCannotBypassTheBurstLimit() throws {
        var session = ExtensionPrototypeSession(generation: 1, grants: [])
        let now = ContinuousClock.now
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]), now: now)
        for id in 1..<ExtensionPrototypeSession.messagesPerSecond {
            XCTAssertEqual(try session.receive(frame(session, request(id, capability: "clipboard.readChunk")), now: now),
                           .denied(requestID: UInt64(id)))
        }
        assertRejection(.limit, try session.receive(frame(session, request(32, capability: "clipboard.readChunk")), now: now))
    }

    func testApplicationListPagesHaveIndependentFiniteBudget() throws {
        let capability = ExtensionPrototypeSession.Capability.applicationListPage
        var session = ExtensionPrototypeSession(generation: 1, grants: [.echo, capability]) { _, text in text }
        let now = ContinuousClock.now
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]), now: now)
        let pageLimit = ExtensionApplicationListTransport.maximumPages
        for id in 1...pageLimit {
            XCTAssertEqual(try session.receive(frame(session, request(id, capability: capability.rawValue)), now: now),
                           .result(requestID: UInt64(id), text: "中文"))
        }
        XCTAssertEqual(try session.receive(frame(session, request(pageLimit + 1)), now: now),
                       .result(requestID: UInt64(pageLimit + 1), text: "中文"))
        assertRejection(.limit, try session.receive(frame(session, request(pageLimit + 2, capability: capability.rawValue)), now: now))
    }

    func testReportsHostFailureWithRequestIDWithoutClosingSession() throws {
        var session = ExtensionPrototypeSession(generation: 3, grants: [.echo]) { _, text in
            if text == "中文" { throw CocoaError(.fileWriteUnknown) }
            return text
        }
        _ = try session.receive(frame(session, ["kind": "hello", "versions": [1]]))
        let failure = try session.receive(frame(session, request(1)))
        XCTAssertEqual(failure, .failed(requestID: 1))
        let data = try ExtensionPrototypeSession.encode(failure, session: session.id, generation: 3)
        let fields = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["session"] as? String, session.id.uuidString)
        XCTAssertEqual(fields["generation"] as? Int, 3)
        XCTAssertEqual(fields["version"] as? Int, 1)
        XCTAssertEqual(fields["requestID"] as? Int, 1)
        XCTAssertEqual(fields["error"] as? String, "Host action failed")
        var next = request(2)
        next["text"] = "ok"
        XCTAssertEqual(try session.receive(frame(session, next)), .result(requestID: 2, text: "ok"))
    }

    private func assertRejection(
        _ expected: ExtensionPrototypeSession.Rejection,
        _ expression: @autoclosure () throws -> ExtensionPrototypeSession.Reply
    ) {
        XCTAssertThrowsError(try expression()) { XCTAssertEqual($0 as? ExtensionPrototypeSession.Rejection, expected) }
    }
}

extension ExtensionPrototypeSessionTests {
    func testAlertWaitPreservesOrdinaryExecutionTimeAndUsesCumulativeAllowance() {
        let now = ContinuousClock.now
        let original = now + .seconds(12)
        let budget = ExtensionExecutionBudget(deadline: original, confirmationAllowance: .seconds(20))
        XCTAssertEqual(budget.watchdogDeadline, original)
        XCTAssertEqual(budget.replyDeadline, now + .seconds(10))

        let firstPrompt = now + .seconds(4)
        XCTAssertEqual(budget.beginConfirmation(at: firstPrompt), now + .seconds(24))
        XCTAssertNil(budget.beginConfirmation(at: firstPrompt))
        XCTAssertEqual(budget.watchdogDeadline, original + .seconds(20))
        budget.endConfirmation(at: now + .seconds(16))
        XCTAssertEqual(budget.watchdogDeadline, now + .seconds(24))
        XCTAssertEqual(budget.replyDeadline, now + .seconds(22))

        XCTAssertEqual(budget.beginConfirmation(at: now + .seconds(20)), now + .seconds(28))
        budget.endConfirmation(at: now + .seconds(30))
        XCTAssertEqual(budget.watchdogDeadline, original + .seconds(20))
        XCTAssertNil(budget.beginConfirmation(at: now + .seconds(30)))
    }

    func testAnAlertCannotPauseAnExpiredReplyDeadline() {
        let now = ContinuousClock.now
        let budget = ExtensionExecutionBudget(deadline: now + .seconds(12))
        XCTAssertNil(budget.beginConfirmation(at: now + .seconds(10)))
        XCTAssertEqual(budget.watchdogDeadline, now + .seconds(12))
    }
}

extension ExtensionPrototypeSessionTests {
    func testInstalledCommandSubtitlesPersistIndependentlyAndCanBeCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try XCTUnwrap(ReviewedRaycastCommandMetadata(installationDirectory: directory, command: "first"))
        let second = try XCTUnwrap(ReviewedRaycastCommandMetadata(installationDirectory: directory, command: "second"))
        XCTAssertNil(ReviewedRaycastCommandMetadata(installationDirectory: directory, command: "../outside"))
        try first.update(subtitle: "待处理 👨‍👩‍👧")
        try second.update(subtitle: "")
        let reopened = ReviewedRaycastCommandMetadata(installationDirectory: directory, command: "first")
        XCTAssertEqual(reopened?.subtitle, "待处理 👨‍👩‍👧")
        XCTAssertEqual(second.subtitle, "")
        XCTAssertThrowsError(try first.update(subtitle: "line\nbreak"))
        XCTAssertThrowsError(try first.update(subtitle: String(repeating: "x", count: 1_025)))
        try first.update(subtitle: nil)
        try first.update(subtitle: nil)
        XCTAssertNil(first.subtitle)
        XCTAssertEqual(second.subtitle, "")
        try ReviewedRaycastCommandMetadata.removeAll(installationDirectory: directory)
        XCTAssertNil(second.subtitle)
    }
}

extension ExtensionPrototypeSessionTests {
    func testViewIDTransportDoesNotCountSnapshotsAgainstOrdinaryRequestSize() throws {
        let entries: [[Any]] = (0..<64).map { [$0, String(repeating: "中", count: 17)] }
        var request: [String: Any] = [
            "query": "test", "viewIDs": entries,
            "poppedFrame": ["query": "parent", "viewIDs": entries],
            "viewRoute": [["query": "root", "viewIDs": entries]],
        ]
        let wire = try JSONSerialization.data(withJSONObject: request)
        XCTAssertTrue(ExtensionViewIDTransport.requestBaseFits(wire, within: 2_048))
        let bundle = try XCTUnwrap(ExtensionViewIDTransport.splitRequest(&request))
        XCTAssertGreaterThan(bundle.count, ExtensionViewIDTransport.chunkBytes)
        XCTAssertNil(request["viewIDs"])
        XCTAssertNil((request["poppedFrame"] as? [String: Any])?["viewIDs"])
        XCTAssertEqual((request["viewRoute"] as? [[String: Any]])?.first?["query"] as? String, "root")
        XCTAssertEqual((try JSONSerialization.jsonObject(with: bundle) as? [[[Any]]])?.map(\.count), [64, 64, 64])
        request["query"] = String(repeating: "x", count: 2_049)
        request["viewIDs"] = entries
        XCTAssertFalse(ExtensionViewIDTransport.requestBaseFits(try JSONSerialization.data(withJSONObject: request), within: 2_048))
    }

    func testViewIDTransportRejectsMalformedOrOversizedSnapshots() throws {
        XCTAssertThrowsError(try ExtensionViewIDTransport.validateSnapshot([[true, "id"]]))
        XCTAssertThrowsError(try ExtensionViewIDTransport.validateSnapshot([[0, "a"], [0, "b"]]))
        XCTAssertThrowsError(try ExtensionViewIDTransport.validateSnapshot([[ExtensionViewIDTransport.mountSeedSlot, "bad"]]))
        XCTAssertThrowsError(try ExtensionViewIDTransport.validateSnapshot((0..<40).map { [$0, String(repeating: "x", count: 256)] as [Any] }))
    }
}
