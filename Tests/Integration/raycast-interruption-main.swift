import Darwin
import Foundation
@testable import KeylaneCore

// Standalone processes, synthetic records, and an explicitly guarded temporary root only.
func require(_ condition: @autoclosure () throws -> Bool, _ message: String = "Synthetic check failed") throws {
    let result = try condition()
    precondition(result, message)
}
let arguments = CommandLine.arguments
try require(arguments.count == 5)
let operation = arguments[1]
let root = URL(fileURLWithPath: arguments[2]).standardizedFileURL
try require(root.path.hasPrefix("/private/tmp/KeylaneRaycastInterruption.") || root.path.hasPrefix("/tmp/KeylaneRaycastInterruption."))
let id = MigrationResourceID(rawValue: arguments[3])!
try require(id != .focus)
let point = RaycastMigrationTransaction.InstallationEvent(rawValue: arguments[4])!
let recovery = root.appendingPathComponent("recovery")
let preferences = root.appendingPathComponent("preferences.plist")
let destination = root.appendingPathComponent(id.relativePath)
let source = root.appendingPathComponent("source")
let marker = root.appendingPathComponent("interrupted")
func read() -> [String:Any] {
    guard let data = try? Data(contentsOf:preferences) else { return [:] }
    return (try? PropertyListSerialization.propertyList(from:data,format:nil)) as? [String:Any] ?? [:]
}
func persist(_ value: [String:Any]) -> Bool {
    do {
        try PropertyListSerialization.data(fromPropertyList:value,format:.binary,options:0).write(to:preferences,options:.atomic)
        return true
    } catch { return false }
}
switch operation {
case "seed":
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    do {
        let store = try Store(url:source.appendingPathComponent("data.sqlite"))
        let body = String(repeating:"Synthetic migration page. ",count:1_500)
        try store.save((0..<96).map { Record(id:String($0),kind:"snippet",title:"Synthetic \($0)",body:body) })
    }
    let payload = try RaycastMigrationTransaction.snapshot(.snippets,root:source)!
    try require(payload.count > 16 * 4096, "The copying fault must interrupt a multi-step backup")
    try require(persist(["unrelated":"preserved"]))
    try RaycastMigrationTransaction.stage(changes:["imported":true],current:read(),resources:[.init(id:id,before:nil,after:payload)],directory:recovery)
case "interrupt":
    _ = try RaycastMigrationTransaction.finish(directory:recovery,root:root,read:read,persist:persist,installationObserver:{ event, candidate in
        guard event == point else { return }
        try require(FileManager.default.fileExists(atPath:candidate.path))
        if event != .published { try require(!FileManager.default.fileExists(atPath:destination.path)) }
        let mode = try FileManager.default.attributesOfItem(atPath:candidate.path)[.posixPermissions] as! NSNumber
        try require(mode.intValue & 0o777 == 0o600)
        try Data(event.rawValue.utf8).write(to:marker)
        // Bypass Swift defer, SQLite close/rollback and all normal process cleanup.
        _exit(73)
    })
    preconditionFailure("Interruption point was not reached")
case "recover":
    try require(try Data(contentsOf:marker) == Data(point.rawValue.utf8))
    try require(RaycastMigrationTransaction.hasPending(in:recovery))
    try require(RaycastMigrationTransaction.hasStarted(in:recovery))
    try require(read()["imported"] == nil)
    let expected = try RaycastMigrationTransaction.snapshot(.snippets,root:source)
    if point == .published {
        try require(try RaycastMigrationTransaction.fingerprint(RaycastMigrationTransaction.snapshot(id,root:root),id:id) == RaycastMigrationTransaction.fingerprint(expected,id:id))
    } else { try require(!FileManager.default.fileExists(atPath:destination.path)) }
    try require(try RaycastMigrationTransaction.finish(directory:recovery,root:root,read:read,persist:persist))
    try require(!RaycastMigrationTransaction.hasPending(in:recovery))
    try require(read()["imported"] as? Bool == true && read()["unrelated"] as? String == "preserved")
    do { let store = try Store(url:destination); try require(try store.records(kind:"snippet").count == 96) }
    try RaycastMigrationTransaction.stageUndo(directory:recovery,root:root,current:read())
    try require(try RaycastMigrationTransaction.finish(directory:recovery,root:root,read:read,persist:persist))
    try require(!FileManager.default.fileExists(atPath:destination.path))
    try require(read()["imported"] == nil && read()["unrelated"] as? String == "preserved")
    print("RAYCAST_INTERRUPTION_REPLAY_UNDO_OK \(id.rawValue)/\(point.rawValue)")
default: preconditionFailure("Unknown synthetic operation")
}
