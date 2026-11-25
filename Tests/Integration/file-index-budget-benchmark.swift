import AppKit
import Darwin
import KeylaneCore
setbuf(stdout, nil)
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KEYLANE_BENCHMARK_ROOT"]!)
let shape = CommandLine.arguments.dropFirst().first ?? "wide"
let scope = base.appendingPathComponent(shape)
let expected = shape == "wide" ? 3000 : 3300
let suite = "org.keylane.index-budget-benchmark." + UUID().uuidString
let preferences = UserDefaults(suiteName: suite)!
defer { preferences.removePersistentDomain(forName: suite) }
var options = FileSearchOptions(roots: [scope.path]); options.ignorePatterns = []; options.contentSearch = false
preferences.set(try JSONEncoder().encode(options), forKey: "fileSearchOptions")
preferences.set(options.roots, forKey: "fileSearchSelectedScopes")
let controller = FileSearchController(directory: base.appendingPathComponent("store-" + UUID().uuidString), preferences: preferences, watchChanges: false, startImmediately: false)
let cpu = clock(), start = Date()
controller.startRuntime()
controller.startIndex()
while controller.stats.entries != expected || controller.indexing {
    if Date().timeIntervalSince(start) > 30 {
        fputs("Benchmark did not finish: \(controller.indexStatus), entries=\(controller.stats.entries)\n", stderr)
        exit(1)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.002))
}
let seconds = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
let wall = Date().timeIntervalSince(start)
controller.stopRuntime()
print("{\"shape\":\"\(shape)\",\"entries\":\(expected),\"cpu_seconds\":\(seconds),\"wall_seconds\":\(wall)}")
RunLoop.current.run(until: Date().addingTimeInterval(0.1))
