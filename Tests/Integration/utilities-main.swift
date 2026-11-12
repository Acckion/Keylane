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
try """
#!/bin/sh
if [ "$1" = list ]; then
    printf 'Synthetic shortcut (\(identifier))\\n'
else
    printf '%s\\n' "$$" > '\(pidFile.path)'
    exec /bin/sleep 30
fi
""".write(to: executable, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
let fixture = SystemShortcutsController(loadsIcons: false, active: false, executable: executable)
fixture.refresh(force: true)
precondition(!fixture.loading && fixture.entries.isEmpty)
fixture.start()
wait("synthetic Shortcuts listing") { fixture.entries.count == 1 }
fixture.run(identifier)
wait("synthetic workflow launch") { FileManager.default.fileExists(atPath: pidFile.path) }
let pid = pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
fixture.stop()
wait("synthetic workflow termination") { kill(pid, 0) == -1 }
precondition(fixture.entries.isEmpty && fixture.runningID == nil && fixture.executionMessage.isEmpty)
fixture.start()
wait("synthetic Shortcuts listing") { fixture.entries.count == 1 }
fixture.stop()
print("PASS Shortcuts process cancellation, catalog release, disabled startup and restart")
print("PASS system Dictionary lookup and empty result, and contact field projection fixture")
