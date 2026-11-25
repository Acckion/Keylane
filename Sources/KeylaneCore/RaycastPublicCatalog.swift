import Foundation

/// Read-only directory and manifest metadata from the public source repository.
public struct RaycastPublicCatalog {
    public struct Index: Codable, Sendable {
        public let revision: String
        public let slugs: [String]

        public init(revision: String, slugs: [String]) {
            self.revision = revision
            self.slugs = slugs
        }
    }

    public struct Details: Decodable, Sendable {
        public struct Command: Decodable, Sendable {
            public let name: String
            public let title: String
            public let mode: String
        }

        public let title: String
        public let description: String?
        public let author: String?
        public let icon: String?
        public let keywords: [String]?
        public let license: String?
        public let platforms: [String]?
        /// The public Raycast manifest defaults to macOS only when the key is absent.
        public var supportsMacOS: Bool { RaycastPublicCatalog.declaresMacOS(platforms) }
        public let categories: [String]?
        public let commands: [Command]
    }

    public enum Failure: LocalizedError {
        case malformedIndex, unexpectedResponse, oversized, rateLimited

        public var errorDescription: String? {
            switch self {
            case .malformedIndex: return "GitHub 返回的扩展目录不完整。"
            case .unexpectedResponse: return "无法读取 Raycast 公开扩展资料。"
            case .oversized: return "扩展资料超过读取上限。"
            case .rateLimited: return "GitHub 暂时限制请求，请稍后刷新。"
            }
        }
    }

    private struct Reference: Decodable {
        struct Object: Decodable { let sha: String }
        let object: Object
    }

    private struct Tree: Decodable {
        struct Item: Decodable { let path: String; let type: String; let sha: String }
        let tree: [Item]
        let truncated: Bool
    }

    private let session: URLSession
    private static let api = URL(string: "https://api.github.com/repos/raycast/extensions")!
    private static let raw = URL(string: "https://raw.githubusercontent.com/raycast/extensions")!

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public init(session: URLSession = .shared) {
        let config = session.configuration
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func loadIndex() async throws -> Index {
        let ref: Reference = try await decode(Self.api.appendingPathComponent("git/ref/heads/main"), maxBytes: 32_768)
        let revision = ref.object.sha
        guard Self.isRevision(revision) else { throw Failure.malformedIndex }
        let root = try await tree(revision)
        guard let folder = root.tree.first(where: { $0.path == "extensions" && $0.type == "tree" }),
              Self.isRevision(folder.sha) else { throw Failure.malformedIndex }
        let directory = try await tree(folder.sha)
        let slugs = directory.tree.filter { $0.type == "tree" && Self.isSlug($0.path) }.map(\.path)
        guard !slugs.isEmpty else { throw Failure.malformedIndex }
        return Index(revision: revision, slugs: Array(Set(slugs)).sorted())
    }

    public func loadDetails(slug: String, revision: String) async throws -> Details {
        guard Self.isSlug(slug), Self.isRevision(revision) else { throw Failure.malformedIndex }
        let url = Self.raw.appendingPathComponent(revision).appendingPathComponent("extensions")
            .appendingPathComponent(slug).appendingPathComponent("package.json")
        return try await decode(url, maxBytes: 262_144)
    }

    public func loadIcon(slug: String, revision: String, name: String) async throws -> Data {
        guard Self.isSlug(slug), Self.isRevision(revision), Self.isSlug(name),
              name.lowercased().hasSuffix(".png") else { throw Failure.malformedIndex }
        let url = Self.raw.appendingPathComponent(revision).appendingPathComponent("extensions")
            .appendingPathComponent(slug).appendingPathComponent("assets").appendingPathComponent(name)
        return try await download(url, maxBytes: 2 * 1024 * 1024)
    }

    /// Resolve the extension subtree from the selected immutable official commit.
    /// This reads source bytes only; it never invokes npm or an extension entry point.
    public func loadSnapshot(_ source: RaycastStoreSource) async throws -> RaycastStoreSnapshot {
        if MacOSReviewedRaycastCommand.supports(source) {
            return try MacOSReviewedRaycastCommand.snapshot(for: source)
        }
        let root = try await tree(source.revision)
        guard let folder = root.tree.first(where: { $0.path == "extensions" && $0.type == "tree" }),
              Self.isRevision(folder.sha) else { throw Failure.malformedIndex }
        let directory = try await tree(folder.sha)
        guard let entry = directory.tree.first(where: { $0.path == source.slug && $0.type == "tree" }),
              Self.isRevision(entry.sha) else { throw Failure.malformedIndex }
        var components = URLComponents(url: Self.api.appendingPathComponent("git/trees")
            .appendingPathComponent(entry.sha), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let bytes = try await download(components.url!, maxBytes: 2 * 1024 * 1024)
        return try RaycastStoreSnapshot(source: source, treeSHA: entry.sha, recursiveTreeJSON: bytes)
    }

    public func loadSourceFile(_ path: String, from snapshot: RaycastStoreSnapshot) async throws -> Data {
        guard let file = snapshot.files.first(where: { $0.path == path }) else { throw Failure.malformedIndex }
        let url = path.split(separator: "/").reduce(snapshot.source.sourceURL) {
            $0.appendingPathComponent(String($1))
        }
        let bytes: Data
        do {
            bytes = try await download(url, maxBytes: file.byteCount)
        } catch Failure.rateLimited {
            guard path == "package.json", let cached = MacOSReviewedRaycastCommand.cachedManifest(for: snapshot.source)
            else { throw Failure.rateLimited }
            bytes = cached
        }
        guard file.verifies(bytes) else { throw Failure.unexpectedResponse }
        return bytes
    }

    /// Acquire build data after official source verification. URLs originate in
    /// the canonical lock projection, and the existing transport forbids redirects.
    /// The aggregate budget is applied before downloading each archive.
    public func prepareBuildProject(
        _ source: RaycastStoreSourcePackage, supportedRuntimeAPIVersions: Set<String>, target: RaycastStoreBuildDependencies.Target = .linuxArm64
    ) async throws -> RaycastStoreBuildProject {
        let selection = try RaycastStoreBuildDependencies(source: source, supportedRuntimeAPIVersions: supportedRuntimeAPIVersions, target: target)
        var archives: [String: Data] = [:], remaining = 32 * 1024 * 1024
        for node in selection.packages {
            try Task.checkCancellation()
            guard remaining > 0, let url = node.registryTarball else { throw Failure.oversized }
            let bytes = try await download(url, maxBytes: min(remaining, 16 * 1024 * 1024))
            guard node.verifiesTarball(bytes) else { throw RaycastStoreDependencyArchive.Failure.integrity }
            remaining -= bytes.count
            archives[node.path] = bytes
        }
        return try RaycastStoreBuildProject(source: source, supportedRuntimeAPIVersions: supportedRuntimeAPIVersions, tarballs: archives, target: target)
    }

    private func tree(_ sha: String) async throws -> Tree {
        let tree: Tree = try await decode(Self.api.appendingPathComponent("git/trees").appendingPathComponent(sha),
                                          maxBytes: 4 * 1024 * 1024)
        guard !tree.truncated else { throw Failure.malformedIndex }
        return tree
    }

    private func decode<Value: Decodable>(_ url: URL, maxBytes: Int) async throws -> Value {
        try JSONDecoder().decode(Value.self, from: await download(url, maxBytes: maxBytes))
    }

    private func download(_ url: URL, maxBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Keylane-Extension-Catalog", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url == url else { throw Failure.unexpectedResponse }
        if http.statusCode == 429 || (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            throw Failure.rateLimited
        }
        guard http.statusCode == 200 else { throw Failure.unexpectedResponse }
        guard http.expectedContentLength <= Int64(maxBytes) else { throw Failure.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxBytes else { throw Failure.oversized }
            data.append(byte)
        }
        return data
    }

    static func declaresMacOS(_ platforms: [String]?) -> Bool {
        platforms?.contains("macOS") ?? true
    }

    private static func isRevision(_ value: String) -> Bool {
        value.utf8.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func isSlug(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}
