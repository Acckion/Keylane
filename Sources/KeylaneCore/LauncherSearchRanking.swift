import Foundation

/// Query-specific ranking policy shared by launcher command providers.
public struct LauncherSearchRanking {
    public enum Kind { case command, file, calculator, systemSetting }

    public enum Sensitivity: String, CaseIterable {
        case low, medium, high

        fileprivate var minimumScore: Int {
            switch self {
            case .low: 0
            case .medium: 600
            case .high: 800
            }
        }
    }

    private let query: SearchRanker.Query
    private let trimmedQuery: String
    private let settingsQuery: SearchRanker.Query
    private let hasSettingsQuery: Bool
    private let aliases: [String: String]
    private let favorites: Set<String>
    private let usage: [String: Int]
    private let sensitivity: Sensitivity
    private let rankFile: (String) -> Int

    public init(query: String, aliases: [String: String], favorites: Set<String>, usage: [String: Int], sensitivity: Sensitivity = .low) {
        self.query = SearchRanker.Query(query)
        trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let settingsText = SystemSettingsCatalog.pageQuery(query)
        settingsQuery = SearchRanker.Query(settingsText)
        hasSettingsQuery = !settingsText.isEmpty
        self.aliases = aliases
        self.favorites = favorites
        self.usage = usage
        self.sensitivity = sensitivity
        rankFile = FileSearchRules.ranker(for: query)
    }

    public func match(id: String, title: String, names: [String] = [], kind: Kind = .command,
                      prepareName: (String) -> SearchRanker.Name = SearchRanker.prepareName) -> SearchResultRank? {
        let score: Int
        switch kind {
        case .calculator:
            score = 2000
        case .file:
            score = rankFile(title)
        case .command, .systemSetting:
            let alias = aliases[id] ?? ""
            let exactAlias = !alias.isEmpty && alias.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame
            func match(_ name: String, _ query: SearchRanker.Query) -> Int {
                query.isEmpty ? 0 : (SearchRanker.score(prepareName(name), query: query) ?? -1)
            }
            let namesQuery = kind == .systemSetting ? settingsQuery : query
            var best = max(exactAlias ? 1500 : match(alias, query), match(title, namesQuery))
            for name in names { best = max(best, match(name, namesQuery)) }
            guard best >= 0 else { return nil }
            score = best
            if kind == .command && !trimmedQuery.isEmpty && score < sensitivity.minimumScore { return nil }
            if kind == .systemSetting && hasSettingsQuery && score < 600 { return nil }
        }
        return SearchResultRank(score: score, favorite: favorites.contains(id), uses: usage[id, default: 0],
                                title: title, id: id)
    }
}
