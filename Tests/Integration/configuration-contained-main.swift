import Foundation
import KeylaneCore

// No AppKit, UserDefaults, clipboard, hotkey manager or app controllers.
// The runner denies filesystem writes outside this root, and denies IPC/network.
precondition(CommandLine.arguments.count == 3)
let phase = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
precondition(root.lastPathComponent == "data")
precondition(root.deletingLastPathComponent().path.hasPrefix("/private/tmp/KeylaneConfigurationContained."))
let preferences = root.appendingPathComponent("preferences.plist")
let recovery = root.appendingPathComponent("recovery", isDirectory: true)
let pending = recovery.appendingPathComponent("pending.plist")
let receipt = recovery.appendingPathComponent("last-import.plist")
let fixture = root.appendingPathComponent("fixture.json")
func require(_ condition: @autoclosure () throws -> Bool) rethrows {
    let satisfied = try condition(); precondition(satisfied)
}
func load() -> [String: Any] {
    guard FileManager.default.fileExists(atPath: preferences.path) else { return [:] }
    return try! PropertyListSerialization.propertyList(from: Data(contentsOf: preferences), format: nil) as! [String: Any]
}
@discardableResult func persist(_ value: [String: Any]) -> Bool {
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: preferences, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferences.path)
        return true
    } catch { return false }
}
func finish() throws -> Bool {
    try ConfigurationTransaction.finish(directory: recovery, read: load, persist: persist, restore: persist)
}
func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    NSDictionary(dictionary: lhs).isEqual(to: rhs)
}
func archive() throws -> ConfigurationArchive {
    try ConfigurationArchive.decode(ConfigurationTransaction.read(fixture))
}
func stage() throws {
    let current = load()
    let plan = try archive().plan(current: current, overwrite: true)
    try ConfigurationTransaction.stage(changes: plan.changes, current: current, directory: recovery)
}
switch phase {
case "seed":
    precondition(persist(["appearance": "light", "unrelated": "synthetic-preserved",
                          "apiKey": "synthetic-excluded", "aliases": [String: String]()]))
    var value = ConfigurationArchive()
    value.preferences["appearance"] = .string("dark")
    value.aliases = ["quicklink:contained": "synthetic"]
    value.quicklinks = [.init(id: "quicklink:contained", title: "Synthetic", template: "https://example.com/")]
    try value.data().write(to: fixture, options: .atomic)
    try require(try finish() == false)
    print("CONTAINED_SEED_NO_PENDING_OK")
case "stage":
    let original = load()
    try stage()
    precondition(equal(load(), original))
    let intent = try PropertyListSerialization.propertyList(from: Data(contentsOf: pending), format: nil) as! [String: Any]
    precondition((intent["before"] as! [String: Any])["apiKey"] == nil)
    precondition((intent["after"] as! [String: Any])["apiKey"] == nil)
    print("CONTAINED_STAGE_NO_LIVE_WRITE_OR_SECRET_COPY_OK")
case "apply":
    try require(try finish())
    precondition(load()["appearance"] as? String == "dark")
    precondition(load()["unrelated"] as? String == "synthetic-preserved")
    precondition(load()["apiKey"] as? String == "synthetic-excluded")
    try require(try archive().plan(current: load(), overwrite: true).changes.isEmpty)
    try require(try finish() == false)
    print("CONTAINED_NEW_PROCESS_APPLY_REPEAT_OK")
case "cancel-and-undo":
    let beforeReceipt = try Data(contentsOf: receipt)
    try ConfigurationTransaction.stage(changes: ["appearance": "light"], current: load(), directory: recovery)
    try ConfigurationTransaction.cancel(directory: recovery, current: load())
    try require(try Data(contentsOf: receipt) == beforeReceipt)
    precondition(load()["appearance"] as? String == "dark")
    try ConfigurationTransaction.stageUndo(current: load(), directory: recovery)
    print("CONTAINED_CANCEL_PRESERVES_RECEIPT_STAGE_UNDO_OK")
case "undo":
    let beforeReceipt = try Data(contentsOf: receipt)
    try require(try finish())
    precondition(load()["appearance"] as? String == "light")
    precondition(load()["aliases"] as? [String: String] == [:])
    precondition(load()[QuicklinkLibrary.storageKey] == nil)
    precondition(load()["apiKey"] as? String == "synthetic-excluded")
    try require(try Data(contentsOf: receipt) == beforeReceipt)
    print("CONTAINED_NEW_PROCESS_UNDO_OK")
case "rollback":
    let original = load(), beforeReceipt = try Data(contentsOf: receipt)
    try stage()
    do {
        _ = try ConfigurationTransaction.finish(directory: recovery, read: load, persist: { value in
            var partial = value; partial["unrelated"] = "synthetic-partial-write"
            precondition(persist(partial)); return false
        }, restore: persist)
        fatalError("Expected write failure")
    } catch is ConfigurationError {}
    precondition(equal(load(), original))
    precondition(FileManager.default.fileExists(atPath: pending.path))
    try require(try Data(contentsOf: receipt) == beforeReceipt)
    try ConfigurationTransaction.cancel(directory: recovery, current: load())
    print("CONTAINED_PARTIAL_WRITE_ROLLBACK_OK")
case "readback-and-rollback-failure":
    let original = load(), beforeReceipt = try Data(contentsOf: receipt)
    try stage()
    do {
        _ = try ConfigurationTransaction.finish(directory: recovery, read: load,
                                                 persist: { _ in true }, restore: persist)
        fatalError("Expected false-success rejection")
    } catch is ConfigurationError {}
    precondition(equal(load(), original))
    try ConfigurationTransaction.cancel(directory: recovery, current: load())
    try stage()
    do {
        _ = try ConfigurationTransaction.finish(directory: recovery, read: load, persist: { value in
            precondition(persist(value)); return false
        }, restore: { _ in false })
        fatalError("Expected rollback-failure rejection")
    } catch is ConfigurationError {}
    precondition(load()["appearance"] as? String == "dark")
    precondition(FileManager.default.fileExists(atPath: pending.path))
    try require(try Data(contentsOf: receipt) == beforeReceipt)
    precondition(persist(original)) // Repair only the deliberately failed synthetic backend.
    try ConfigurationTransaction.cancel(directory: recovery, current: load())
    print("CONTAINED_FALSE_SUCCESS_AND_ROLLBACK_FAILURE_RETAIN_BACKUP_OK")
case "changed-and-corrupt":
    let original = load()
    try stage()
    var changed = original; changed["appearance"] = "system"; precondition(persist(changed))
    do { _ = try finish(); fatalError("Expected changed-config rejection") } catch is ConfigurationError {}
    precondition(equal(load(), changed))
    precondition(persist(original))
    try ConfigurationTransaction.cancel(directory: recovery, current: load())
    try Data("invalid synthetic record".utf8).write(to: pending)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
    do { _ = try finish(); fatalError("Expected corrupt-record rejection") } catch {}
    precondition(equal(load(), original))
    precondition(FileManager.default.fileExists(atPath: pending.path))
    let future = Data("{\"format\":\"keylane.configuration\",\"schemaVersion\":999,\"preferences\":{}}".utf8)
    do { _ = try ConfigurationArchive.decode(future); fatalError("Expected future-version rejection") } catch is ConfigurationError {}
    precondition(equal(load(), original))
    print("CONTAINED_CHANGED_CORRUPT_FUTURE_REJECTION_OK")
default: fatalError("Unknown fixture phase")
}
