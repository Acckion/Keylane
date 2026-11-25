import Foundation
import SQLite3
import KeylaneCore

let root = "/fixture"
let entries = (0..<30_000).map { index in
    FileIndexRecord(path: "\(root)/file-\(index).txt", name: "file-\(index).txt",
                    volume: "/", modified: 1, directory: false, symlink: false)
}
func run(transient: Bool) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("index.sqlite")
    let db = try FileSearchIndex(url: url)
    try db.transaction {
        for record in entries { try db.put(record, root: root, epoch: "n:old") }
    }
    var reader: OpaquePointer?
    precondition(sqlite3_open(url.path, &reader) == SQLITE_OK)
    defer { sqlite3_close(reader) }
    precondition(sqlite3_exec(reader, "PRAGMA wal_checkpoint(TRUNCATE); BEGIN; SELECT count(*) FROM files", nil, nil, nil) == SQLITE_OK)
    let before = db.writeDiagnostics
    let start = ProcessInfo.processInfo.systemUptime
    if transient { try db.prepareTransientSeen(epoch: "n:scan") }
    for offset in stride(from: 0, to: entries.count, by: 64) {
        try db.transaction {
            for record in entries[offset..<min(entries.count, offset + 64)] {
                try db.stageMetadata(record, root: root, epoch: "n:scan", contentSearch: false)
            }
        }
    }
    try db.removeUnseen(root: root, epoch: "n:scan")
    if transient { try db.discardTransientSeen(epoch: "n:scan") }
    let seconds = ProcessInfo.processInfo.systemUptime - start
    let stats = try db.stats()
    precondition(stats.entries == entries.count)
    let bytes = try FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as! NSNumber
    print("bench transient=\(transient) entries=\(stats.entries) seen_writes=\(db.writeDiagnostics.seenWrites-before.seenWrites) wal_bytes=\(bytes) seconds=\(seconds)")
}
for transient in [false, true, true, false, false, true] { try run(transient: transient) }
