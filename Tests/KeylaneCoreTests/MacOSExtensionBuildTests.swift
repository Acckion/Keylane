import Foundation
import XCTest
@testable import KeylaneCore

final class MacOSExtensionBuildTests: XCTestCase {
    typealias Build = MacOSExtensionBuild
    private func recipe(_ digit: String = "a") throws -> Build.Recipe {
        try .init(compilerSHA256: String(repeating: digit, count: 64), helperSHA256: String(repeating: "b", count: 64))
    }
    private func files() -> [Build.File] {
        [.init(path: "package.json", body: Data(#"{"name":"fixture"}"#.utf8)),
         .init(path: "src/main.ts", body: Data("globalThis.answer=42;".utf8)),
         .init(path: "assets/icon.txt", body: Data("fixture-only".utf8)),
         .init(path: "node_modules/example/LICENSE", body: Data("Synthetic license".utf8))]
    }
    private func plan() throws -> Build.Plan { try .init(files: files(), entries: ["src/main.ts"]) }
    private func request() throws -> Build.Request { try .init(recipe: recipe(), plan: plan()) }
    private func reply(_ request: Build.Request) throws -> Build.Reply {
        try .init(id: request.id, recipeDigest: request.recipe.digest, projectDigest: request.plan.digest,
                  commands: [.init(path: "src/main.ts", body: Data("(()=>{globalThis.answer=42})();".utf8))])
    }

    func testCanonicalPlanIgnoresInputOrderAndBindsAllBytes() throws {
        let first = try plan(), reverse = try Build.Plan(files: files().reversed(), entries: ["src/main.ts"])
        XCTAssertEqual(try first.digest, try reverse.digest)
        var changed = files(); changed[2] = .init(path: changed[2].path, body: Data("changed resource".utf8))
        XCTAssertNotEqual(try first.digest, try Build.Plan(files: changed, entries: first.entries).digest)
        let request = try request()
        XCTAssertEqual(try Build.Request.decode(request.encoded()).plan.digest, try first.digest)
    }

    func testPathsAliasesAndNativeBytesAreRejectedBeforeStaging() throws {
        for path in ["/absolute", "../outside", "src/../outside", "src//a.ts", "src/-x.ts", "src/a\\b", "src/é.ts", "src/a:b"] {
            XCTAssertThrowsError(try Build.Plan(files: files() + [.init(path: path, body: Data())], entries: ["src/main.ts"]))
        }
        for path in ["SRC/main.ts", "SRC/other.ts", "src", "assets/icon.txt/more"] {
            XCTAssertThrowsError(try Build.Plan(files: files() + [.init(path: path, body: Data())], entries: ["src/main.ts"]))
        }
        for (path, bytes) in [("src/a.node", Data()), ("src/fake.txt", Data([0xcf,0xfa,0xed,0xfe])),
                              ("node_modules/x/binding.gyp", Data()), ("assets/fake", Data([0x7f,0x45,0x4c,0x46]))] {
            XCTAssertThrowsError(try Build.Plan(files: files() + [.init(path: path, body: bytes)], entries: ["src/main.ts"]))
        }
    }

    func testHooksAreNotExecutableAndInstallHooksFailClosed() throws {
        for hook in ["preinstall", "install", "postinstall"] {
            var values = files(); values[0] = .init(path: "package.json", body: Data("{\"scripts\":{\"\(hook)\":\"touch marker\"}}".utf8))
            XCTAssertThrowsError(try Build.Plan(files: values, entries: ["src/main.ts"]))
        }
        var values = files(); values[0] = .init(path: "package.json", body: Data(#"{"scripts":{"prepare":"touch marker"}}"#.utf8))
        XCTAssertNoThrow(try Build.Plan(files: values, entries: ["src/main.ts"])) // inert published metadata
    }

    func testDecodeCannotBypassValidation() throws {
        let request = try request()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        var r = try XCTUnwrap(object["recipe"] as? [String: Any]); r["target"] = "linux-arm64"; object["recipe"] = r
        XCTAssertThrowsError(try Build.Request.decode(JSONSerialization.data(withJSONObject: object)))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        var p = try XCTUnwrap(object["plan"] as? [String: Any]); p["entries"] = ["../escape"]; object["plan"] = p
        XCTAssertThrowsError(try Build.Request.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try Build.Recipe(compilerSHA256: "bad", helperSHA256: String(repeating: "a", count: 64)))
    }

    func testMissingEntriesDuplicateEntriesAndOversizedFilesFailClosed() throws {
        for entries in [[], ["src/missing.ts"], ["package.json"], ["src/main.ts", "src/main.ts"]] {
            XCTAssertThrowsError(try Build.Plan(files: files(), entries: entries))
        }
        XCTAssertThrowsError(try Build.Plan(files: files().filter { $0.path != "package.json" }, entries: ["src/main.ts"]))
        XCTAssertThrowsError(try Build.Plan(files: files() + [.init(path: "assets/large", body: Data(count: 8 * 1024 * 1024 + 1))], entries: ["src/main.ts"]))
    }

    func testArtifactBindsRequestRecipeProjectCommandSetAndOriginalResources() throws {
        let r = try request(), good = try reply(r), artifact = try Build.Artifact(request: r, reply: good)
        XCTAssertEqual(artifact.resources.map(\.path), ["assets/icon.txt", "node_modules/example/LICENSE"])
        XCTAssertEqual(artifact.inventory.resources.map(\.sha256), artifact.resources.map { Build.hash($0.body) })
        for bad in [Build.Reply(id: UUID(), recipeDigest: good.recipeDigest, projectDigest: good.projectDigest, commands: good.commands),
                    Build.Reply(id: r.id, recipeDigest: String(repeating: "0", count: 64), projectDigest: good.projectDigest, commands: good.commands),
                    Build.Reply(id: r.id, recipeDigest: good.recipeDigest, projectDigest: String(repeating: "0", count: 64), commands: good.commands),
                    Build.Reply(id: r.id, recipeDigest: good.recipeDigest, projectDigest: good.projectDigest, commands: [.init(path: "src/other.ts", body: Data("x".utf8))]),
                    Build.Reply(id: r.id, recipeDigest: good.recipeDigest, projectDigest: good.projectDigest, commands: good.commands + good.commands)] {
            XCTAssertThrowsError(try Build.Artifact(request: r, reply: bad))
        }
        for bytes in [Data(), Data([0xff]), Data([65,0]), Data(repeating: 65, count: 4 * 1024 * 1024 + 1)] {
            XCTAssertThrowsError(try Build.Artifact(request: r, reply: .init(id: r.id, recipeDigest: good.recipeDigest, projectDigest: good.projectDigest, commands: [.init(path: "src/main.ts", body: bytes)])))
        }
        let changed = try Build.Artifact(request: r, reply: .init(id: r.id, recipeDigest: good.recipeDigest, projectDigest: good.projectDigest,
                                                                   commands: [.init(path: "src/main.ts", body: Data("other".utf8))]))
        XCTAssertNotEqual(try changed.digest, try artifact.digest)
    }

    private final class Service: Build.Service, @unchecked Sendable {
        let lock = NSLock()
        var recipe: Build.Recipe
        var calls = 0, cancelled = Set<UUID>()
        var operation: (@Sendable (Build.Request) async throws -> Build.Reply)?
        init(_ recipe: Build.Recipe) { self.recipe = recipe }
        func verifiedRecipe() throws -> Build.Recipe { lock.withLock { recipe } }
        func compile(_ request: Build.Request) async throws -> Build.Reply {
            let op = lock.withLock { calls += 1; return operation }
            if let op { return try await op(request) }
            return try .init(id: request.id, recipeDigest: request.recipe.digest, projectDigest: request.plan.digest,
                             commands: request.plan.entries.map { .init(path: $0, body: Data("compiled".utf8)) })
        }
        func cancel(_ id: UUID) { lock.withLock { _ = cancelled.insert(id) } }
    }

    func testCoordinatorChecksSourceAndToolchainAgainAfterAwait() async throws {
        let service = try Service(recipe()), coordinator = try Build.Coordinator(expected: recipe(), service: service)
        let result = try await coordinator.build(plan(), isCurrent: { true })
        XCTAssertEqual(result.commands.count, 1)
        do { _ = try await coordinator.build(plan(), isCurrent: { false }); XCTFail("stale input accepted") }
        catch { XCTAssertEqual(error as? Build.Failure, .stale) }
        XCTAssertEqual(service.calls, 1)
        let changed = try recipe("c")
        service.operation = { request in
            service.lock.withLock { service.recipe = changed }
            return try self.reply(request)
        }
        do { _ = try await coordinator.build(plan(), isCurrent: { true }); XCTFail("changed compiler accepted") }
        catch { XCTAssertEqual(error as? Build.Failure, .toolchainChanged) }
    }

    func testSourceInvalidatedDuringBuildCannotPublish() async throws {
        let service = try Service(recipe()), coordinator = try Build.Coordinator(expected: recipe(), service: service)
        final class Snapshot: @unchecked Sendable {
            let lock = NSLock(); var reads = 0
            func current() -> Bool { lock.withLock { reads += 1; return reads == 1 } }
        }
        let snapshot = Snapshot()
        do { _ = try await coordinator.build(plan(), isCurrent: { snapshot.current() }); XCTFail("old source published") }
        catch { XCTAssertEqual(error as? Build.Failure, .stale) }
        XCTAssertEqual(service.calls, 1)
        _ = try await coordinator.build(plan(), isCurrent: { true })
    }

    func testCancellationReachesOnlyCurrentRequestAndReleasesBusySlot() async throws {
        let service = try Service(recipe()), coordinator = try Build.Coordinator(expected: recipe(), service: service)
        service.operation = { _ in try await Task.sleep(for: .seconds(30)); throw CancellationError() }
        let p = try plan()
        let task = Task { try await coordinator.build(p, isCurrent: { true }) }
        while service.lock.withLock({ service.calls }) == 0 { await Task.yield() }
        do { _ = try await coordinator.build(p, isCurrent: { true }); XCTFail("concurrent build accepted") }
        catch { XCTAssertEqual(error as? Build.Failure, .busy) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancel ignored") } catch is CancellationError {}
        XCTAssertEqual(service.lock.withLock { service.cancelled.count }, 1)
        service.operation = nil
        _ = try await coordinator.build(p, isCurrent: { true })
    }
}
