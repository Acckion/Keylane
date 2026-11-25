import Foundation
import Darwin
import KeylaneCore
let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneRuleIO-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/info"),withIntermediateDirectories:true)
if CommandLine.arguments.dropFirst().first == "present" {
    for name in [".gitignore",".ignore",".rayignore",".git/info/exclude"] { try Data("*.log\n!keep.log\n".utf8).write(to:root.appendingPathComponent(name)) }
}
func cpu() -> Double { var r = rusage(); getrusage(RUSAGE_SELF,&r); return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1e6 }
let before = cpu(), start = ProcessInfo.processInfo.systemUptime
var rules = 0
for _ in 0..<1000 { rules += autoreleasepool { FileSearchRules.readIgnoreRules(in:root).count } }
print("{\"cpu_seconds\":\(cpu()-before),\"wall_seconds\":\(ProcessInfo.processInfo.systemUptime-start),\"rules\":\(rules)}")
