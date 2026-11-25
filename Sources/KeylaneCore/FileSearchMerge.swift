import Foundation

/// Merge sources already ordered by RankedFile.precedes. Accepted local records
/// shadow Spotlight duplicates even when the remote score is higher, preserving
/// the existing saved-body/offline-record policy.
public enum FileSearchMerge {
    public static func top(local: [RankedFile], system: [RankedFile], limit: Int = 200,
                           acceptsLocal: (RankedFile) -> Bool,
                           acceptsSystem: (RankedFile) -> Bool,
                           isCancelled: () -> Bool = { false }) -> [RankedFile]? {
        guard limit > 0 else { return [] }
        var localIDs = Set<String>()
        var accepted: [RankedFile] = []
        for hit in local {
            if isCancelled() { return nil }
            if acceptsLocal(hit), localIDs.insert(hit.file.id).inserted { accepted.append(hit) }
        }
        var result: [RankedFile] = []
        var seen = localIDs
        var left = 0, right = 0
        while result.count < limit && (left < accepted.count || right < system.count) {
            if isCancelled() { return nil }
            if left < accepted.count && (right == system.count || accepted[left].precedes(system[right])) {
                result.append(accepted[left]); left += 1
            } else {
                let hit = system[right]; right += 1
                if seen.contains(hit.file.id) { continue }
                if acceptsSystem(hit) { seen.insert(hit.file.id); result.append(hit) }
            }
        }
        return isCancelled() ? nil : result
    }
}
