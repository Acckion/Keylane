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

    private static let explicitMatchPriority = 4

    private let query: SearchRanker.Query
    private let trimmedQuery: String
    private let settingsQuery: SearchRanker.Query
    private let hasSettingsQuery: Bool
    private let aliases: [String: String]
    private let favorites: Set<String>
    private let usage: [String: Int]
    private let sensitivity: Sensitivity
    private let history: SearchUsageHistory
    private let queryKey: String?
    private let now: Date
    private let rankFile: (String) -> Int

    public init(query: String, aliases: [String: String], favorites: Set<String>, usage: [String: Int], sensitivity: Sensitivity = .low,
                history: SearchUsageHistory = .init(), now: Date = .now) {
        self.query = SearchRanker.Query(query)
        trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let settingsText = SystemSettingsCatalog.pageQuery(query)
        settingsQuery = SearchRanker.Query(settingsText)
        hasSettingsQuery = !settingsText.isEmpty
        self.aliases = aliases
        self.favorites = favorites
        self.usage = usage
        self.sensitivity = sensitivity
        self.history = history
        self.now = now
        queryKey = SearchUsageHistory.queryKey(query)
        rankFile = FileSearchRules.ranker(for: query)
    }

    public func match(id: String, title: String, names: [String] = [], kind: Kind = .command,
                      prepareName: (String) -> SearchRanker.Name = SearchRanker.prepareName) -> SearchResultRank? {
        let score: Int
        let priority: Int
        switch kind {
        case .calculator:
            score = 2000
            priority = Self.explicitMatchPriority
        case .file:
            score = rankFile(title)
            priority = 0
        case .command, .systemSetting:
            let alias = aliases[id] ?? ""
            let namesQuery = kind == .systemSetting ? settingsQuery : query
            func match(_ name: String, _ query: SearchRanker.Query) -> Int {
                if query.isEmpty { return 0 }
                guard !name.isEmpty else { return -1 }
                return SearchRanker.score(prepareName(name), query: query) ?? -1
            }

            let aliasScore = match(alias, query)
            let titleScore = match(title, namesQuery)
            let keywordScore = names.reduce(-1) { max($0, match($1, namesQuery)) }
            let best = max(aliasScore, titleScore, keywordScore)
            guard best >= 0 else { return nil }
            let minimum = kind == .systemSetting && hasSettingsQuery ? 600
                : kind == .command && !trimmedQuery.isEmpty ? sensitivity.minimumScore : 0
            guard best >= minimum else { return nil }

            let aliasOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
            let matchesAlias = !query.isEmpty && !alias.isEmpty
            if matchesAlias && alias.compare(trimmedQuery, options: aliasOptions) == .orderedSame {
                score = 1500
                priority = 3
            } else if matchesAlias && alias.range(of: trimmedQuery, options: aliasOptions.union(.anchored)) != nil {
                score = 1400
                priority = 2
            } else if titleScore >= minimum && titleScore > 0 {
                score = titleScore
                priority = 1
            } else {
                score = best
                priority = 0
            }
        }
        return result(id: id, title: title, score: score, priority: priority, groupCloseMatches: kind == .command)
    }

    public func explicitResult(id: String, title: String, score: Int) -> SearchResultRank {
        result(id: id, title: title, score: score, priority: Self.explicitMatchPriority, groupCloseMatches: false)
    }

    private func result(id: String, title: String, score: Int, priority: Int, groupCloseMatches: Bool) -> SearchResultRank {
        let activity = history.scores(for: id, queryKey: queryKey, at: now)
        let count = max(0, usage[id, default: 0])
        // A small capped contribution keeps legacy usage useful while recent selections decay.
        let legacyWeight = min(0.75, log2(1 + Double(count)) / 8)
        let band = groupCloseMatches && (1...300).contains(score) ? (score - 1) / 20 * 20 + 1 : score
        return SearchResultRank(score: score, favorite: favorites.contains(id), uses: count,
                                title: title, id: id, priority: priority, relevanceBand: band,
                                queryUsage: activity.query, overallUsage: activity.overall + legacyWeight)
    }
}
