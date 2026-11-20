import CryptoKit
import XCTest
@testable import KeylaneCore

final class RaycastStoreSourcePackageTests: XCTestCase {
    private func snapshot(_ files: [String: Data]) throws -> RaycastStoreSnapshot {
        let sha = String(repeating: "a", count: 40)
        let source = try RaycastStoreSource(slug: "not-a-preselected-sample", catalog: .init(revision: sha, slugs: ["not-a-preselected-sample"]))
        let entries: [[String: Any]] = files.map { path, bytes in
            let digest = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes).map { String(format: "%02x", $0) }.joined()
            return ["path": path, "sha": digest, "size": bytes.count, "mode": "100644", "type": "blob"]
        }
        return try .init(source: source, treeSHA: sha, recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha": sha, "truncated": false, "tree": entries]))
    }
    private var manifest: Data {
        Data(#"{"name":"fixture","title":"Fixture","author":"tests","license":"MIT","commands":[{"name":"hello","title":"Hello","mode":"no-view"}],"scripts":{"postinstall":"exit 99"}}"#.utf8)
    }
    func testOriginalSourceScriptsAndLicenseArePreservedOnlyAsData() throws {
        let files = ["package.json": manifest, "LICENSE": Data("fixture license attribution".utf8)]
        let package = try RaycastStoreSourcePackage(snapshot: snapshot(files), files: files)
        XCTAssertEqual(package.files, files)
        XCTAssertEqual(package.metadata.license, "MIT")
        XCTAssertEqual(package.licensePaths, ["LICENSE"])
        XCTAssertEqual(package.source.slug, "not-a-preselected-sample")
    }
    func testMissingAndExtraFilesAreRejected() throws {
        let files = ["package.json": manifest], inventory = try snapshot(files)
        XCTAssertThrowsError(try RaycastStoreSourcePackage(snapshot: inventory, files: [:]))
        XCTAssertThrowsError(try RaycastStoreSourcePackage(snapshot: inventory, files: files.merging(["extra": Data()]) { $1 }))
    }
    func testModifiedManifestIsRejectedBeforeParsing() throws {
        let files = ["package.json": manifest]
        XCTAssertThrowsError(try RaycastStoreSourcePackage(snapshot: snapshot(files), files: ["package.json": Data("{}".utf8)]))
    }
    func testDependenciesNeedCommittedLockMetadata() throws {
        let data = Data(#"{"name":"fixture","title":"Fixture","commands":[{"name":"hello","title":"Hello","mode":"view"}],"dependencies":{"example":"^1.0.0"}}"#.utf8)
        var files = ["package.json": data]
        XCTAssertThrowsError(try RaycastStoreSourcePackage(snapshot: snapshot(files), files: files)) { error in
            XCTAssertEqual(error as? RaycastStoreSourcePackage.Failure, .missingDependencyLock)
        }
        files["package-lock.json"] = Data(#"{"lockfileVersion":true}"#.utf8)
        XCTAssertThrowsError(try RaycastStoreSourcePackage(snapshot: snapshot(files), files: files))
        files["package-lock.json"] = Data(#"{"lockfileVersion":3,"packages":{}}"#.utf8)
        XCTAssertNoThrow(try RaycastStoreSourcePackage(snapshot: snapshot(files), files: files))
    }
    func testDuplicateCommandsAreNotAdmittedAsAnInstallPlan() throws {
        let files = ["package.json": Data(#"{"name":"fixture","title":"Fixture","commands":[{"name":"same","title":"One","mode":"view"},{"name":"same","title":"Two","mode":"view"}]}"#.utf8)]
        XCTAssertThrowsError(try RaycastStoreSourcePackage(snapshot: snapshot(files), files: files))
    }

    func testPlatformDefaultsToMacOSButWindowsOnlyRemainsBrowseable() throws {
        let variants: [(String, Bool)] = [("", true), (#","platforms":["macOS","Windows"]"#, true), (#","platforms":["Windows"]"#, false), (#","platforms":[] "#, false)]
        for (suffix, supported) in variants {
            let json = String(decoding: manifest.dropLast(), as: UTF8.self) + suffix + "}"
            let bytes = Data(json.utf8)
            let detail = try JSONDecoder().decode(RaycastPublicCatalog.Details.self, from: bytes)
            XCTAssertEqual(detail.supportsMacOS, supported)
            let packageFiles = ["package.json": bytes]
            if supported {
                XCTAssertNoThrow(try RaycastStoreSourcePackage(snapshot: snapshot(packageFiles), files: packageFiles))
            } else {
                XCTAssertThrowsError(try RaycastStoreSourcePackage(snapshot: snapshot(packageFiles), files: packageFiles)) {
                    XCTAssertEqual($0 as? RaycastStoreSourcePackage.Failure, .unsupportedPlatform)
                }
            }
        }
    }

}
