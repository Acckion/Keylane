import XCTest
import CryptoKit
import zlib
@testable import KeylaneCore

final class RaycastStoreDependencyArchiveTests: XCTestCase {
    private let manifest = Data(#"{"name":"fixture","version":"1.0.0","main":"lib/index.js"}"#.utf8)
    private func tar(_ entries: [(String, Data, UInt8)]) -> Data {
        var result = Data()
        for (path, bytes, type) in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ at: Int, _ text: String) { header.replaceSubrange(at..<at + text.utf8.count, with: text.utf8) }
            field(0, path); field(100, "0000644"); field(124, String(format: "%011o", bytes.count)); header[156] = type
            field(257, "ustar"); field(263, "00")
            header.replaceSubrange(148..<156, with: repeatElement(32, count: 8))
            field(148, String(format: "%06o\0 ", header.reduce(0) { $0 + Int($1) }))
            result.append(contentsOf: header); result.append(bytes)
            result.append(Data(repeating: 0, count: (512 - bytes.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1024)); return result
    }
    private func gzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        XCTAssertEqual(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)), Z_OK)
        defer { deflateEnd(&stream) }
        var output = Data(count: input.count + 4096); let capacity = output.count
        let written = input.withUnsafeBytes { source in output.withUnsafeMutableBytes { destination -> Int in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress); stream.avail_in = uInt(input.count)
            stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(capacity)
            XCTAssertEqual(deflate(&stream, Z_FINISH), Z_STREAM_END)
            return capacity - Int(stream.avail_out)
        } }
        output.count = written; return output
    }
    private func node(_ bytes: Data, declarations: [String: Any] = [:],
                      productionNodes: [String: String] = [:]) throws -> RaycastStoreDependencyPlan.Node {
        let entry: [String: Any] = [
            "version": "1.0.0", "resolved": "https://registry.npmjs.org/fixture/-/fixture-1.0.0.tgz",
            "integrity": "sha512-" + Data(SHA512.hash(data: bytes)).base64EncodedString()
        ]
        var packages: [String: [String: Any]] = [
            "": [:], "node_modules/fixture": entry.merging(declarations) { _, new in new }
        ]
        for (name, version) in productionNodes { packages["node_modules/" + name] = ["version": version] }
        let json: [String: Any] = ["lockfileVersion": 3, "packages": packages]
        return try XCTUnwrap(RaycastStoreDependencyPlan(lockJSON: JSONSerialization.data(withJSONObject: json))
            .nodes.first { $0.path == "node_modules/fixture" })
    }
    private func validate(_ entries: [(String, Data, UInt8)]) throws -> RaycastStoreDependencyArchive {
        let bytes = try gzip(tar(entries)); return try .init(tarball: bytes, node: node(bytes))
    }
    func testInertFilesAndLockedLocation() throws {
        let archive = try validate([("package/package.json", manifest, 48), ("package/lib/index.js", Data("export default 1".utf8), 48)])
        XCTAssertEqual(archive.installationPath, "node_modules/fixture")
        XCTAssertEqual(archive.files.count, 2)
    }
    func testIntegrityPrecedesDecompression() throws {
        let bytes = Data("not gzip".utf8)
        XCTAssertThrowsError(try RaycastStoreDependencyArchive(tarball: bytes, node: node(Data("other".utf8)))) { XCTAssertEqual($0 as? RaycastStoreDependencyArchive.Failure, .integrity) }
    }
    func testDarwinArchiveRequiresMatchingPlatformAndStillBlocksNativeBuilds() throws {
        let manifest = Data(#"{"name":"fixture","version":"1.0.0","main":"index.js","os":["darwin"],"cpu":["arm64"]}"#.utf8)
        let bytes = try gzip(tar([("package/package.json",manifest,48),("package/index.js",Data("export default 42".utf8),48)]))
        func selected(native: Bool) throws -> RaycastStoreDependencyPlan.Node {
            let json: [String:Any] = ["lockfileVersion":3,"packages":["":[:],"node_modules/fixture":[
                "version":"1.0.0","resolved":"https://registry.npmjs.org/fixture/-/fixture-1.0.0.tgz",
                "integrity":"sha512-"+Data(SHA512.hash(data:bytes)).base64EncodedString(),"os":["darwin"],"cpu":["arm64"],"gypfile":native]]]
            return try XCTUnwrap(RaycastStoreDependencyPlan(lockJSON:JSONSerialization.data(withJSONObject:json)).nodes.first)
        }
        let archive = try RaycastStoreDependencyArchive(tarball:bytes,node:selected(native:false),target:.macOSArm64)
        XCTAssertEqual(archive.files["index.js"],Data("export default 42".utf8))
        XCTAssertThrowsError(try RaycastStoreDependencyArchive(tarball:bytes,node:selected(native:false),target:.linuxArm64))
        XCTAssertThrowsError(try RaycastStoreDependencyArchive(tarball:bytes,node:selected(native:true),target:.macOSArm64))
    }
    func testTraversalLinksSpecialEntriesAndCollisionsReject() throws {
        for (path, type): (String, UInt8) in [("package/../escape",48),("/absolute",48),("package/x",50),("package/x",49),("package/x",51),("package/x",120),("package/a\\b",48)] {
            XCTAssertThrowsError(try validate([("package/package.json", manifest, 48), (path, Data(), type)]))
        }
        XCTAssertThrowsError(try validate([("package/package.json",manifest,48),("package/Package.json",manifest,48)]))
        XCTAssertThrowsError(try validate([("package/package.json",manifest,48),("package/a",Data(),48),("package/a/b",Data(),48)]))
    }
    func testNativeAndInstallHooksAndIdentityReject() throws {
        for path in ["package/binding.gyp", "package/x.node", "package/node_modules/x/index.js"] {
            XCTAssertThrowsError(try validate([("package/package.json",manifest,48),(path,Data(),48)]))
        }
        XCTAssertThrowsError(try validate([("package/package.json",manifest,48),("package/disguised",Data([0x7f,0x45,0x4c,0x46]),48)]))
        for json in [#"{"name":"other","version":"1.0.0"}"#, #"{"name":"fixture","version":"2.0.0"}"#, #"{"name":"fixture","version":"1.0.0","scripts":{"install":"bad"}}"#] {
            XCTAssertThrowsError(try validate([("package/package.json",Data(json.utf8),48)]))
        }
    }
    func testGzipTrailersTruncatedTarChecksumAndExpansionLimitReject() throws {
        let good = tar([("package/package.json",manifest,48)])
        var corrupt = good; corrupt[0] ^= 1
        for raw in [Data(good.dropLast(512)), corrupt, Data(repeating: 0, count: 32 * 1024 * 1024 + 512)] {
            let bytes = try gzip(raw)
            XCTAssertThrowsError(try RaycastStoreDependencyArchive(tarball: bytes, node: node(bytes)))
        }
        let bytes = try gzip(good) + Data([0])
        XCTAssertThrowsError(try RaycastStoreDependencyArchive(tarball: bytes, node: node(bytes)))
    }
    func testEntryAndFileLimitsAndPreparePolicy() throws {
        let many = (0..<4097).map { ("package/f\($0)", Data(), UInt8(48)) }
        XCTAssertThrowsError(try validate(many))
        XCTAssertThrowsError(try validate([("package/package.json",manifest,48),("package/big",Data(repeating: 0, count: 8 * 1024 * 1024 + 1),48)]))
        let prepare = Data(#"{"name":"fixture","version":"1.0.0","scripts":{"prepare":"fixture-only"}}"#.utf8)
        let archived = try validate([("package/package.json",prepare,48),("package/index.js",Data("export default 1".utf8),48)])
        XCTAssertTrue(archived.hasInertPrepareMetadata)
        XCTAssertThrowsError(try validate([("package/package.json",prepare,48)])) { XCTAssertEqual($0 as? RaycastStoreDependencyArchive.Failure, .runtimeEntry) }
        XCTAssertThrowsError(try validate([("package/package.json",manifest,48),("package/A",Data(),48),("package/a/b",Data(),48)]))
    }

    func testConcreteExportsExistAndUnsupportedResolutionFailsClosed() throws {
        let good = Data(#"{"name":"fixture","version":"1.0.0","exports":{".":{"import":"./index.js","require":"./index.cjs"}}}"#.utf8)
        let entries: [(String, Data, UInt8)] = [("package/package.json",good,48),("package/index.js",Data(),48),("package/index.cjs",Data(),48)]
        XCTAssertNoThrow(try validate(entries))
        XCTAssertThrowsError(try validate(Array(entries.dropLast())))
        let wildcard = Data(#"{"name":"fixture","version":"1.0.0","exports":{"./*":"./lib/*.js"}}"#.utf8)
        XCTAssertThrowsError(try validate([("package/package.json",wildcard,48)]))
    }


    func testArchiveMatchesNormalizedProductionOptionalAndPeerDeclarations() throws {
        let common: [String: Any] = [
            "dependencies": ["production": "^1.0.0"],
            "optionalDependencies": ["soft": "^2.0.0"],
            "peerDependencies": ["peer": "^3.0.0"],
            "peerDependenciesMeta": ["peer": ["optional": true]]
        ]
        // The package repeats an optional dependency in dependencies, unlike
        // its normalized lock entry. Its development declaration is inert.
        let matching = common.merging([
            "name": "fixture", "version": "1.0.0",
            "dependencies": ["production": "^1.0.0", "soft": "^9.0.0"],
            "devDependencies": ["unlocked": "1.0.0"]
        ]) { _, new in new }
        func archive(_ manifest: [String: Any]) throws -> RaycastStoreDependencyArchive {
            let bytes = try gzip(tar([
                ("package/package.json", JSONSerialization.data(withJSONObject: manifest), 48),
                ("package/index.js", Data("export default 1".utf8), 48)
            ]))
            return try .init(tarball: bytes, node: node(bytes, declarations: common, productionNodes: ["production": "1.0.0"]), target: .macOSArm64)
        }
        XCTAssertNoThrow(try archive(matching))
        let mismatches: [[String: Any]] = [
            ["dependencies": ["production": "^2.0.0"]],
            ["dependencies": ["production": "^1.0.0", "additional": "1.0.0"]],
            ["dependencies": [:] as [String: String]],
            ["optionalDependencies": ["soft": "^9.0.0"]],
            ["peerDependencies": ["peer": "^4.0.0"]],
            ["peerDependenciesMeta": ["peer": ["optional": false]]],
            ["peerDependenciesMeta": [:] as [String: Any]]
        ]
        for change in mismatches {
            XCTAssertThrowsError(try archive(matching.merging(change) { _, new in new })) {
                XCTAssertEqual($0 as? RaycastStoreDependencyArchive.Failure, .dependencyLockMismatch)
            }
        }
    }

    func testBuildProjectRejectsTransitiveManifestDisagreementEvenWithMatchingArchiveDigest() throws {
        let dependency = try gzip(tar([
            ("package/package.json", Data(#"{"name":"b","version":"1.0.0"}"#.utf8), 48),
            ("package/index.js", Data("export default 1".utf8), 48)
        ]))
        let package = try gzip(tar([
            ("package/package.json", Data(#"{"name":"fixture","version":"1.0.0","dependencies":{"b":"^2.0.0"}}"#.utf8), 48),
            ("package/index.js", Data("export default 42".utf8), 48)
        ]))
        func locked(_ name: String, _ bytes: Data) -> [String: Any] {
            ["version": "1.0.0", "resolved": "https://registry.npmjs.org/\(name)/-/\(name)-1.0.0.tgz",
             "integrity": "sha512-" + Data(SHA512.hash(data: bytes)).base64EncodedString()]
        }
        let a = locked("fixture", package).merging(["dependencies": ["b": "^1.0.0"]]) { _, new in new }
        let lock: [String: Any] = ["lockfileVersion": 3, "packages": [
            "": ["dependencies": ["fixture": "1.0.0"]], "node_modules/fixture": a, "node_modules/b": locked("b", dependency)
        ]]
        let source = try projectSource(tarball: package, additional: ["package-lock.json": JSONSerialization.data(withJSONObject: lock)])
        XCTAssertThrowsError(try RaycastStoreBuildProject(source: source, supportedRuntimeAPIVersions: [],
            tarballs: ["node_modules/fixture": package, "node_modules/b": dependency], target: .macOSArm64)) {
            XCTAssertEqual($0 as? RaycastStoreDependencyArchive.Failure, .dependencyLockMismatch)
        }
    }

    private func projectSource(tarball: Data, additional: [String: Data] = [:]) throws -> RaycastStoreSourcePackage {
        let revision = String(repeating: "a", count: 40)
        let source = try RaycastStoreSource(slug: "staged-fixture", catalog: .init(revision: revision, slugs: ["staged-fixture"]))
        let lock: [String: Any] = ["lockfileVersion": 3, "packages": [
            "": ["dependencies": ["fixture": "1.0.0"]],
            "node_modules/fixture": ["version": "1.0.0", "resolved": "https://registry.npmjs.org/fixture/-/fixture-1.0.0.tgz",
                "integrity": "sha512-" + Data(SHA512.hash(data: tarball)).base64EncodedString()]
        ]]
        let files = [
            "package.json": Data(#"{"name":"staged-fixture","title":"Stage","commands":[{"name":"entry","title":"Entry","mode":"no-view"}],"dependencies":{"fixture":"1.0.0"},"scripts":{"install":"must never execute"}}"#.utf8),
            "package-lock.json": try JSONSerialization.data(withJSONObject: lock),
            "src/entry.ts": Data("export default () => 1".utf8)
        ].merging(additional) { _, new in new }
        let directories = Set(files.keys.flatMap { path in
            var parts = path.split(separator: "/").dropLast(), result: [String] = []
            while !parts.isEmpty {
                result.append(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
            return result
        })
        let tree = files.map { path, body -> [String: Any] in
            let digest = Insecure.SHA1.hash(data: Data("blob \(body.count)\0".utf8) + body).map { String(format: "%02x", $0) }.joined()
            return ["type": "blob", "mode": "100644", "path": path, "size": body.count, "sha": digest]
        } + directories.map { ["type": "tree", "mode": "040000", "path": $0, "sha": revision] }
        let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: revision,
          recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha": revision, "truncated": false, "tree": tree]))
        return try .init(snapshot: snapshot, files: files)
    }

    func testBuildProjectKeepsPinnedPackageAndNoticeAsOrderedInertFiles() throws {
        let ownNotice = Data("Fixture license".utf8)
        let bytes = try gzip(tar([
            ("package/package.json", manifest, 48), ("package/lib/index.js", Data("export default 42".utf8), 48),
            ("package/LICENSE", ownNotice, 48)
        ]))
        let source = try projectSource(tarball: bytes)
        let project = try RaycastStoreBuildProject(source: source, supportedRuntimeAPIVersions: [],
                                                  tarballs: ["node_modules/fixture": bytes])
        let paths = project.files.map(\.path)
        XCTAssertEqual(paths, paths.sorted())
        XCTAssertEqual(project.files.first { $0.path == "node_modules/fixture/LICENSE" }?.body, ownNotice)
        XCTAssertEqual(project.files.first { $0.path == "package.json" }?.body, source.files["package.json"])
        XCTAssertNil(project.runtimeAPIVersion)
    }

    func testBuildProjectRejectsMissingExtraChangedArchivesAndPathAliases() throws {
        let bytes = try gzip(tar([("package/package.json", manifest, 48), ("package/lib/index.js", Data(), 48)]))
        let source = try projectSource(tarball: bytes)
        for candidates in [[:], ["node_modules/fixture": bytes, "node_modules/not-locked": bytes],
                           ["node_modules/fixture": Data("bad".utf8)]] {
            XCTAssertThrowsError(try RaycastStoreBuildProject(source: source, supportedRuntimeAPIVersions: [], tarballs: candidates))
        }
        for path in ["node_modules/extra/index.js", "src/bad path.ts", "src/-unsafe.ts"] {
            let aliased = try projectSource(tarball: bytes, additional: [path: Data()])
            XCTAssertThrowsError(try RaycastStoreBuildProject(source: aliased, supportedRuntimeAPIVersions: [],
                                                             tarballs: ["node_modules/fixture": bytes]))
        }
        let caseAliases = try gzip(tar([("package/package.json", manifest, 48), ("package/lib/index.js", Data(), 48),
                                       ("package/Lib/other.js", Data(), 48)]))
        let conflicting = try projectSource(tarball: caseAliases)
        XCTAssertThrowsError(try RaycastStoreBuildProject(source: conflicting, supportedRuntimeAPIVersions: [],
                                                         tarballs: ["node_modules/fixture": caseAliases])) {
            XCTAssertEqual($0 as? RaycastStoreBuildProject.Failure, .conflictingPath)
        }
    }

}
