import Foundation
import XCTest
@testable import KeylaneCore

private final class CatalogProtocol: URLProtocol {
    static var responses: [String: (Int, Data)] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.responses[request.url!.absoluteString] ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RaycastPublicCatalogTests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)
    private let tree = String(repeating: "b", count: 40)
    private let api = "https://api.github.com/repos/raycast/extensions"
    private func catalog() -> RaycastPublicCatalog {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogProtocol.self]
        return RaycastPublicCatalog(session: URLSession(configuration: config))
    }
    private func reply(_ url: String, _ json: String, code: Int = 200) {
        CatalogProtocol.responses[url] = (code, Data(json.utf8))
    }
    override func setUp() { CatalogProtocol.responses = [:] }

    func testEntireDirectoryNotFeaturedSubsetAndPinsImmutableRevision() async throws {
        reply(api + "/git/ref/heads/main", "{\"object\":{\"sha\":\"\(sha)\"}}")
        reply(api + "/git/trees/\(sha)", "{\"truncated\":false,\"tree\":[{\"path\":\"extensions\",\"type\":\"tree\",\"sha\":\"\(tree)\"}]}")
        let entries = (0..<2000).map { "{\"path\":\"any-extension-\($0)\",\"type\":\"tree\",\"sha\":\"\(sha)\"}" }
        reply(api + "/git/trees/\(tree)", "{\"truncated\":false,\"tree\":[\(entries.joined(separator: ","))]}")
        let index = try await catalog().loadIndex()
        XCTAssertEqual(index.slugs.count, 2000)
        XCTAssertEqual(index.revision, sha)
        XCTAssertTrue(index.slugs.contains("any-extension-1999"))
    }

    func testRejectsTruncatedDirectoryRatherThanPresentingPartialSuccess() async {
        reply(api + "/git/ref/heads/main", "{\"object\":{\"sha\":\"\(sha)\"}}")
        reply(api + "/git/trees/\(sha)", "{\"truncated\":true,\"tree\":[]}")
        do { _ = try await catalog().loadIndex(); XCTFail("Accepted truncated tree") }
        catch RaycastPublicCatalog.Failure.malformedIndex {} catch { XCTFail("\(error)") }
    }

    func testResolvesPinnedSubtreeAndVerifiesBytesBeforeHandingToBuilder() async throws {
        let subtree = String(repeating: "c", count: 40)
        reply(api + "/git/trees/\(sha)", "{\"truncated\":false,\"tree\":[{\"path\":\"extensions\",\"type\":\"tree\",\"sha\":\"\(tree)\"}]}")
        reply(api + "/git/trees/\(tree)", "{\"truncated\":false,\"tree\":[{\"path\":\"fresh-extension\",\"type\":\"tree\",\"sha\":\"\(subtree)\"}]}")
        reply(api + "/git/trees/\(subtree)?recursive=1", "{\"sha\":\"\(subtree)\",\"truncated\":false,\"tree\":[{\"path\":\"package.json\",\"type\":\"blob\",\"mode\":\"100644\",\"sha\":\"e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\",\"size\":0}]}")
        let source = try RaycastStoreSource(slug: "fresh-extension", catalog: .init(revision: sha, slugs: ["fresh-extension"]))
        let service = catalog()
        let snapshot = try await service.loadSnapshot(source)
        reply(source.manifestURL.absoluteString, "")
        let empty = try await service.loadSourceFile("package.json", from: snapshot)
        XCTAssertTrue(empty.isEmpty)
        reply(source.manifestURL.absoluteString, "tampered")
        do { _ = try await service.loadSourceFile("package.json", from: snapshot); XCTFail("Accepted altered content") }
        catch {}
        do { _ = try await service.loadSourceFile("../outside", from: snapshot); XCTFail("Accepted unlisted path") }
        catch {}
    }

    func testReportsRateLimit() async {
        reply(api + "/git/ref/heads/main", "{}", code: 429)
        do { _ = try await catalog().loadIndex(); XCTFail("Accepted rate limit") }
        catch RaycastPublicCatalog.Failure.rateLimited {} catch { XCTFail("\(error)") }
    }

    func testReadsNewExtensionMetadataWithoutExecutingScripts() async throws {
        reply("https://raw.githubusercontent.com/raycast/extensions/\(sha)/extensions/new-extension/package.json",
              #"{"title":"New","commands":[{"name":"hello","title":"Hello","mode":"no-view"}],"scripts":{"postinstall":"never execute me"}}"#)
        let details = try await catalog().loadDetails(slug: "new-extension", revision: sha)
        XCTAssertEqual(details.commands.first?.name, "hello")
    }
}
