import Foundation
import XCTest
@testable import KeylaneCore

@MainActor
final class StoreRuntimeBridgeTests: XCTestCase {
    typealias Bridge = StoreRuntimeBridge

    private final class Engine: Bridge.IsolatedEngine {
        var identity = String(repeating: "a", count: 64)
        var result = Data("fake-built-data".utf8)
        var inputs: [Data] = []
        var launched: [Bridge.Installation] = []
        var duringBuild: () -> Void = {}

        func verifiedRuntimeDigest() throws -> String { identity }

        func build(projectEnvelope: Data, entry: String, runtimeDigest: String) async throws -> Data {
            inputs.append(projectEnvelope)
            duringBuild()
            return result
        }

        func run(artifact: Data, receipt: Bridge.Receipt, installation: Bridge.Installation) async throws {
            launched.append(installation)
        }
    }

    private let staged = Bridge.Installation(id: "immutable-installation", generation: 0)
    private let enabled = Bridge.Installation(id: "immutable-installation", generation: 3)
    private let entry = Bridge.File(path: "src/entry.ts", body: Data("hello".utf8))

    func testDeterministicProjectAndCurrentGenerationDispatch() async throws {
        let engine = Engine()
        let bridge = Bridge(engine: engine) { [staged, enabled] current, operation in
            operation == .stagingBuild ? current == staged : current == enabled
        }
        let extra = Bridge.File(path: "package.json", body: Data("{}".utf8))
        let first = try await bridge.prepare(installation: staged, entry: entry.path, files: [entry, extra])
        let second = try await bridge.prepare(installation: staged, entry: entry.path, files: [extra, entry])
        XCTAssertEqual(first.receipt, second.receipt)
        let persisted = try JSONEncoder().encode(first.receipt)
        XCTAssertEqual(try JSONDecoder().decode(Bridge.Receipt.self, from: persisted), first.receipt)
        XCTAssertEqual(engine.inputs[0], engine.inputs[1])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: engine.inputs[0]) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        let files = try XCTUnwrap(object["files"] as? [[String: String]])
        XCTAssertEqual(files.map { $0["path"] }, ["package.json", "src/entry.ts"])
        XCTAssertEqual(files[1]["body"], "aGVsbG8=")
        XCTAssertEqual(files[1]["sha256"], "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        try await bridge.run(artifact: first.artifact, expectedReceipt: first.receipt, installation: enabled)
        XCTAssertEqual(engine.launched, [enabled])
    }

    func testRejectsTraversalAndAliasesBeforeBuild() async throws {
        let engine = Engine()
        let bridge = Bridge(engine: engine) { _, _ in true }
        for path in ["../entry.ts", "/entry.ts", "src//entry.ts", "src/./other", "SRC/ENTRY.TS", "src"] {
            do {
                _ = try await bridge.prepare(installation: staged, entry: entry.path, files: [entry, .init(path: path, body: Data())])
                XCTFail("accepted invalid path " + path)
            } catch { XCTAssertEqual(error as? Bridge.Rejection, .invalidProject) }
        }
        XCTAssertTrue(engine.inputs.isEmpty)
    }

    func testRevocationDuringBuildDiscardsReceipt() async throws {
        let engine = Engine()
        var active = true
        engine.duringBuild = { active = false }
        let bridge = Bridge(engine: engine) { _, _ in active }
        do {
            _ = try await bridge.prepare(installation: staged, entry: entry.path, files: [entry])
            XCTFail("minted receipt after revocation")
        } catch { XCTAssertEqual(error as? Bridge.Rejection, .staleInstallation) }
    }

    func testTamperingRuntimeChangesAndStaleGenerationsNeverLaunch() async throws {
        let engine = Engine()
        let bridge = Bridge(engine: engine) { [enabled] candidate, operation in
            operation == .stagingBuild || candidate == enabled
        }
        let built = try await bridge.prepare(installation: staged, entry: entry.path, files: [entry])
        let stale = Bridge.Installation(id: enabled.id, generation: enabled.generation - 1)
        do {
            try await bridge.run(artifact: built.artifact, expectedReceipt: built.receipt, installation: stale)
            XCTFail("launched revoked installation")
        } catch { XCTAssertEqual(error as? Bridge.Rejection, .staleInstallation) }
        do {
            try await bridge.run(artifact: Data("tampered".utf8), expectedReceipt: built.receipt, installation: enabled)
            XCTFail("launched mutated artifact")
        } catch { XCTAssertEqual(error as? Bridge.Rejection, .artifactIdentity) }
        engine.identity = String(repeating: "b", count: 64)
        do {
            try await bridge.run(artifact: built.artifact, expectedReceipt: built.receipt, installation: enabled)
            XCTFail("launched mismatched runtime")
        } catch { XCTAssertEqual(error as? Bridge.Rejection, .runtimeIdentity) }
        XCTAssertTrue(engine.launched.isEmpty)
    }
}
