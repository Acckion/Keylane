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

    struct Diagnostics {
        var scored = 0
        var reused = 0
        var cacheHit = false
        var duration: TimeInterval = 0
    }
    private(set) var diagnostics = Diagnostics()
    private struct Ranked {
        let entry: Entry
        let owner: ModuleID?
        let rank: SearchResultRank?
        func matches(_ other: Entry) -> Bool {
            entry.commandID == other.commandID && entry.name == other.name && entry.aliases == other.aliases &&
            entry.rankingKind == other.rankingKind && entry.matchScore == other.matchScore
        }
    }
    private var ranked: [String: Ranked] = [:]
    private var rankingInput: Input?
    private var rankingDate = Date.distantPast
    private var registryIdentity: ObjectIdentifier?

    func invalidate(module: ModuleID? = nil) {
        cached = nil
        if let module { ranked = ranked.filter { $0.value.owner != module } }
        else { ranked.removeAll(); rankingInput = nil }
    }

    func releasePreparedNames() {
        invalidate()
        preparedNames.removeAll()
    }

    func results(for input: Input, registry: LauncherModuleRegistry) -> [Entry] {
        let start = ProcessInfo.processInfo.systemUptime
        diagnostics = Diagnostics()
        defer { diagnostics.duration = ProcessInfo.processInfo.systemUptime - start }
        let now = Date.now
        if registryIdentity != ObjectIdentifier(registry) {
            invalidate(); registryIdentity = ObjectIdentifier(registry)
        }
        if let cached, cached.input == input, now.timeIntervalSince(cached.date) < 60 {
            diagnostics.cacheHit = true
            return cached.results
        }
        if rankingInput != input || now.timeIntervalSince(rankingDate) >= 60 {
            ranked.removeAll(); rankingInput = input; rankingDate = now
        }

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
        var nextRanked: [String: Ranked] = [:]
        let results = candidates.compactMap { entry -> (Entry, SearchResultRank)? in
            let score: SearchResultRank?
            if let previous = ranked[entry.id], previous.matches(entry) {
                diagnostics.reused += 1
                score = previous.rank
            } else {
                diagnostics.scored += 1
                if let explicit = entry.matchScore {
                    score = rank.explicitResult(id: entry.id, title: entry.name, score: explicit)
                } else {
                    score = rank.match(id: entry.id, title: entry.name, names: entry.aliases,
                                       kind: entry.rankingKind, prepareName: prepare)
                }
            }
            nextRanked[entry.id] = Ranked(entry: entry, owner: registry.moduleOwningCommand(entry.commandID), rank: score)
            return score.map { (entry, $0) }
        }.sorted { $0.1.precedes($1.1) }.map(\.0)
        ranked = nextRanked

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
