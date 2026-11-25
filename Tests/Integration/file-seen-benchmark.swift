import Foundation
import SQLite3
import KeylaneCore
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneSeenBench-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: folder) }
let url = folder.appendingPathComponent("index.sqlite")
let db = try FileSearchIndex(url: url)
let records = (0..<200).map { FileIndexRecord(path: "/fixture/item-\($0).txt", name: "item-\($0).txt", volume: "/", modified: 1, directory: false, symlink: false) }
let body = (0..<1800).map { "word\($0)" }.joined(separator: " ")
try db.transaction { for record in records { try db.put(record, body: body, root: "/fixture", epoch: "c:original") } }
var connection: OpaquePointer?
guard sqlite3_open(url.path, &connection) == SQLITE_OK else { fatalError("open") }
defer { sqlite3_close(connection) }
guard sqlite3_exec(connection, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil) == SQLITE_OK else { fatalError("checkpoint") }
let start = ProcessInfo.processInfo.systemUptime
try db.transaction { for record in records { try db.stageMetadata(record, root: "/fixture", epoch: "c:newscan", contentSearch: true) } }
let seconds = ProcessInfo.processInfo.systemUptime - start
let wal = try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as! NSNumber
try db.removeUnseen(root: "/fixture", epoch: "c:newscan")
guard try db.stats().entries == records.count else { fatalError("reconciliation") }
print("{\"entries\":200,\"wal_bytes\":\(wal),\"seconds\":\(seconds)}")
