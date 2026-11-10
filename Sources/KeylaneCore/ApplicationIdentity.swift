import Foundation
import CoreFoundation

/// Resolve the target bundle's language independently of the launcher's own localization.
/// Uses Apple's public localization API, including system .loctable resources.
public struct ApplicationIdentity {
    public let displayName: String
    public let aliases: [String]
    public init(url: URL, preferredLanguages: [String] = Locale.preferredLanguages) {
        let filename = url.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]
        let missing = "__KEYLANE_MISSING_LOCALIZED_BUNDLE_NAME__"
        let cf = CFBundleCreate(nil, url as CFURL)
        func localized(_ key: String, languages: [String]) -> String? {
            guard let cf else { return nil }
            let value = CFBundleCopyLocalizedStringForLocalizations(cf, key as CFString, missing as CFString, "InfoPlist" as CFString, languages as CFArray) as String
            return value != missing && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? value : nil
        }
        let rawDisplay = info["CFBundleDisplayName"] as? String
        let rawName = info["CFBundleName"] as? String
        let systemName = FileManager.default.displayName(atPath: url.path)
        let fallback = systemName.hasSuffix(".app") ? String(systemName.dropLast(4)) : systemName
        displayName = localized("CFBundleDisplayName", languages: preferredLanguages)
            ?? localized("CFBundleName", languages: preferredLanguages)
            ?? (fallback.isEmpty ? nil : fallback) ?? rawDisplay ?? rawName ?? filename
        let alternatives = info["CFBundleAlternateNames"] as? [String] ?? []
        let candidates = [filename, rawDisplay, rawName,
                          localized("CFBundleDisplayName", languages: ["en"]),
                          localized("CFBundleName", languages: ["en"])].compactMap { $0 } + alternatives
        let shownName = displayName
        var seen = Set<String>()
        aliases = candidates.filter { !$0.isEmpty && $0 != shownName && seen.insert($0.lowercased()).inserted }
    }
    public func score(query: String) -> Int? {
        ([displayName] + aliases).compactMap { SearchRanker.score($0, query: query) }.max()
    }
}
