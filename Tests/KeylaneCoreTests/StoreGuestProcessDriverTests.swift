import CryptoKit
import Foundation
import Security
import XCTest
@testable import KeylaneCore

final class StoreGuestProcessDriverTests: XCTestCase {
    @MainActor
    func testBrokerOnlyAllowsGrantedToastWhileGenerationCurrent() async throws {
        let sessionID = UUID()
        var currentGeneration: UInt64 = 8
        let installation = StoreRuntimeBridge.Installation(id: "fixture", generation: 8)
        var calls = 0
        let broker = StoreGuestProcessDriver.Broker(id: sessionID, installation: installation,
            isCurrent: { $0.generation == currentGeneration }, grants: [.toast]) { _, _, _ in
                calls += 1
                return "result"
            }
        func frame(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object.merging([
                "session": sessionID.uuidString, "generation": 1
            ]) { left, _ in left })
        }
        let stale = try broker.receive(frame(["kind": "hello", "versions": [1], "generation": 0]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: stale) as? [String: Any])?["kind"] as? String, "ignored-stale")
        _ = try broker.receive(frame(["kind": "hello", "versions": [1]]))
        let denied = try broker.receive(frame(["kind": "request", "version": 1, "requestID": 1,
                                                "capability": "clipboard.read", "text": "none"]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: denied) as? [String: Any])?["kind"] as? String, "denied")
        XCTAssertEqual(calls, 0)
        let toast = try frame(["kind": "request", "version": 1, "requestID": 2,
                               "capability": "feedback.toast", "text": "{}"])
        _ = try broker.receive(toast)
        XCTAssertEqual(calls, 1)
        currentGeneration = 9
        XCTAssertThrowsError(try broker.receive(toast)) { error in
            guard case StoreGuestProcessDriver.Failure.revoked = error else { return XCTFail("not revoked") }
        }
        XCTAssertEqual(calls, 1)
        XCTAssertThrowsError(try broker.finish())
    }

    @MainActor
    func testScopedPreferenceCopyAndHUDBrokerDoesNotRoutePasteOrNavigation() async throws {
        let sessionID = UUID()
        let installation = StoreRuntimeBridge.Installation(id: "synthetic", generation: 5)
        var current = true
        var copied: [String] = []
        var hud: [String] = []
        let context = StoreGuestLaunchContext(arguments: ["text": "synthetic"],
            ordinaryPreferences: ["mode": .text("copy"), "notice": .toggle(true), "count": .number(1)])
        let broker = StoreGuestProcessDriver.Broker(id: sessionID, installation: installation,
            isCurrent: { $0 == installation && current }, grants: [.preferencesRead, .clipboardCopy, .hud],
            ordinaryPreferences: try context.preferencesReply()) { id, capability, text in
                XCTAssertEqual(id, installation)
                switch capability {
                case .clipboardCopy: copied.append(text)
                case .hud: hud.append(text)
                default: XCTFail("unrequested app effect")
                }
                return ""
            }
        func frame(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value.merging([
                "session": sessionID.uuidString, "generation": 1
            ]) { left, _ in left })
        }
        func request(_ n: Int, _ capability: String, _ text: String) throws -> [String: Any] {
            let data = try broker.receive(frame(["kind": "request", "version": 1, "requestID": n,
                                                 "capability": capability, "text": text]))
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        _ = try broker.receive(frame(["kind": "hello", "versions": [1]]))
        XCTAssertEqual(try request(1, "preferences.read", "")["text"] as? String, try context.preferencesReply())
        XCTAssertEqual(try request(2, "clipboard.paste", "do not paste")["kind"] as? String, "denied")
        XCTAssertEqual(try request(3, "navigation.closeWindow", "{}")["kind"] as? String, "denied")
        XCTAssertEqual(try request(4, "clipboard.copy", "inert string")["kind"] as? String, "result")
        XCTAssertEqual(try request(5, "feedback.hud", #"{"text":"Done","clearRootSearch":true}"#)["kind"] as? String, "result")
        XCTAssertEqual(copied, ["inert string"])
        XCTAssertEqual(hud, ["Done"])
        current = false
        XCTAssertThrowsError(try request(6, "clipboard.copy", "revoked"))
        XCTAssertEqual(copied, ["inert string"])
    }

    @MainActor
    func testTicketChildKeepsSoleReaderWhenRevocationInterruptsBrokerReply() async throws {
        let id = UUID(), profile = UUID()
        let installation = StoreRuntimeBridge.Installation(id: "fixture", generation: 5)
        let digest = String(repeating: "a", count: 64)
        let receipt = StoreRuntimeBridge.Receipt(provenance: .init(installation: .init(id: installation.id, generation: 0),
            entry: "src/test.ts", projectDigest: digest, runtimeDigest: digest), artifactDigest: digest)
        let ticket = StoreGuestRunTicket(id: id, profileID: profile, installation: installation, receipt: receipt,
            commandID: "fixture", capabilities: ["feedback.toast"], launchContext: .init(), liveLease: { true })
        XCTAssertTrue(ticket.consumeForStart())
        let hello = try JSONSerialization.data(withJSONObject: ["kind":"hello", "session":id.uuidString, "generation":1, "versions":[1]])
        let late = try JSONSerialization.data(withJSONObject: ["kind":"request", "session":id.uuidString, "generation":1,
            "version":1, "requestID":1, "capability":"feedback.toast", "text":"late"])
        let proof = StoreGuestHelperStopProof.frame(session: id, outcome: .callerClosed)
        var reads = 0, halfCloses = 0, effects = 0
        var writer: CheckedContinuation<Void, Error>?
        let child = StoreGuestProcessDriver.TicketChild(ticket: ticket, envelope: Data([1]), io: .init(
            send: { XCTAssertEqual($0, Data([1])) },
            read: { reads += 1; return [hello, late, proof][reads - 1] },
            reply: { _ in try await withCheckedThrowingContinuation { writer = $0 } },
            halfClose: { halfCloses += 1; writer?.resume(throwing: StoreGuestProcessDriver.Failure.channel); writer = nil },
            prove: { frame, suppliedID, outcome in
                XCTAssertEqual(suppliedID, id)
                guard StoreGuestHelperStopProof.verify(frame, session: suppliedID, outcome: outcome,
                                                       helperExitedSuccessfully: true) else {
                    throw StoreGuestProcessDriver.Failure.childStopUnconfirmed
                }
            }))
        let run = Task { try await child.run { _, _ in effects += 1; return "" } }
        defer { writer?.resume(throwing: CancellationError()); run.cancel() }
        for _ in 0..<100 where writer == nil { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(writer)
        let bad = StoreGuestTicketHost.Revocation(id: UUID(), profileID: UUID(), installationID: installation.id, beforeGeneration: 6)
        do { _ = try await child.stop(bad, deadline: .now.advanced(by: .seconds(1))); XCTFail("wrong profile") }
        catch StoreGuestProcessDriver.Failure.revoked {}
        let stop = StoreGuestTicketHost.Revocation(id: UUID(), profileID: profile, installationID: installation.id, beforeGeneration: 6)
        let evidence = try await child.stop(stop, deadline: .now.advanced(by: .seconds(1)))
        XCTAssertEqual(evidence.revocationID, stop.id)
        XCTAssertEqual(evidence.ticketID, id)
        XCTAssertTrue(evidence.acknowledged && evidence.helperExited)
        let exit = try await run.value
        XCTAssertTrue(exit.authenticatedCompletion && exit.helperExited)
        XCTAssertEqual(halfCloses, 1)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(effects, 0)
    }

    func testExactChildCodeRejectsOtherSameTeamBinaryAndEarlyExit() throws {
        typealias Child = StoreGuestProcessDriver.Child
        let pinned = Data(repeating: 0x42, count: 20)
        let replacementSameTeamAndIdentifier = Data(repeating: 0x43, count: 20)
        let text = try Child.exactCodeRequirement(team: "TEAM01", expectedCode: pinned)
        let replacement = try Child.exactCodeRequirement(team: "TEAM01", expectedCode: replacementSameTeamAndIdentifier)
        XCTAssertEqual(text.components(separatedBy: " and cdhash ").first,
                       replacement.components(separatedBy: " and cdhash ").first)
        XCTAssertNotEqual(text, replacement)
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess)
        XCTAssertNotNil(requirement)
        XCTAssertTrue(Child.matchesCode(expected: pinned, observed: pinned, stillRunning: true))
        XCTAssertFalse(Child.matchesCode(expected: pinned, observed: replacementSameTeamAndIdentifier, stillRunning: true))
        XCTAssertFalse(Child.matchesCode(expected: pinned, observed: pinned, stillRunning: false))
        XCTAssertFalse(Child.matchesCode(expected: pinned, observed: nil, stillRunning: true))
        XCTAssertThrowsError(try Child.exactCodeRequirement(team: "TEAM01", expectedCode: Data()))
    }

    func testBoundedLaunchContextDoesNotEmbedPreferences() throws {
        let context = StoreGuestLaunchContext(arguments: ["input": "synthetic"],
            ordinaryPreferences: ["privateToBroker": .text("ordinary app default")])
        let data = try context.launchData(loadPreferences: true)
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(decoded["arguments"] as? [String: String], ["input": "synthetic"])
        XCTAssertEqual(decoded["loadPreferences"] as? Bool, true)
        XCTAssertNil(decoded["ordinaryPreferences"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("privateToBroker"))
        XCTAssertThrowsError(try StoreGuestLaunchContext(arguments: ["__proto__": "x"]).launchData(loadPreferences: false))
        XCTAssertThrowsError(try StoreGuestLaunchContext(arguments: ["input": String(repeating: "x", count: 1025)])
            .launchData(loadPreferences: false))
        XCTAssertThrowsError(try StoreGuestLaunchContext(ordinaryPreferences: ["x": .number(.infinity)]).preferencesReply())
    }

    @MainActor
    func testHelperUsesExactFilePathAndRejectsSymbolicLink() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("StorePath-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let contents = scratch.appendingPathComponent("Fixture.app/Contents")
        let kernel = contents.appendingPathComponent("Resources/Image")
        let ramdisk = contents.appendingPathComponent("Resources/ingress.cpio")
        let app = contents.appendingPathComponent("MacOS/KeylaneStoreGuest")
        try FileManager.default.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kernel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("inert test marker".utf8).write(to: app)
        let resources = StoreSignedGuestEngine.Resources(kernelURL: kernel, ramdiskURL: ramdisk,
                                                         digest: "unused", recipeIdentifier: "test")
        let actual = try StoreGuestProcessDriver.helperExecutable(resources: resources)
        XCTAssertEqual(actual.path, app.resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: app)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: URL(fileURLWithPath: "/bin/cat"))
        XCTAssertThrowsError(try StoreGuestProcessDriver.helperExecutable(resources: resources))
    }

    func testOwnedHelperChildCooperativeStopIsIndependentlyObserved() async throws {
        // Fixed first-party fixture command echoes stdin and awaits EOF. No
        // extension, hypervisor, other process or user data is involved.
        let child = try StoreGuestProcessDriver.Child(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        XCTAssertTrue(child.process.isRunning)
        try await Task.detached { try child.confirmStop() }.value
        XCTAssertFalse(child.process.isRunning)
        XCTAssertEqual(child.process.terminationStatus, 0)
    }

    @MainActor
    func testHelperOutputDigestIndependentlyVerified() async throws {
        let artifact = Data("test".utf8)
        let digest = SHA256.hash(data: artifact).map { String(format: "%02x", $0) }.joined()
        var parser = StoreGuestProcessDriver.ArtifactFrames()
        func frame(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertNil(try parser.consume(frame(["kind": "artifact-start", "bytes": 4, "sha256": digest])))
        XCTAssertNil(try parser.consume(frame(["kind": "artifact-chunk", "offset": 0, "body": artifact.base64EncodedString()])))
        XCTAssertThrowsError(try parser.consume(frame(["kind": "artifact-done", "sha256": String(repeating: "f", count: 64)])))
        XCTAssertEqual(try parser.consume(frame(["kind": "artifact-done", "sha256": digest])), artifact)
    }
}
