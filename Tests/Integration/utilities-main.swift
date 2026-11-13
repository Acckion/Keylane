import AppKit
import Contacts
import Darwin
import KeylaneCore

let shortcutController = SystemShortcutsController(loadsIcons: false)
func wait(_ description: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(20)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
    precondition(condition(), description)
}
let identifier = UUID().uuidString
if ProcessInfo.processInfo.environment["KEYLANE_UTILITIES_FIXTURE_ONLY"] != "1" {
    shortcutController.refresh(force: true)
    wait("native Shortcuts listing") { !shortcutController.loading }
    precondition(shortcutController.message.isEmpty && !shortcutController.entries.isEmpty)
    precondition(!shortcutController.entries.contains { $0.id == identifier })
    shortcutController.run(identifier)
    wait("native missing shortcut") { shortcutController.runningID == nil }
    precondition(shortcutController.executionMessage.contains("退出码"))
}
precondition(DictionaryController.definition(for: "apple")?.isEmpty == false)
precondition(DictionaryController.definition(for: "zzzzkeylanenotawordqzx") == nil)
let realDictionary = DictionaryController()
for term in ["apple", "苹果"] {
    realDictionary.search(term)
    wait("system dictionary lookup") { !realDictionary.loading }
    let matched = realDictionary.definition?.isEmpty == false
    if term == "apple" { precondition(matched) }
    print("Dictionary Services \(term): \(matched ? "matched" : "no match in active sources")")
}
let dictionary = DictionaryController { term in
    if term == "first" { Thread.sleep(forTimeInterval: 0.30) }
    return term == "missing" ? nil : "Definition for \(term)"
}
let dictionaryBoard = NSPasteboard.withUniqueName()
defer { dictionaryBoard.releaseGlobally() }
dictionary.search("first")
RunLoop.current.run(until: Date().addingTimeInterval(0.20))
dictionary.search("  中文  ")
precondition(dictionary.loading && !dictionary.canSubmit)
precondition(!dictionary.copyDefinition(for: "first", to: dictionaryBoard))
wait("latest dictionary query") { !dictionary.loading }
precondition(dictionary.term == "中文" && dictionary.definition == "Definition for 中文")
precondition(dictionary.copyDefinition(for: "中文", to: dictionaryBoard))
precondition(dictionaryBoard.string(forType: .string) == "Definition for 中文")
dictionary.search("missing")
wait("dictionary no match") { !dictionary.loading }
precondition(dictionary.canSubmit && dictionary.definition == nil)
dictionary.search(String(repeating: "词", count: 257))
precondition(dictionary.termTooLong && !dictionary.canSubmit && dictionary.definition == nil)
dictionary.search("first")
dictionary.search(" \n ")
precondition(dictionary.term.isEmpty && !dictionary.loading && dictionary.definition == nil)
dictionary.search("reopen")
wait("dictionary reopened") { !dictionary.loading }
precondition(dictionary.definition == "Definition for reopen")
precondition(!dictionary.copyDefinition(for: "中文", to: dictionaryBoard))
precondition(dictionaryBoard.string(forType: .string) == "Definition for 中文")
let termWithReservedCharacters = "中文 / café?#%"
let dictionaryURL = DictionaryController.dictionaryURL(for: termWithReservedCharacters)!
precondition(dictionaryURL.scheme == "dict" && dictionaryURL.query == nil && dictionaryURL.fragment == nil)
precondition(URLComponents(url: dictionaryURL, resolvingAgainstBaseURL: false)?.path == termWithReservedCharacters)
print("PASS Dictionary: latest query, cancel/reopen, missing and long input, encoded URL and isolated pasteboard")
let record = CNMutableContact()
record.givenName = "示例"
record.familyName = "测试"
record.organizationName = "Fixture"
record.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+1 555 0100"))]
record.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "fixture@example.invalid" as NSString)]
let summary = ContactSummary(contact: record)
precondition(summary.searchable.contains("15550100") && summary.emails == ["fixture@example.invalid"])
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("KeylaneShortcutsLifecycle-" + UUID().uuidString)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let executable = scratch.appendingPathComponent("shortcuts-fixture")
let pidFile = scratch.appendingPathComponent("pid")
let catalog = scratch.appendingPathComponent("catalog")
let exitCode = scratch.appendingPathComponent("exit-code")
let secondIdentifier = UUID().uuidString
try "Synthetic shortcut (\(identifier))\n".write(to: catalog, atomically: true, encoding: .utf8)
try """
#!/bin/sh
case "$1" in
list)
    /bin/cat '\(catalog.path)'
    ;;
run)
    printf '%s\\n' "$$" > '\(pidFile.path)'
    if [ ! -e '\(exitCode.path)' ]; then exec /bin/sleep 30; fi
    exit "$(/bin/cat '\(exitCode.path)')"
    ;;
esac
""".write(to: executable, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
let fixture = SystemShortcutsController(loadsIcons: false, active: false, executable: executable)
fixture.refresh(force: true)
precondition(!fixture.loading && fixture.entries.isEmpty)
fixture.start()
wait("synthetic Shortcuts listing") { fixture.entries.count == 1 }
try """
Duplicate (\(identifier))
Duplicate (\(secondIdentifier))
""".write(to: catalog, atomically: true, encoding: .utf8)
fixture.launcherShown()
wait("catalog adds duplicate title with distinct IDs") { fixture.entries.count == 2 }
precondition(fixture.duplicateTitles == ["Duplicate"])
precondition(fixture.entries.map(\.id) == [identifier, secondIdentifier].sorted())
let commandID = fixture.entries.first { $0.id == identifier }!.commandID
try "Renamed (\(identifier))\n".write(to: catalog, atomically: true, encoding: .utf8)
fixture.launcherShown()
wait("catalog removes old shortcut and preserves renamed identity") { fixture.entries.map(\.name) == ["Renamed"] }
precondition(fixture.entries.first?.commandID == commandID && fixture.duplicateTitles.isEmpty)
fixture.launcherHidden()
var feedback: [SystemShortcutsController.RunStatus] = []
fixture.run(identifier) { feedback.append($0) }
wait("synthetic workflow launch") { FileManager.default.fileExists(atPath: pidFile.path) }
let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
fixture.run(identifier) { feedback.append($0) }
precondition(feedback == [.started, .busy] && fixture.runningID == identifier)
fixture.stop()
wait("synthetic workflow termination") { kill(pid, 0) == -1 }
precondition(fixture.entries.isEmpty && fixture.runningID == nil && fixture.executionMessage.isEmpty)
fixture.start()
wait("synthetic Shortcuts listing") { fixture.entries.count == 1 }
let outcomes: [(Int, SystemShortcutsController.RunStatus)] = [(0, .completed), (7, .failed(7))]
for (code, expected) in outcomes {
    try String(code).write(to: exitCode, atomically: true, encoding: .utf8)
    feedback = []
    fixture.run(identifier) { feedback.append($0) }
    wait("synthetic exit status \(code)") { fixture.runningID == nil }
    precondition(feedback == [.started, expected])
}
fixture.stop()
print("PASS Shortcuts UUID across rename, duplicate names, add/remove, busy, completion, failure and lifecycle")
print("PASS system Dictionary lookup and empty result, and contact field projection fixture")
