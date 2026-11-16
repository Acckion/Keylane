import Foundation
import XCTest
@testable import KeylaneCore

final class ConfigurationMappingTests: XCTestCase {
    private let q = Shortcut(key: 12, modifiers: 2048)
    private let w = Shortcut(key: 13, modifiers: 2048)
    private let e = Shortcut(key: 14, modifiers: 2048)
    private let r = Shortcut(key: 15, modifiers: 2048)

    private func shortcuts(_ incoming: [String: Shortcut], over old: [String: Shortcut], overwrite: Bool = true) throws
        -> (ConfigurationArchive.Plan, [String: Shortcut]) {
        var archive = ConfigurationArchive(); archive.shortcuts = incoming
        let original = try JSONEncoder().encode(old)
        let plan = try archive.plan(current: ["shortcuts": original], overwrite: overwrite)
        let result = try JSONDecoder().decode([String: Shortcut].self, from: plan.changes["shortcuts"] as? Data ?? original)
        return (plan, result)
    }

    func testQuicklinkSnippetValidationUsesProvidedContext() throws {
        var archive = ConfigurationArchive()
        archive.quicklinks = [Quicklink(title: "Synthetic", template: "https://example.com/?q={snippet name=Greeting}")]
        XCTAssertThrowsError(try archive.plan(current: [:], overwrite: true))
        var context = DynamicTemplate.Context()
        context.snippet = { $0 == "Greeting" ? "hello" : nil }
        XCTAssertNotNil(try archive.plan(current: [:], overwrite: true, templateContext: context).changes[QuicklinkLibrary.storageKey])
        context.snippet = { _ in "{snippet name=Other}" }
        XCTAssertThrowsError(try archive.plan(current: [:], overwrite: true, templateContext: context))
    }

    func testDeduplicatedQuicklinkRemapsReferencesAndRepeatsWithoutChanges() throws {
        let retained = Quicklink(title: "Synthetic", template: "https://example.com/")
        let duplicate = Quicklink(title: retained.title, template: retained.template)
        var archive = ConfigurationArchive()
        archive.quicklinks = [duplicate]
        archive.aliases = [duplicate.id: "synthetic"]
        archive.shortcuts = [duplicate.id: q]
        archive.disabledCommands = [duplicate.id]
        let initial: [String: Any] = [QuicklinkLibrary.storageKey: try JSONEncoder().encode(QuicklinkLibrary(links: [retained])),
                                     "shortcuts": try JSONEncoder().encode([String: Shortcut]())]
        let plan = try archive.plan(current: initial, overwrite: true)
        XCTAssertNil(plan.changes[QuicklinkLibrary.storageKey])
        XCTAssertEqual(plan.changes["aliases"] as? [String: String], [retained.id: "synthetic"])
        XCTAssertEqual(try JSONDecoder().decode([String: Shortcut].self, from: XCTUnwrap(plan.changes["shortcuts"] as? Data)), [retained.id: q])
        XCTAssertEqual(plan.changes["disabledLauncherCommands"] as? [String], [retained.id])
        let applied = initial.merging(plan.changes) { _, new in new }
        XCTAssertTrue(try archive.plan(current: applied, overwrite: true).changes.isEmpty)
        archive.disabledCommands = nil; archive.commandEnabled = [duplicate.id: true]
        XCTAssertEqual(try archive.plan(current: applied, overwrite: true).changes["disabledLauncherCommands"] as? [String], [])
    }

    func testRemappedQuicklinkMappingsRespectExistingConflictsAndCanonicalEntry() throws {
        let retained = Quicklink(title: "Synthetic", template: "https://example.com/")
        let duplicate = Quicklink(title: retained.title, template: retained.template)
        var archive = ConfigurationArchive(); archive.quicklinks = [duplicate]
        archive.aliases = [duplicate.id: "new"]
        archive.shortcuts = [duplicate.id: w]
        let initial: [String: Any] = [QuicklinkLibrary.storageKey: try JSONEncoder().encode(QuicklinkLibrary(links: [retained])),
            "aliases": [retained.id: "old"], "shortcuts": try JSONEncoder().encode([retained.id: q, "reserved": w])]
        XCTAssertTrue(try archive.plan(current: initial, overwrite: false).changes.isEmpty)
        let overwrite = try archive.plan(current: initial, overwrite: true)
        XCTAssertEqual(overwrite.changes["aliases"] as? [String: String], [retained.id: "new"])
        XCTAssertNil(overwrite.changes["shortcuts"])
        archive.aliases = [duplicate.id: "discarded", retained.id: "canonical"]
        archive.shortcuts = [duplicate.id: e, retained.id: r]
        let canonical = try archive.plan(current: initial, overwrite: true)
        XCTAssertEqual(canonical.changes["aliases"] as? [String: String], [retained.id: "canonical"])
        XCTAssertEqual(try JSONDecoder().decode([String: Shortcut].self, from: XCTUnwrap(canonical.changes["shortcuts"] as? Data)), [retained.id: r, "reserved": w])
    }

    func testDuplicateQuicklinksWithinArchiveShareOneStableIdentity() throws {
        let first = Quicklink(title: "Synthetic", template: "https://example.com/")
        let second = Quicklink(title: first.title, template: first.template)
        var archive = ConfigurationArchive(); archive.quicklinks = [first, second]
        archive.aliases = [second.id: "synthetic"]
        archive.shortcuts = [second.id: q]
        let current: [String: Any] = ["shortcuts": try JSONEncoder().encode([String: Shortcut]())]
        let plan = try archive.plan(current: current, overwrite: true)
        XCTAssertEqual(try JSONDecoder().decode(QuicklinkLibrary.self, from: XCTUnwrap(plan.changes[QuicklinkLibrary.storageKey] as? Data)).links, [first])
        XCTAssertEqual(plan.changes["aliases"] as? [String: String], [first.id: "synthetic"])
        XCTAssertEqual(try JSONDecoder().decode([String: Shortcut].self, from: XCTUnwrap(plan.changes["shortcuts"] as? Data)), [first.id: q])
        XCTAssertTrue(try archive.plan(current: current.merging(plan.changes) { _, new in new }, overwrite: true).changes.isEmpty)
    }

    func testOverwriteHotkeySwapAndThreeWayCycleAreFinalStateValidAndIdempotent() throws {
        let old = ["a": q, "b": w, "c": e]
        for incoming in [["a": w, "b": q], ["a": w, "b": e, "c": q]] {
            let (plan, actual) = try shortcuts(incoming, over: old)
            XCTAssertEqual(actual, old.merging(incoming) { _, new in new })
            XCTAssertEqual(plan.omitted, 0)
            XCTAssertEqual(plan.conflicts, incoming.count)
            XCTAssertNil(ShortcutValidation.conflict(in: actual))
            let (repeated, unchanged) = try shortcuts(incoming, over: actual)
            XCTAssertTrue(repeated.changes.isEmpty)
            XCTAssertEqual(repeated.omitted, 0)
            XCTAssertEqual(repeated.conflicts, 0)
            XCTAssertEqual(unchanged, actual)
        }
    }

    func testUncoveredHotkeyOwnerStillBlocksCollisionWithoutBlockingIndependentImport() throws {
        let old = ["a": q, "b": w, "retained": e]
        let (plan, actual) = try shortcuts(["a": e, "new": r], over: old)
        XCTAssertEqual(actual, old.merging(["new": r]) { _, new in new })
        XCTAssertEqual(plan.omitted, 1)
        XCTAssertNil(ShortcutValidation.conflict(in: actual))
    }

    func testRejectedHotkeyRestoresReservationAndRejectsDependentUpdate() throws {
        let old = ["a": q, "b": w, "retained": e]
        let incoming = ["a": w, "b": e, "new": r]
        let (plan, actual) = try shortcuts(incoming, over: old)
        XCTAssertEqual(actual, old.merging(["new": r]) { _, new in new })
        XCTAssertEqual(plan.omitted, 2)
        XCTAssertNil(ShortcutValidation.conflict(in: actual))
        XCTAssertTrue(try shortcuts(incoming, over: actual).0.changes.isEmpty)
    }

    func testLongBlockedChainDoesNotDependOnCommandSortingOrder() throws {
        var old: [String: Shortcut] = ["retained": Shortcut(key: 120, modifiers: 2048)]
        var incoming: [String: Shortcut] = ["independent": Shortcut(key: 125, modifiers: 2048)]
        for i in 0..<64 {
            old["command\(i)"] = Shortcut(key: UInt32(i), modifiers: 2048)
            incoming["command\(i)"] = Shortcut(key: i == 63 ? 120 : UInt32(i + 1), modifiers: 2048)
        }
        let (plan, actual) = try shortcuts(incoming, over: old)
        XCTAssertEqual(actual, old.merging(["independent": Shortcut(key: 125, modifiers: 2048)]) { _, new in new })
        XCTAssertEqual(plan.omitted, 64)
        XCTAssertNil(ShortcutValidation.conflict(in: actual))
        XCTAssertTrue(try shortcuts(incoming, over: actual).0.changes.isEmpty)
    }

    func testPreserveHotkeyPolicyKeepsOldBindingsAndTheirReservations() throws {
        let old = ["a": q, "b": w]
        let (swap, swapped) = try shortcuts(["a": w, "b": q], over: old, overwrite: false)
        XCTAssertTrue(swap.changes.isEmpty)
        XCTAssertEqual(swap.conflicts, 2)
        XCTAssertEqual(swapped, old)
        let (plan, actual) = try shortcuts(["a": w, "blocked": q, "new": r], over: old, overwrite: false)
        XCTAssertEqual(actual, old.merging(["new": r]) { _, new in new })
        XCTAssertEqual(plan.omitted, 1)
        XCTAssertEqual(plan.conflicts, 1)
    }

    func testAliasSwapsAndCyclesUseTheFinalMappingAndRepeatWithoutChanges() throws {
        let old = ["a": "one", "b": "two", "c": "three", "retained": "keep"]
        for incoming in [["a": "two", "b": "one"], ["a": "two", "b": "three", "c": "one"]] {
            var archive = ConfigurationArchive(); archive.aliases = incoming
            let plan = try archive.plan(current: ["aliases": old], overwrite: true)
            let actual = try XCTUnwrap(plan.changes["aliases"] as? [String: String])
            XCTAssertEqual(actual, old.merging(incoming) { _, new in new })
            XCTAssertEqual(plan.omitted, 0)
            XCTAssertTrue(try archive.plan(current: ["aliases": actual], overwrite: true).changes.isEmpty)
            XCTAssertTrue(try archive.plan(current: ["aliases": old], overwrite: false).changes.isEmpty)
        }
    }

    func testRetainedAliasesAndRejectedUpdatesStillReserveCaseInsensitiveNames() throws {
        let old = ["a": "one", "b": "two", "retained": "taken"]
        var archive = ConfigurationArchive(); archive.aliases = ["a": "TWO", "b": "TAKEN", "new": "fresh"]
        let plan = try archive.plan(current: ["aliases": old], overwrite: true)
        XCTAssertEqual(plan.changes["aliases"] as? [String: String], old.merging(["new": "fresh"]) { _, new in new })
        XCTAssertEqual(plan.omitted, 2)
        archive.aliases = ["a": "two", "blocked": "ONE"]
        let preserve = try archive.plan(current: ["aliases": old], overwrite: false)
        XCTAssertTrue(preserve.changes.isEmpty)
        XCTAssertEqual(preserve.omitted, 1)
    }

    func testAliasDuplicateSelectionKeepsSemanticOwnerAndStableOrdering() throws {
        var archive = ConfigurationArchive(); archive.aliases = ["a": "foo", "b": "FOO"]
        let owner = try archive.plan(current: ["aliases": ["b": "foo"]], overwrite: true)
        XCTAssertEqual(owner.changes["aliases"] as? [String: String], ["b": "FOO"])
        XCTAssertEqual(owner.omitted, 1)
        let fresh = try archive.plan(current: ["aliases": [String: String]()], overwrite: true)
        XCTAssertEqual(fresh.changes["aliases"] as? [String: String], ["a": "foo"])
        XCTAssertEqual(fresh.omitted, 1)
    }
}
