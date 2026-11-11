import AppKit

final class KeylaneReleaseCheck {
    static let releasesURL = URL(string: "https://github.com/Acckion/Keylane/releases")!
    private var checking = false

    func check() {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                let result = try await Self.latest()
                let installedVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                let installedBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
                let message: String
                if let installedVersion,
                   result.manifest.version.compare(installedVersion, options: .numeric) == .orderedDescending ||
                    (result.manifest.version == installedVersion && installedBuild.map { $0 < result.manifest.build } == true) {
                    message = result.release.prerelease ? "有新的 Keylane 预发行版" : "有新的 Keylane 版本"
                } else if installedVersion != nil, installedBuild != nil {
                    message = "当前构建已是最新或更新"
                } else {
                    message = "最新的 Keylane 发布"
                }
                present(message, detail: "\(result.release.tag) · 构建 \(result.manifest.build)", url: result.release.url)
            } catch {
                present("无法检查 Keylane 更新", detail: error.localizedDescription, url: Self.releasesURL)
            }
        }
    }

    private struct Release: Decodable {
        let tag: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case draft, prerelease
        }

        var url: URL { KeylaneReleaseCheck.releasesURL.appendingPathComponent("tag").appendingPathComponent(tag) }
        var version: String { String(tag.dropFirst().prefix { $0 != "-" }) }
        var channel: Int { !prerelease ? 2 : (tag.contains("-beta") ? 1 : 0) }
        var supported: Bool {
            !draft && tag.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)(?:\.[0-9]+)?)?$"#,
                                options: .regularExpression) != nil
        }
    }

    private struct Manifest: Decodable {
        let version: String
        let build: Int
    }

    private static func latest() async throws -> (release: Release, manifest: Manifest) {
        let endpoint = URL(string: "https://api.github.com/repos/Acckion/Keylane/releases?per_page=30")!
        let releases: [Release] = try await get(endpoint)
        // Read the tagged manifest so builds sharing a marketing version can be compared.
        let latest = releases.filter(\.supported).max { lhs, rhs in
            let versions = lhs.version.compare(rhs.version, options: .numeric)
            if versions != .orderedSame { return versions == .orderedAscending }
            if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
            return lhs.tag.compare(rhs.tag, options: .numeric) == .orderedAscending
        }
        guard let release = latest else {
            throw URLError(.resourceUnavailable)
        }
        let root = URL(string: "https://raw.githubusercontent.com/Acckion/Keylane")!
        let manifest: Manifest = try await get(root.appendingPathComponent(release.tag).appendingPathComponent("version.json"))
        guard manifest.version == release.version,
              manifest.build > 0 else { throw URLError(.cannotDecodeContentData) }
        return (release, manifest)
    }

    private static func get<Value: Decodable>(_ url: URL) async throws -> Value {
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    @MainActor private func present(_ message: String, detail: String, url: URL) {
        (NSApp.delegate as? Delegate)?.hideLauncher()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "查看发布页面")
        alert.addButton(withTitle: "关闭")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }
}
