import Foundation

public struct GitHubUpdateRelease: Decodable, Equatable {
    public let tag: String
    public let draft: Bool
    public let prerelease: Bool
    private let assets: [Asset]

    private struct Asset: Decodable, Equatable {
        let name: String
        let state: String
    }

    private enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case draft, prerelease, assets
    }

    public var version: String { String(tag.dropFirst().prefix { $0 != "-" }) }

    private var channel: Int {
        if tag.contains("-alpha") { return 0 }
        if tag.contains("-beta") { return 1 }
        return 2
    }

    public var imageName: String { "Keylane-\(version)-macos-arm64.dmg" }
    public var checksumName: String { imageName + ".sha256" }

    public static func latest(in releases: [Self], includePrereleases: Bool) -> Self? {
        releases.filter { release in
            guard !release.draft,
                  release.tag.range(of: #"^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:alpha|beta)(?:\.[1-9][0-9]*)?)?$"#,
                                    options: .regularExpression) != nil,
                  release.prerelease == (release.channel != 2),
                  includePrereleases || !release.prerelease else { return false }
            let names = Set(release.assets.filter { $0.state == "uploaded" }.map(\.name))
            return names.contains(release.imageName) && names.contains(release.checksumName)
        }.max { lhs, rhs in
            let versions = lhs.version.compare(rhs.version, options: .numeric)
            if versions != .orderedSame { return versions == .orderedAscending }
            if lhs.channel != rhs.channel { return lhs.channel < rhs.channel }
            return lhs.tag.compare(rhs.tag, options: .numeric) == .orderedAscending
        }
    }

    public func isNewer(build: Int, than installedVersion: String, build installedBuild: Int) -> Bool {
        guard build > installedBuild else { return false }
        return version.compare(installedVersion, options: .numeric) != .orderedAscending
    }
}
