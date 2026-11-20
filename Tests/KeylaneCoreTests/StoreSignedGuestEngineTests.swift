import CryptoKit
import Foundation
import XCTest
@testable import KeylaneCore

final class StoreSignedGuestEngineTests: XCTestCase {
    @MainActor
    private final class Driver: StoreSignedGuestEngine.Driver {
        var builds: [StoreSignedGuestEngine.Resources] = []
        var runs: [StoreSignedGuestEngine.Resources] = []
        func buildInFreshGuest(
            resources: StoreSignedGuestEngine.Resources, envelope: Data, entry: String
        ) async throws -> Data {
            builds.append(resources)
            return Data("artifact".utf8)
        }

        func runInFreshGuest(
            resources: StoreSignedGuestEngine.Resources, artifact: Data, receipt: StoreRuntimeBridge.Receipt,
            installation: StoreRuntimeBridge.Installation
        ) async throws {
            runs.append(resources)
        }
    }

    @MainActor
    func testChangedResourceSelectionAndArtifactDoNotReachDriver() async throws {
        let driver = Driver()
        var expected = String(repeating: "a", count: 64)
        let engine = StoreSignedGuestEngine(driver: driver) {
            .init(kernelURL: URL(fileURLWithPath: "/fixture/Image"),
                  ramdiskURL: URL(fileURLWithPath: "/fixture/ingress.cpio"),
                  digest: expected, recipeIdentifier: "test-api-1")
        }
        let installation = StoreRuntimeBridge.Installation(id: "fixture", generation: 1)
        let bridge = StoreRuntimeBridge(engine: engine) { _, _ in true }
        let built = try await bridge.prepare(installation: installation, entry: "src/test.ts",
                                              files: [.init(path: "src/test.ts", body: Data("input".utf8))])
        XCTAssertEqual(driver.builds.count, 1)
        try await bridge.run(artifact: built.artifact, expectedReceipt: built.receipt, installation: installation)
        XCTAssertEqual(driver.runs.count, 1)
        expected = String(repeating: "b", count: 64)
        do {
            try await engine.run(artifact: built.artifact, receipt: built.receipt, installation: installation)
            XCTFail("changed resources reached the guest driver")
        } catch StoreRuntimeBridge.Rejection.runtimeIdentity {}
        do {
            try await engine.run(artifact: Data("replacement".utf8), receipt: built.receipt, installation: installation)
            XCTFail("replacement reached the guest driver")
        } catch StoreRuntimeBridge.Rejection.artifactIdentity {}
        XCTAssertEqual(driver.runs.count, 1)
    }

    @MainActor
    func testUntrustedBundleFailsClosed() throws {
        let driver = Driver()
        let engine = StoreSignedGuestEngine(bundle: .main, trust: .init(
            signingIdentifier: "invalid.example.fixture", teamIdentifier: "INVALIDTEAM",
            recipeIdentifier: "test-api-1"), driver: driver)
        XCTAssertThrowsError(try engine.verifiedRuntimeDigest())
        XCTAssertTrue(driver.builds.isEmpty && driver.runs.isEmpty)
    }

    @MainActor
    func testInstalledProductionConstructorNeverFallsBackWhenNestedHelperIsAbsent() throws {
        let isolatedURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? FileManager.default.removeItem(at: isolatedURL) }
        let contents = isolatedURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "org.keylane.unsigned-test"],
                                                       format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let app = try XCTUnwrap(Bundle(url: isolatedURL))
        let driver = StoreGuestProcessDriver(teamIdentifier: "TESTONLY", isCurrent: { _ in false },
                                             grants: { _ in [] }) { _, _, _ in
            XCTFail("No installed helper; the broker must not run")
            return ""
        }
        XCTAssertThrowsError(try StoreSignedGuestEngine.installed(in: app, expectedTeam: "TESTONLY",
                                                                  recipeIdentifier: "test-only", driver: driver)) {
            XCTAssertEqual($0 as? StoreRuntimeBridge.Rejection, .runtimeIdentity)
        }
    }

}
