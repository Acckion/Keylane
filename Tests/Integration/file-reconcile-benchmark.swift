import Foundation
import Darwin
import KeylaneCore
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneReconcile-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let db = try FileSearchIndex(url: folder.appendingPathComponent("index.sqlite"))
try db.transaction {
    for i in 0..<30_000 {
        try db.put(.init(path: "/fixture/unrelated-\(i).txt", name: "unrelated-\(i).txt", volume: "/", modified: 1, directory: false, symlink: false), root: "/fixture", epoch: "old")
    }
}
func cpu() -> Double {
    var r = rusage(); getrusage(RUSAGE_SELF, &r)
    // timeval is already seconds/microseconds, not Mach clock ticks.
    return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
}
let before = cpu(), start = ProcessInfo.processInfo.systemUptime
for i in 0..<30 {
    try db.removeUnseen(root: "/fixture", subtree: "/fixture/absent-\(i)", epoch: "current")
}
let elapsed = ProcessInfo.processInfo.systemUptime - start, used = cpu() - before
precondition(try! db.stats().entries == 30_000, "Unrelated root rows changed")
print("{\"rows\":30000,\"subtrees\":30,\"cpu_seconds\":\(used),\"wall_seconds\":\(elapsed)}")
