// Privacy-safe comparison; run alone with KEYLANE_FILE_TEST_RELEASE=1 and verify-files.sh.
import Foundation
import Darwin
import KeylaneCore

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_FILE_TEST_ROOT"]!).appendingPathComponent("merge")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let files = try (0..<400).map { id -> SpotlightFile in
    let url = root.appendingPathComponent("fixture-\(id).txt")
    try Data().write(to: url)
    return .init(url: url, name: url.lastPathComponent, modified: Date(timeIntervalSince1970: Double(id)))
}
var options = FileSearchOptions(roots: [root.path]); options.ignorePatterns = []; options.useIgnoreFiles = false
let local = (0..<200).map { RankedFile(file: files[$0], score: 1000 - $0) }.sorted { $0.precedes($1) }
func cpu() -> Double { Double(clock()) / Double(CLOCKS_PER_SEC) }
func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
for highSystemCount in [0, 100, 200] {
    let system = (200..<400).map { id in RankedFile(file: files[id], score: id - 200 < highSystemCount ? 2000 - id : 500 - id) }.sorted { $0.precedes($1) }
    var oldCPU: [Double] = [], newCPU: [Double] = []
    var oldChecks = 0, newChecks = 0
    func run(_ optimized: Bool) -> [RankedFile] {
        var locations = FileSearchLocation(options: options, automaticExclusions: [])
        func saved(_ hit: RankedFile) -> Bool { locations.includesSavedResult(at: hit.file.id, directory: false) }
        func systemAllowed(_ hit: RankedFile) -> Bool {
            if optimized { newChecks += 1 } else { oldChecks += 1 }
            return options.roots.contains { FileSearchLocation.contains(hit.file.id, in: $0) }
                && (try? locations.item(at: hit.file.url)) != nil
        }
        if optimized {
            return FileSearchMerge.top(local: local, system: system, acceptsLocal: saved,
                acceptsSystem: { saved($0) && systemAllowed($0) })!
        }
        var seen = Set<String>()
        return Array((local + system.filter(systemAllowed)).filter { saved($0) && seen.insert($0.file.id).inserted }
            .sorted { $0.precedes($1) }.prefix(200))
    }
    precondition(run(false).map(\.file) == run(true).map(\.file))
    for round in 0..<5 {
        // Alternate execution order to reduce warm-cache/order bias.
        for optimized in round % 2 == 0 ? [false, true] : [true, false] {
            let start = cpu()
            for _ in 0..<30 { precondition(run(optimized).count == 200) }
            let elapsed = cpu() - start
            if optimized { newCPU.append(elapsed) } else { oldCPU.append(elapsed) }
        }
    }
    print("MERGE highSystem=\(highSystemCount) equal=true rounds=5 iterations=30 old_cpu_ms=\(median(oldCPU) * 1000) new_cpu_ms=\(median(newCPU) * 1000) old_checks_per_merge=\(oldChecks / 151) new_checks_per_merge=\(newChecks / 151)")
}
