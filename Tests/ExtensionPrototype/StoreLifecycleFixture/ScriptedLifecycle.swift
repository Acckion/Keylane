import Darwin
import Foundation

@main @MainActor
enum StoreLifecycleEntry {
    static func main() async {
        let arguments = CommandLine.arguments
        let mode = arguments.dropFirst().first
        if mode == "--ticketed-offline-acceptance" {
            #if DEBUG && KEYLANE_STORE_TICKET_ACCEPTANCE
            Darwin.exit(await TicketedAcceptance.run(arguments) ? 0 : 1)
            #else
            Darwin.exit(64)
            #endif
        }
        guard mode == "--scripted" || mode == "--preflight-only" else {
            StoreLifecycleFixtureLauncher.main()
            return
        }
        let argumentsForFixture = [arguments[0]] + arguments.dropFirst(2)
        let result = await ScriptedLifecycle().run(arguments: argumentsForFixture, preflightOnly: mode == "--preflight-only")
        Darwin.exit(result ? 0 : 1)
    }
}

/// Finite, explicit phases over the same model/service as the fixture window.
/// Never dump arbitrary errors, paths, bundle identities or project content.
@MainActor
private struct ScriptedLifecycle {
    private struct Receipt: Encodable {
        let schema = 2
        let scope = "signed-self-authored-fixture"
        let persistence = "same-process-disk-reopen"
        let phase: String
        let preflight: FixtureModel.Preflight?
        let passed: Bool
        let generation: UInt64?
        let enabled: Bool?
        let artifactSHA256: String?
        let buildCount: Int
        let confirmedRunCount: Int
        let copyCount: Int
        let hudCount: Int
    }

    func run(arguments: [String], preflightOnly: Bool) async -> Bool {
        let model = FixtureModel()
        await model.configure(arguments: arguments)
        guard emit("verified-helper-preflight", model.ready, model) else { return false }
        // This controlled mode stops even when signed resources and service pass.
        if preflightOnly { return true }

        let installed = await model.act(.install)
        let id = model.receipt?.id
        let built = installed && id != nil && model.observe.buildCount == 1 && model.observe.builtArtifactDigest != nil
        guard emit("build", built, model), emit("install", model.receipt?.generation == 1 && model.receipt?.enabled == true, model) else {
            return false
        }

        let needsPreferences = await model.confirmsLaunchDenial(.preferencesRequired)
        guard emit("missing-config-blocked", needsPreferences, model) else { return false }
        let configured = await model.act(.configure)
        guard emit("configure", configured && model.configured, model) else { return false }
        let ran = await model.act(.run)
        guard emit("run", ran && model.observe.confirmedRunCount == 1 && model.observe.copyCount == 1 && model.observe.hudCount == 1, model) else { return false }
        let reopened = await model.act(.reopen)
        guard emit("disk-reopen", reopened && model.receipt?.id == id && model.receipt?.generation == 1 && model.configured, model) else {
            return false
        }

        let disabled = await model.act(.toggle)
        guard emit("disable", disabled && model.receipt?.generation == 2 && model.receipt?.enabled == false, model) else { return false }
        let blocked = await model.confirmsLaunchDenial(.notInstalled)
        guard emit("disabled-run-blocked", blocked, model) else { return false }
        let enabled = await model.act(.toggle)
        guard emit("reenable", enabled && model.receipt?.generation == 3 && model.receipt?.enabled == true, model) else { return false }
        let reran = await model.act(.run)
        guard emit("run-after-reenable", reran && model.observe.confirmedRunCount == 2 && model.observe.copyCount == 2 && model.observe.hudCount == 2 &&
                   model.observe.buildCount == 1, model) else { return false }

        let removed = await model.act(.uninstall)
        guard emit("uninstall", removed && model.receipt == nil && !model.configured, model) else { return false }
        let empty = await model.act(.reopen)
        return emit("disk-reopen-empty", empty && model.receipt == nil && model.observe.confirmedRunCount == 2, model)
    }

    @discardableResult
    private func emit(_ phase: String, _ passed: Bool, _ model: FixtureModel) -> Bool {
        let facts = model.observe
        let receipt = Receipt(phase: phase, preflight: phase == "verified-helper-preflight" ? model.lastPreflight : nil,
                              passed: passed, generation: model.receipt?.generation, enabled: model.receipt?.enabled,
                              artifactSHA256: phase == "build" ? facts.builtArtifactDigest : nil, buildCount: facts.buildCount,
                              confirmedRunCount: facts.confirmedRunCount, copyCount: facts.copyCount, hudCount: facts.hudCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(receipt), encoded.count < 1_024 else { return false }
        FileHandle.standardOutput.write(encoded + Data([0x0a]))
        return passed
    }
}
