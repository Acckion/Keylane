import Foundation

/// Query-specific ranking policy shared by launcher command providers.
public struct LauncherSearchRanking {
    public enum Kind { case command, file, calculator }

    private let query: String
    private let trimmedQuery: String
    private let aliases: [String: String]
    private let favorites: Set<String>
    private let usage: [String: Int]
    private let rankFile: (String) -> Int

    public init(query: String, aliases: [String: String], favorites: Set<String>, usage: [String: Int]) {
        self.query = query
        trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.aliases = aliases
        self.favorites = favorites
        self.usage = usage
        rankFile = FileSearchRules.ranker(for: query)
    }

    public func match(id: String, title: String, names: [String] = [], kind: Kind = .command) -> SearchResultRank? {
        let score: Int
        switch kind {
        case .calculator:
            score = 2000
        case .file:
            score = rankFile(title)
        case .command:
            let alias = aliases[id] ?? ""
            let exactAlias = !alias.isEmpty && alias.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame
            let aliasScore = exactAlias ? 1500 : (SearchRanker.score(alias, query: query) ?? -1)
            let nameScore = ([title] + names).compactMap { SearchRanker.score($0, query: query) }.max()
            guard let match = nameScore ?? (aliasScore >= 0 ? aliasScore : nil) else { return nil }
            score = max(match, aliasScore)
        }
        return SearchResultRank(score: score, favorite: favorites.contains(id), uses: usage[id, default: 0],
                                title: title, id: id)
    }
}
