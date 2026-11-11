import KeylaneCore

/// Owns the most recent query result on the UI thread.
final class LauncherCommandSearch {
    struct Input: Equatable {
        let query: String
        let page: PageID
        let aliases: [String: String]
        let favorites: Set<String>
        let usage: [String: Int]
    }
    private var cached: (input: Input, results: [Entry])?

    func invalidate() { cached = nil }

    func results(for input: Input, registry: LauncherModuleRegistry) -> [Entry] {
        if let cached, cached.input == input { return cached.results }

        let candidates = registry.candidates(for: input)
        let rank = LauncherSearchRanking(query: input.query, aliases: input.aliases,
                                         favorites: input.favorites, usage: input.usage)
        let results = candidates.compactMap { entry -> (Entry, SearchResultRank)? in
            rank.match(id: entry.id, title: entry.name, names: entry.aliases, kind: entry.rankingKind)
                .map { (entry, $0) }
        }.sorted { $0.1.precedes($1.1) }.map(\.0)

        cached = (input, results)
        return results
    }

}
