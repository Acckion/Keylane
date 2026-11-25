import Foundation
import SQLite3
import KeylaneCore
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneBodyReuse-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let url = folder.appendingPathComponent("index.sqlite")
let db = try FileSearchIndex(url: url)
let body = (0..<1800).map { "word\($0)" }.joined(separator: " ")
func record(_ i: Int, _ modified: Double) -> FileIndexRecord {
    .init(path: "/fixture/doc-\(i).txt", name: "doc-\(i).txt", volume: "/", modified: modified, directory: false, symlink: false)
}
try db.transaction { for i in 0..<20 { try db.put(record(i,1), body: body, root: "/fixture", epoch: "c:one") } }
var raw: OpaquePointer?
guard sqlite3_open(url.path, &raw) == SQLITE_OK else { fatalError("open") }
defer { sqlite3_close(raw) }
guard sqlite3_exec(raw, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK else { fatalError("checkpoint") }
var options = FileSearchOptions(roots: ["/fixture"]); options.ignorePatterns = []; options.contentSearch = true
let start = ProcessInfo.processInfo.systemUptime
try db.transaction { for i in 0..<20 { try db.stageMetadata(record(i,2), root: "/fixture", epoch: "c:two", contentSearch: true) } }
precondition(try! db.search("word1000", options: options).isEmpty, "Unverified body leaked")
while let job = try db.nextContentJob() { _ = try db.completeContent(job, body: body) }
let elapsed = ProcessInfo.processInfo.systemUptime - start
precondition(try! db.search("word1000", options: options).count == 20)
let size = try FileManager.default.attributesOfItem(atPath: url.path+"-wal")[.size] as! NSNumber
let queries = ProcessInfo.processInfo.systemUptime
for _ in 0..<100 { precondition(try! db.search("word1000", options: options).count == 20) }
print("{\"wal_bytes\":\(size),\"update_seconds\":\(elapsed),\"query100_seconds\":\(ProcessInfo.processInfo.systemUptime-queries)}")
