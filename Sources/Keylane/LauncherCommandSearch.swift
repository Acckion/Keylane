import Foundation
import KeylaneCore

struct FallbackCommandOrder: Equatable {
    static let preferenceKey = "launcherFallbackCommandIDs"

    // An empty custom order is an explicit opt-out. No saved order follows the available catalog.
    var custom: [String]?
    var legacyFirst: String?

    init(custom: [String]? = nil, legacyFirst: String? = nil) {
        self.custom = custom
        self.legacyFirst = legacyFirst
    }

    init(preferences: UserDefaults) {
        let saved = preferences.stringArray(forKey: Self.preferenceKey)
        let legacy = preferences.string(forKey: "scriptCommands.fallback").flatMap { $0.isEmpty ? nil : $0 }
        var seen = Set<String>()
        self.init(custom: saved?.filter { !$0.isEmpty && seen.insert($0).inserted }, legacyFirst: legacy)
    }

    func ids(in catalog: [Entry]) -> [String] {
        if let custom { return custom }
        var ids = catalog.map(\.id)
        if let legacyFirst, let index = ids.firstIndex(of: legacyFirst) {
            ids.remove(at: index)
            ids.insert(legacyFirst, at: 0)
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// Owns the most recent query result on the UI thread.
final class LauncherCommandSearch {
    struct Input: Equatable {
        let query: String
        let page: PageID
        let aliases: [String: String]
        let favorites: Set<String>
        let usage: [String: Int]
        var favoriteOrder: [String] = []
        var history = SearchUsageHistory()
        var sensitivity: LauncherSearchRanking.Sensitivity = .low
        var namespace: LauncherCommandNamespace?
        var fallbackOrder = FallbackCommandOrder()
        var allowsFallback = true
    }
    private var cached: (input: Input, date: Date, results: [Entry])?
    private var preparedNames: [String: SearchRanker.Name] = [:]

    func invalidate() { cached = nil }

    func releasePreparedNames() {
        invalidate()
        preparedNames.removeAll()
    }

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
            if let score = entry.matchScore {
                return (entry, rank.explicitResult(id: entry.id, title: entry.name, score: score))
            }
            return rank.match(id: entry.id, title: entry.name, names: entry.aliases, kind: entry.rankingKind, prepareName: prepare)
                .map { (entry, $0) }
        }.sorted { $0.1.precedes($1.1) }.map(\.0)

        // On the home screen, the user's order applies to the favorite slots.
        var ordered = results
        if input.query.isEmpty {
            let positions = results.indices.filter { input.favorites.contains(results[$0].id) }
            let byID = Dictionary(results.filter { input.favorites.contains($0.id) }.map { ($0.id, $0) },
                                  uniquingKeysWith: { first, _ in first })
            let favorites = input.favoriteOrder.compactMap { byID[$0] }
            if positions.count == favorites.count {
                for (position, favorite) in zip(positions, favorites) { ordered[position] = favorite }
            }
        }

        // File rows form one section, retaining their rank within the section.
        let grouped: [Entry]
        if ordered.isEmpty, input.page == .root, input.namespace == nil, input.allowsFallback,
           input.fallbackOrder.custom?.isEmpty != true,
           !input.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let catalog = registry.fallbackCatalog()
            let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            grouped = input.fallbackOrder.ids(in: catalog).compactMap { id in
                guard var entry = byID[id] else { return nil }
                entry.fallbackQuery = input.query
                return entry
            }
        } else {
            grouped = ordered.filter { $0.rankingKind != .file } + ordered.filter { $0.rankingKind == .file }
        }
        if !currentNames.isEmpty { preparedNames = currentNames }
        cached = (input, now, grouped)
        return grouped
    }

}
