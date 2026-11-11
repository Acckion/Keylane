import Foundation
import KeylaneCore

/// Owns the most recent query result on the UI thread.
final class LauncherCommandSearch {
    struct Input: Equatable {
        let query: String
        let page: PageID
        let aliases: [String: String]
        let favorites: Set<String>
        let usage: [String: Int]
        var history = SearchUsageHistory()
        var sensitivity: LauncherSearchRanking.Sensitivity = .low
        var namespace: LauncherCommandNamespace?
    }
    private var cached: (input: Input, date: Date, results: [Entry])?
    private var preparedNames: [String: SearchRanker.Name] = [:]

    func invalidate() { cached = nil }

    func results(for input: Input, registry: LauncherModuleRegistry) -> [Entry] {
        let now = Date.now
        if let cached, cached.input == input, now.timeIntervalSince(cached.date) < 60 { return cached.results }

        let candidates = registry.candidates(for: input)
        let rank = LauncherSearchRanking(query: input.query, aliases: input.aliases,
                                         favorites: input.favorites, usage: input.usage, sensitivity: input.sensitivity,
                                         history: input.history, now: now)
        // Keep the names from the last nonempty query, including catalogs larger than NSCache.
        var currentNames: [String: SearchRanker.Name] = [:]
        func prepare(_ name: String) -> SearchRanker.Name {
            if let prepared = currentNames[name] { return prepared }
            let prepared = preparedNames[name] ?? SearchRanker.prepareName(name)
            currentNames[name] = prepared
            return prepared
        }
        let results = candidates.compactMap { entry -> (Entry, SearchResultRank)? in
            guard !entry.isFallback else { return nil }
            if let score = entry.matchScore {
                return (entry, rank.result(id: entry.id, title: entry.name, score: score))
            }
            return rank.match(id: entry.id, title: entry.name, names: entry.aliases, kind: entry.rankingKind, prepareName: prepare)
                .map { (entry, $0) }
        }.sorted { $0.1.precedes($1.1) }.map(\.0)

        // File rows form one section, retaining their rank within the section.
        let grouped = results.isEmpty ? candidates.filter(\.isFallback)
            : results.filter { $0.rankingKind != .file } + results.filter { $0.rankingKind == .file }
        if !currentNames.isEmpty { preparedNames = currentNames }
        cached = (input, now, grouped)
        return grouped
    }

}
