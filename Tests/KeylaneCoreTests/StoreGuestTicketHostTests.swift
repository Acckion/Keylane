import Foundation
import XCTest
@testable import KeylaneCore

final class StoreGuestTicketHostTests: XCTestCase {
    @MainActor private final class Authority: StoreGuestTicketHost.Authority {
        var authorizedRequest: UUID?
        var watermark: UInt64 = 1
        var withinEffect = false
        func start(_ ticket: StoreGuestRunTicket, spawn: () throws -> any StoreGuestTicketHost.Process) throws -> any StoreGuestTicketHost.Process {
            guard ticket.installation.generation >= watermark else { throw StoreGuestTicketHost.Failure.denied }
            return try spawn()
        }
        func effect(_ ticket: StoreGuestRunTicket, capability: String, apply: () throws -> String) throws -> String {
            guard ticket.installation.generation >= watermark else { throw StoreGuestTicketHost.Failure.denied }
            withinEffect = true; defer { withinEffect = false }
            return try apply()
        }
        func authorizeRevocation(_ request: StoreGuestTicketHost.Revocation) throws {
            guard request.id == authorizedRequest else { throw StoreGuestTicketHost.Failure.denied }
            watermark = max(watermark, request.beforeGeneration)
        }
    }

    @MainActor private final class Channel: StoreGuestTicketHost.Process {
        var effect: (@MainActor (String, String) throws -> String)?
        var completion: CheckedContinuation<Void, Never>?
        var acknowledge = false
        var exit = false
        var delay: Duration?
        var stops = 0
        let ticketID: UUID
        init(_ ticketID: UUID) { self.ticketID = ticketID }
        func run(effect: @escaping @MainActor (String, String) throws -> String) async throws -> StoreGuestTicketHost.ExitEvidence {
            self.effect = effect
            await withCheckedContinuation { completion = $0 }
            return .init(ticketID: ticketID, authenticatedCompletion: acknowledge, helperExited: exit)
        }
        func finish() { completion?.resume(); completion = nil }
        func stop(_ request: StoreGuestTicketHost.Revocation, deadline: ContinuousClock.Instant) async throws -> StoreGuestTicketHost.StopEvidence {
            stops += 1
            XCTAssertThrowsError(try effect?("feedback.toast", "late")) // denied before transport suspension
            if let delay { try await Task.sleep(for: delay) }
            if acknowledge && exit { finish() }
            return .init(ticketID: ticketID, revocationID: request.id, acknowledged: acknowledge, helperExited: exit)
        }
    }

    @MainActor
    func testDriverSeamRequiresAtomicEffectsAuthenticatedRevocationAndPositiveStopEvidence() async throws {
        let profile = UUID()
        let installation = StoreRuntimeBridge.Installation(id: "synthetic", generation: 1)
        let receipt = StoreRuntimeBridge.Receipt(provenance: .init(installation: .init(id: installation.id, generation: 0),
            entry: "src/test.ts", projectDigest: String(repeating: "a", count: 64), runtimeDigest: String(repeating: "b", count: 64)),
            artifactDigest: String(repeating: "c", count: 64))
        let ticket = StoreGuestRunTicket(id: UUID(), profileID: profile, installation: installation, receipt: receipt,
            commandID: "fixture", capabilities: ["feedback.toast"], launchContext: .init(), liveLease: { true })
        let authority = Authority(), channel = Channel(ticket.id)
        var effects: [String] = [], spawns = 0
        let host = StoreGuestTicketHost(authority: authority, spawn: { _, _, supplied in
            XCTAssertEqual(supplied.id, ticket.id)
            spawns += 1
            return channel
        }, sink: { _, _, text in
            XCTAssertTrue(authority.withinEffect)
            effects.append(text)
            return text
        })
        let resources = StoreSignedGuestEngine.Resources(kernelURL: URL(fileURLWithPath: "/inert/Image"),
            ramdiskURL: URL(fileURLWithPath: "/inert/init"), digest: receipt.provenance.runtimeDigest, recipeIdentifier: "test")
        let legacy = StoreGuestProcessDriver(teamIdentifier: "fixture", isCurrent: { _ in false }, grants: { _ in [] }) { _, _, _ in "" }
        XCTAssertFalse(legacy.supportsTicketedLaunch)
        let driver = StoreGuestProcessDriver(teamIdentifier: "fixture", ticketHost: host)
        XCTAssertTrue(driver.supportsTicketedLaunch)
        let task = Task { try await driver.runInFreshGuest(resources: resources, artifact: Data(), ticket: ticket) }
        defer { channel.finish(); task.cancel() }
        for _ in 0..<100 where channel.effect == nil { try await Task.sleep(for: .milliseconds(2)) }
        let effect = try XCTUnwrap(channel.effect)
        XCTAssertEqual(try effect("feedback.toast", "first"), "first")
        XCTAssertThrowsError(try effect("clipboard.copy", "not granted"))
        let request = StoreGuestTicketHost.Revocation(id: UUID(), profileID: profile, installationID: installation.id, beforeGeneration: 2)
        do { try await host.revoke(request, timeout: .milliseconds(100)); XCTFail("unauthenticated revoke") }
        catch { XCTAssertEqual(error as? StoreGuestTicketHost.Failure, .denied) }
        XCTAssertEqual(channel.stops, 0)

        authority.authorizedRequest = request.id
        channel.acknowledge = true
        do { try await host.revoke(request, timeout: .milliseconds(100)); XCTFail("ack without helper exit") }
        catch { XCTAssertEqual(error as? StoreGuestTicketHost.Failure, .stopUnconfirmed) }
        XCTAssertThrowsError(try effect("feedback.toast", "still denied"))
        channel.exit = true; channel.delay = .milliseconds(15)
        do { try await host.revoke(request, timeout: .milliseconds(1)); XCTFail("late proof") }
        catch { XCTAssertEqual(error as? StoreGuestTicketHost.Failure, .stopUnconfirmed) }
        channel.delay = nil
        try await host.revoke(request, timeout: .milliseconds(100))
        try await task.value
        XCTAssertEqual(channel.stops, 3)
        XCTAssertEqual(effects, ["first"])
        XCTAssertEqual(spawns, 1)
    }
}
