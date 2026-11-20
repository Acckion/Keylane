#if DEBUG && KEYLANE_STORE_TICKET_ACCEPTANCE
import CryptoKit
import Darwin
import Foundation
import KeylaneCore

/// Authorized acceptance only. Standalone development executable; no app or
/// production bootstrap references this entry. Never uses host effects or Keychain.
@MainActor
enum TicketedAcceptance {
    private static let mode = "--ticketed-offline-acceptance"
    private static let marker = "keylane-ticketed-offline-ok"
    private static let recipeID = "test-noview-synthetic-v2"
    private static let archivedRuntimeDigest = "49e4f4b52293ef1582d26b35b156a2e0a427b9618b6cedb2c078f94438667121"
    private static let manifest = #"{"name":"keylane-ticket-acceptance","author":"fixture","title":"Ticketed Offline Acceptance","preferences":[{"name":"marker","title":"Marker","type":"textfield","required":true}],"commands":[{"name":"entry","title":"Entry","mode":"no-view"}]}"#
    private static let program = #"import {getPreferenceValues,showToast} from '@raycast/api'; export default async function(){if(getPreferenceValues().marker!=='keylane-ticketed-offline-ok')throw Error('fixture preference');await showToast({title:'keylane-ticketed-offline-ok'});}"#
    private static let projectSHA256 = "83584c6c5c63e451b6e3a5bdd4497fdf7ea1a8cd36cb1ae2c6014c867eadbd82"

    static func run(_ args: [String]) async -> Bool {
        var phase = "arguments"
        func require(_ valid: Bool) throws { guard valid else { throw FixtureFailure.invalid } }
        func emit(_ name: String, _ passed: Bool) {
            print("{\"scope\":\"ticketed-offline-synthetic\",\"phase\":\"\(name)\",\"passed\":\(passed)}")
        }
        do {
            try require(args.count == 6 && args[1] == mode && args[2] == "--sealed-probe")
            let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
            let path = URL(fileURLWithPath: args[3], isDirectory: true).resolvingSymlinksInPath()
            let leaf = Array(path.pathComponents.dropFirst(parent.pathComponents.count))
            try require(path.pathComponents.starts(with: parent.pathComponents) && leaf.count == 3 &&
                leaf[0].hasPrefix("keylane-store-ticket-acceptance.") && leaf[1] == "unpacked" &&
                leaf[2] == "KeylaneStorePackagingProbe.app")
            guard let application = Bundle(url: path) else { throw FixtureFailure.invalid }
            let team = args[4], digest = args[5]
            try require(team.utf8.count == 10 && team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }))
            try require(digest == archivedRuntimeDigest)

            phase = "fixture-pin"
            let (source, project) = try makeProject()
            let fixture = try RaycastStoreAppCapability.OfflineFixture(project: project, expectedDigest: projectSHA256)
            try require(fixture.index.slugs == [source.slug])
            _ = try fixture.details(slug: source.slug, revision: source.revision)
            emit(phase, true)

            phase = "disposable-scope"
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("keylane-ticket-registry-" + UUID().uuidString, isDirectory: true)
            try require(mkdir(root.path, S_IRWXU) == 0)
            defer { try? FileManager.default.removeItem(at: root) }
            let ownerPath = root.appendingPathComponent("store-authority.lock")
            let fd = open(ownerPath.path, O_RDWR | O_NOFOLLOW | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
            try require(fd >= 0)
            var rootInfo = stat(), fileInfo = stat()
            let valid = lstat(root.path, &rootInfo) == 0 && fstat(fd, &fileInfo) == 0
            close(fd)
            try require(valid)
            let profileID = UUID(), registryID = UUID()
            let binding = RaycastStoreProtectedReceiptState.OwnerBinding(profileID: profileID, rootPath: root.path,
                rootDevice: Int64(rootInfo.st_dev), rootInode: UInt64(rootInfo.st_ino),
                lockDevice: Int64(fileInfo.st_dev), lockInode: UInt64(fileInfo.st_ino))
            let signer = P256.Signing.PrivateKey() // Process ephemeral fixture artifact seal only.
            let recipe = RaycastStoreArtifactSeal.Recipe(identifier: recipeID, runtimeDigest: digest, qualifiedAPIVersions: [])
            let anchor = try RaycastStoreProtectedReceiptState(storage: FixtureAnchorStorage(), registryID: registryID,
                publicKey: signer.publicKey, recipe: recipe, owner: binding)
            try anchor.initializeNewRegistry(observedRegistryDigest: nil) // No platform enrollment claim.
            emit(phase, true)

            var toyEffects = 0
            func openCapability() async throws -> RaycastStoreAppCapability {
                try await RaycastStoreAppCapability.verifyNativeOfflineFixture(fixture, application: application,
                    expectedTeam: team, recipe: recipe, registryRoot: root, profileID: profileID, registryID: registryID,
                    anchor: anchor, ownerBinding: binding, publicKey: signer.publicKey,
                    sign: { try signer.signature(for: $0) }) { _, effect, body in
                        guard effect == "feedback.toast",
                              let payload = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
                              payload["operation"] as? String == "show", payload["title"] as? String == marker else {
                            throw FixtureFailure.invalid
                        }
                        toyEffects += 1
                        return ""
                    }
            }
            phase = "activate-verified-native-capability"
            // Scope the initial authority so the next coordinator must reacquire the lock.
            let installation = try await installAndConfigure(try await openCapability(), source: source)
            emit(phase, true)

            phase = "disk-reopen-and-ticketed-run"
            let reopened = try await openCapability()
            let coordinator = reopened.coordinator
            let restored = try await coordinator.installations()
            try require(restored.count == 1 && restored.first?.id == installation.id)
            guard let command = installation.manifest.commands.first else { throw FixtureFailure.invalid }
            try await coordinator.launch(installationID: installation.id, commandID: command.id)
            try require(toyEffects == 1)
            emit(phase, true)

            phase = "disable-and-uninstall"
            let disabled = try await coordinator.setEnabled(installationID: installation.id, enabled: false)
            try require(!disabled.enabled && disabled.generation == installation.generation + 1)
            try require(try await coordinator.launchReadiness(installationID: installation.id, commandID: command.id) == .runtimeUnavailable)
            try await coordinator.uninstall(installationID: installation.id)
            try require(try await coordinator.installations().isEmpty && toyEffects == 1)
            emit(phase, true)
            return true
        } catch {
            emit(phase, false)
            return false
        }
    }

    private static func installAndConfigure(_ capability: RaycastStoreAppCapability,
                                            source: RaycastStoreSource) async throws -> RaycastStoreInstallation {
        let coordinator = capability.coordinator
        let staged = try await coordinator.prepare(source)
        let installed = try await coordinator.install(staged)
        guard let command = installed.manifest.commands.first,
              try await coordinator.launchReadiness(installationID: installed.id, commandID: command.id) == .preferencesRequired
        else { throw FixtureFailure.invalid }
        var changes = RaycastStorePreferenceChanges()
        changes.values[.init(scope: .extensionWide, name: "marker")] = .set(.string(marker))
        try await coordinator.save(installationID: installed.id, generation: installed.generation, changes: changes)
        return installed
    }

    private static func makeProject() throws -> (RaycastStoreSource, RaycastStoreBuildProject) {
        let revision = String(repeating: "a", count: 40)
        let slug = "keylane-ticket-acceptance"
        let files = ["package.json": Data(manifest.utf8), "src/entry.ts": Data(program.utf8)]
        let tree = files.map { path, bytes -> [String: Any] in
            let blob = Insecure.SHA1.hash(data: Data("blob \(bytes.count)\0".utf8) + bytes)
                .map { String(format: "%02x", $0) }.joined()
            return ["path": path, "sha": blob, "size": bytes.count, "mode": "100644", "type": "blob"]
        } + [["path": "src", "sha": revision, "mode": "040000", "type": "tree"]]
        let source = try RaycastStoreSource(slug: slug, catalog: .init(revision: revision, slugs: [slug]))
        let snapshot = try RaycastStoreSnapshot(source: source, treeSHA: revision,
            recursiveTreeJSON: JSONSerialization.data(withJSONObject: ["sha": revision, "truncated": false, "tree": tree]))
        return (source, try .init(source: .init(snapshot: snapshot, files: files), supportedRuntimeAPIVersions: [], tarballs: [:]))
    }
}
#endif
