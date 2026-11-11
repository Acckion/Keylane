import AppKit
import Contacts
import KeylaneCore

let shortcutController = SystemShortcutsController()
func wait(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(20)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
    precondition(condition())
}
shortcutController.refresh(force: true)
wait { !shortcutController.loading }
precondition(shortcutController.message.isEmpty && !shortcutController.entries.isEmpty)
let identifier = UUID().uuidString
precondition(!shortcutController.entries.contains { $0.id == identifier })
var runFailure = false
shortcutController.onRunFailure = { _ in runFailure = true }
shortcutController.run(identifier)
wait { runFailure && shortcutController.runningID == nil }
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
print("PASS live Shortcuts discovery and missing-ID failure, system Dictionary lookup and empty result, contact field projection fixture")
