import Foundation

enum AIModelChoice: Hashable {
    case model(UUID), lastUsed, inherit
}

/// A single ordered snapshot feeds both visible groups and keyboard navigation.
struct AIModelMenuCatalog {
    struct Group: Identifiable {
        let id: String
        let models: [AIConnection]
    }
    let groups: [Group]

    init(connections: [AIConnection], selection: AIModelChoice, query: String) {
        let matches = connections.filter {
            ($0.isConfigured && $0.hiddenFromPicker != true || selection == .model($0.id)) &&
                (query.isEmpty || ($0.displayName + " " + $0.model + " " + $0.providerLabel).localizedCaseInsensitiveContains(query))
        }
        let providers = Dictionary(grouping: matches, by: \.providerLabel)
        groups = providers.keys.sorted(by: Self.precedes).map { provider in
            Group(id: provider, models: (providers[provider] ?? []).sorted {
                if $0.displayName != $1.displayName { return Self.precedes($0.displayName, $1.displayName) }
                return $0.id.uuidString < $1.id.uuidString
            })
        }
    }

    func choices(inherits: Bool, allowsLastUsed: Bool) -> [AIModelChoice] {
        (inherits ? [.inherit] : []) + (allowsLastUsed ? [.lastUsed] : []) +
            groups.flatMap(\.models).filter(\.isConfigured).map { .model($0.id) }
    }

    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.localizedStandardCompare(rhs)
        return order == .orderedSame ? lhs < rhs : order == .orderedAscending
    }
}
