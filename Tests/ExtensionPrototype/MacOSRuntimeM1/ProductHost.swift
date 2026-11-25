import CryptoKit
import Foundation
import Security
import Darwin
#if M1_LINKED_CORE
import KeylaneCore
#endif

// Test-only signed native application. No test mode exists in the product app.
@main enum M1ProductHost {
    static let hostID = "org.keylane.tests.runtime-m1.product-host"
    static func emit(_ value: [String: Bool]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
    static func main() async {
        do { try await run() } catch {
            try? FileHandle.standardError.write(contentsOf:Data("First-party failure: \(error)\n".utf8))
            emit(["unexpectedFailure":true]); exit(70)
        }
    }
    static func run() async throws {
        guard CommandLine.arguments.count == 3 else { exit(71) }
        let mode = CommandLine.arguments[1], task = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
        guard task.path.hasPrefix("/private/tmp/keylane-m1-product-") || task.path.hasPrefix("/tmp/keylane-m1-product-") else { exit(71) }
        let intent = task.appendingPathComponent("cleanup.json")
        if mode == "forge-legacy-profile" {
            // A foreign native process chooses every trust field and explicitly
            // grants the real host access. An ACL read proves access, not origin.
            let id = UUID(), root = task.appendingPathComponent(id.uuidString)
            var ids = (try? JSONDecoder().decode([UUID].self,from:Data(contentsOf:intent))) ?? []
            ids.append(id); try JSONEncoder().encode(ids).write(to:intent,options:.atomic)
            guard mkdir(root.path,0o700) == 0 else { exit(70) }
            func identity(_ url: URL) throws -> [String:Any] {
                var info = stat(); guard lstat(url.path,&info) == 0 else { throw CocoaError(.fileReadUnknown) }
                return ["device":Int64(info.st_dev),"inode":info.st_ino]
            }
            for name in ["store-authority.lock","receipt-authority.lock","build.lock"] {
                let fd = open(root.appendingPathComponent(name).path,O_CREAT|O_EXCL|O_WRONLY,0o600)
                guard fd >= 0 else { exit(70) }; close(fd)
            }
            let host = task.appendingPathComponent("Host.app/Contents/MacOS/host")
            let config = try JSONSerialization.jsonObject(with:Data(contentsOf:task.appendingPathComponent("Host.app/Contents/Resources/ExtensionBuild.json"))) as! [String:Any]
            let record: [String:Any] = ["phase":"enrolled","id":id.uuidString,"host":host.path,"recipe":config["recipe"]!,
                "root":root.path,"directory":try identity(root),"owner":try identity(root.appendingPathComponent("store-authority.lock")),
                "receiptLock":try identity(root.appendingPathComponent("receipt-authority.lock")),
                "buildLock":try identity(root.appendingPathComponent("build.lock")),"key":P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()]
            var trusted: SecTrustedApplication?, access: SecAccess?
            guard SecTrustedApplicationCreateFromPath(host.path,&trusted) == errSecSuccess, let trusted,
                  SecAccessCreate("Keylane synthetic foreign-origin control" as CFString,[trusted] as CFArray,&access) == errSecSuccess, let access else { exit(70) }
            var q = legacyQuery(id,suffix:"profile"); q[kSecAttrAccess as String] = access
            q[kSecValueData as String] = try JSONSerialization.data(withJSONObject:record)
            guard SecItemAdd(q as CFDictionary,nil) == errSecSuccess else { exit(70) }
            var protected = query(id,suffix:"profile"); protected[kSecValueData as String] = Data("foreign-origin control".utf8)
            let createStatus = SecItemAdd(protected as CFDictionary,nil)
            let updateStatus = SecItemUpdate(query(ids[0],suffix:"profile") as CFDictionary,
                                            [kSecValueData as String:Data("foreign replacement control".utf8)] as CFDictionary)
            emit(["foreignProfileCreated":true,
                  "foreignProtectedCreateDenied":createStatus == errSecMissingEntitlement,
                  "foreignProtectedUpdateDenied":updateStatus == errSecMissingEntitlement]); return
        }
        if mode == "adopt-forged-profile" {
            let ids = try JSONDecoder().decode([UUID].self,from:Data(contentsOf:intent))
            guard let id = ids.last else { exit(70) }
            var legacy = legacyQuery(id,suffix:"profile"); legacy[kSecReturnData as String] = true
            var legacyData: CFTypeRef?
            let legacyReadable = SecItemCopyMatching(legacy as CFDictionary,&legacyData) == errSecSuccess
            var denied = false
            do {
                let forged = try MacOSBuildProfile.open(id:id,application:.main,hostIdentifier:hostID)
                _ = try forged.sign(Data("synthetic foreign origin".utf8))
            } catch { denied = true }
            emit(["foreignLegacyReadableByHost":legacyReadable,"foreignProfileRejected":denied]); return
        }
        if mode == "setup" || mode == "runtime-setup" {
            if mode == "runtime-setup" {
                try MacOSBuildProfile.verifyRuntimeConfiguration(application: .main, hostIdentifier: hostID)
            }
            let approval = try MacOSBuildProfile.Approval(userConfirmed:true)
            // Intent precedes ANY native Keychain write. Keep this signed app if
            // deletion fails; never erase the recovery identity after a failure.
            try JSONEncoder().encode([approval.profileID]).write(to:intent,options:.withoutOverwriting)
            let root = task.appendingPathComponent(approval.profileID.uuidString)
            let profile = try await MacOSBuildProfile.enroll(approval,root:root,application:.main,hostIdentifier:hostID)
            var replay = false
            do { _ = try await MacOSBuildProfile.enroll(approval,root:root,application:.main,hostIdentifier:hostID) } catch { replay = true }
            emit(["enrolled": profile.id == approval.profileID, "approvalReplayRejected": replay]); return
        }
        let ids = try JSONDecoder().decode([UUID].self,from:Data(contentsOf:intent))
        if mode == "cleanup" {
            let manifest = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ExtensionBuild.json")
            let configuration = try JSONDecoder().decode(MacOSBuildProfile.Configuration.self, from: Data(contentsOf: manifest))
            for id in ids {
                for suffix in ["head", "profile"] {
                    var queries = [query(id, suffix: suffix), legacyQuery(id, suffix: suffix)]
                    if configuration.storage == "legacy-login-keychain-preview-v1" {
                        var preview = legacyQuery(id, suffix: suffix)
                        preview[kSecAttrService as String] = "org.keylane.extension-build.legacy-preview.v1." + signingTeam() + "." + hostID
                        queries = [preview]
                    }
                    for query in queries {
                        let result = SecItemDelete(query as CFDictionary)
                        guard result == errSecSuccess || result == errSecItemNotFound else { emit(["cleanupFailed": true]); exit(74) }
                    }
                }
            }
            try FileManager.default.removeItem(at:intent); emit(["cleaned":true]); return
        }
        guard !ids.isEmpty else { exit(71) }; let id = ids[0]
        if mode == "no-provision" {
            var denied = false
            do { _ = try MacOSBuildProfile.open(id:id,application:.main,hostIdentifier:hostID) }
            catch MacOSBuildProfile.Failure.identity { denied = true }
            emit(["unprovisionedHostRejected":denied]); return
        }
        if mode == "foreign" {
            SecKeychainSetUserInteractionAllowed(false) // this test process only
            var q = query(id,suffix:"profile"); q[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary,&result)
            emit(["foreignReadDenied": status == errSecMissingEntitlement]); return
        }
        if mode == "copy" {
            var denied = false
            do { _ = try MacOSBuildProfile.open(id:id,application:.main,hostIdentifier:hostID) } catch { denied = true }
            emit(["copiedHostRejected":denied]); return
        }
        if mode == "tamper" {
            var denied = false
            do { _ = try MacOSBuildProfile.open(id:id,application:.main,hostIdentifier:hostID) } catch { denied = true }
            emit(["tamperedToolchainRejected":denied]); return
        }
        if mode == "official-lorem-markdown" || mode == "official-lorem-markdown-restart" {
            try await exerciseOfficialLoremMarkdown(profileID: id, restarting: mode.hasSuffix("-restart"))
            return
        }
        if mode == "official-silent-mention" || mode == "official-silent-mention-restart" {
            try await exerciseOfficialSilentMention(profileID: id, restarting: mode.hasSuffix("-restart"))
            return
        }
        if mode == "official-uuid-run" || mode == "official-uuid-restart" {
            try await exerciseOfficialUUID(profileID: id, restarting: mode == "official-uuid-restart")
            return
        }
        let profile = try MacOSBuildProfile.open(id:id,application:.main,hostIdentifier:hostID)
        if mode == "hold-build-lock" {
            let fd = try profile.acquireBuildLock(); defer { flock(fd, LOCK_UN); close(fd) }
            try FileHandle.standardOutput.write(contentsOf:Data("{\"lockHeld\":true}\n".utf8))
            let end = ContinuousClock.now + .seconds(15)
            while !FileManager.default.fileExists(atPath:task.appendingPathComponent("release-lock").path), ContinuousClock.now < end {
                try await Task.sleep(for:.milliseconds(10))
            }
            return
        }
        if mode == "lock-busy" {
            var denied = false
            do { let fd = try profile.acquireBuildLock(); flock(fd, LOCK_UN); close(fd) }
            catch MacOSExtensionBuild.Failure.busy { denied = true }
            emit(["crossProcessBuildLock":denied]); return
        }
        let service = try MacOSStoreBuildInstallationService(profile:profile)
        let backend = try RaycastStoreInstallCoordinator(root:profile.root,service:service,anchor:profile.anchor,requiresExistingRoot:true,
            acquireProject: { source,_ in try project(source) })
        if mode == "runtime-service" {
            let installer = RaycastStoreInstaller(backend: backend)
            var unsupportedCommandDenied = false
            do { _ = try await installer.prepareAndInstall(source("a")) }
            catch RaycastStoreInstaller.Failure.noRunnableCommands {
                unsupportedCommandDenied = try await backend.installations().isEmpty
            }
            let installed = try await installer.prepareAndInstall(source("f"))
            let commandID = installed.manifest.commands[0].id
            let readiness = try await backend.launchReadiness(installationID: installed.id, commandID: commandID)
            try await backend.launch(installed, commandID: commandID)
            _ = try await backend.setEnabled(installationID: installed.id, enabled: false)
            _ = try await backend.setEnabled(installationID: installed.id, enabled: true)
            var staleLauncherCommandDenied = false
            do { try await backend.launch(installed, commandID: commandID) }
            catch RaycastStoreDiskRegistry.Failure.stale { staleLauncherCommandDenied = true }
            var competingHostDenied = false
            do { _ = try MacOSStoreBuildInstallationService(profile: profile) }
            catch RaycastStoreDiskRegistry.Failure.busy { competingHostDenied = true }
            emit(["signedProfileDispatch": readiness == .ready, "competingServiceDenied": competingHostDenied,
                  "staleLauncherCommandDenied": staleLauncherCommandDenied,
                  "unsupportedCommandDeniedBeforeInstall": unsupportedCommandDenied])
            return
        }
        if mode == "runtime-restart" {
            let installer = RaycastStoreInstaller(backend: backend)
            let list = try await installer.refreshInstalled()
            guard list.count == 1, let installed = list.first,
                  installed.source == (try source("f")), let command = installed.manifest.commands.first else { exit(70) }
            try await installer.launch(slug: installed.source.slug, commandID: command.id)
            try await installer.setEnabled(slug: installed.source.slug, enabled: false)
            let disabled = try await installer.launchReadiness(slug: installed.source.slug, commandID: command.id)
            try await installer.setEnabled(slug: installed.source.slug, enabled: true)
            try await installer.launch(slug: installed.source.slug, commandID: command.id)
            try await installer.uninstall(slug: installed.source.slug)
            let empty = try await backend.installations().isEmpty
            emit(["restartDispatch": true, "disabledCommandDenied": disabled != .ready, "uninstallRecorded": empty])
            return
        }
        if mode == "runtime-after-uninstall" {
            let empty = try await RaycastStoreInstaller(backend: backend).refreshInstalled().isEmpty
            emit(["uninstallPersistsAfterRestart": empty])
            return
        }
        if mode == "build" {
            let first = try source("a"), second = try source("b")
            let installer = RaycastStoreInstaller(backend:backend)
            let installed = try await installer.prepareAndInstall(first)
            let command = installed.manifest.commands[0].id
            var changes = RaycastStorePreferenceChanges()
            changes.values[.init(scope:.extensionWide,name:"label")] = .set(.string("kept"))
            try await backend.save(installationID:installed.id,generation:installed.generation,changes:changes)
            let staged = try await backend.prepareUpdate(second,replacing:installed)
            let during = try await backend.installations()
            let b = try await installer.prepareAndUpdate(second,replacing:installed)
            let preferences = try await backend.load(installationID:b.id,generation:b.generation)
            let ready = try await backend.launchReadiness(installationID:b.id,commandID:command)
            var runDenied = false
            do { try await backend.launch(installationID:b.id,commandID:command) } catch { runDenied = true }
            emit(["realBuildAndInstall":installed.generation == 1 && installed.enabled,
                  "oldActiveDuringStaging":during.count == 1 && during[0].generation == 1 && during[0].source == first && staged.id == installed.id,
                  "atomicReplacement":b.id == installed.id && b.generation == 2 && b.source == second,
                  "preferencesPreserved":preferences.values[.init(scope:.extensionWide,name:"label")] == .string("kept"),
                  "executionStillClosed":ready == .runtimeUnavailable && runDenied]); return
        }
        if mode == "restart" {
            let list = try await backend.installations()
            let expected = try source("b")
            emit(["restartPersistent":list.count == 1 && list[0].generation == 2 && list[0].source == expected]); return
        }
        if mode == "cancel" {
            let source = try source("d")
            let old = try await backend.installations()[0]
            let operation = Task { try await backend.prepareUpdate(source,replacing:old) }
            let signal = task.appendingPathComponent("cancel-now")
            let end = ContinuousClock.now + .seconds(15)
            while !FileManager.default.fileExists(atPath:signal.path), ContinuousClock.now < end {
                try await Task.sleep(for:.milliseconds(5))
            }
            operation.cancel()
            var cancelled = false
            do { _ = try await operation.value } catch is CancellationError { cancelled = true } catch {}
            let list = try await backend.installations()
            emit(["realCompilerCancelled":cancelled,"oldPreservedAfterCancellation":list.count == 1 && list[0].generation == 2]); return
        }
        if mode == "build-failure" {
            var rejected = false
            let old = try await backend.installations()[0]
            do { _ = try await backend.prepareUpdate(source("e"),replacing:old) } catch { rejected = true }
            let list = try await backend.installations()
            emit(["oldPreservedAfterCompilerFailure":rejected && list.count == 1 && list[0].generation == 2]); return
        }
        if mode == "cas" || mode == "cas-recover" {
            let live = profile.root.appendingPathComponent("registry.json")
            let original = try Data(contentsOf:live)
            var object = try JSONSerialization.jsonObject(with:original) as! [String:Any]
            var records = object["records"] as! [[String:Any]]
            let nextGeneration = (records[0]["generation"] as! Int) + 1
            records[0]["generation"] = nextGeneration; records[0]["enabled"] = false; object["records"] = records
            let next = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
            if mode == "cas" {
                var success = false
                do { try profile.anchor.advance(previousDigest:MacOSExtensionBuild.hash(original),to:MacOSExtensionBuild.hash(next)); success = true } catch {}
                emit(["casAdvanced":success]); return
            }
            try next.write(to:profile.root.appendingPathComponent("registry.pending"),options:.withoutOverwriting)
            let installer = RaycastStoreInstaller(backend:backend)
            try await installer.reconcile(slug:"m1-product-fixture")
            let list = await installer.installedList()
            emit(["crossProcessCASRecoverable":list[0].generation == UInt64(nextGeneration) && !FileManager.default.fileExists(atPath:profile.root.appendingPathComponent("registry.pending").path)]); return
        }
        if mode == "recovery" {
            let live = profile.root.appendingPathComponent("registry.json"), pending = profile.root.appendingPathComponent("registry.pending")
            let original = try Data(contentsOf:live)
            var object = try JSONSerialization.jsonObject(with:original) as! [String:Any]
            var records = object["records"] as! [[String:Any]]
            records[0]["generation"] = 3; records[0]["enabled"] = false; object["records"] = records
            let next = try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
            try next.write(to:pending,options:.withoutOverwriting)
            let discarded = try await backend.recoverPendingPublication()
            let old = try await backend.installations()
            try next.write(to:pending,options:.withoutOverwriting)
            try profile.anchor.advance(previousDigest:MacOSExtensionBuild.hash(original),to:MacOSExtensionBuild.hash(next))
            let reopened = try await MacOSStoreBuildInstallationService.open(id:id,application:.main,hostIdentifier:hostID)
            let current = try await reopened.installations()
            try original.write(to:live)
            var rollback = false
            do { _ = try await reopened.installations() } catch { rollback = true }
            try next.write(to:live)
            emit(["uncommittedPublicationDiscarded":discarded == .discardedUncommitted && old[0].generation == 2,
                  "committedPublicationRecovered":current[0].generation == 3 && !current[0].enabled && !FileManager.default.fileExists(atPath:pending.path),
                  "registryRollbackRejected":rollback]); return
        }
        if mode == "missing" {
            guard SecItemDelete(query(id,suffix:"head") as CFDictionary) == errSecSuccess else { exit(70) }
            var headDenied = false
            do { _ = try await MacOSStoreBuildInstallationService.open(id:id,application:.main,hostIdentifier:hostID) } catch { headDenied = true }
            guard SecItemDelete(query(id,suffix:"profile") as CFDictionary) == errSecSuccess else { exit(70) }
            var profileDenied = false, cachedDenied = false
            do { _ = try MacOSBuildProfile.open(id:id,application:.main,hostIdentifier:hostID) } catch { profileDenied = true }
            do { _ = try profile.sign(Data("must-not-sign".utf8)) } catch { cachedDenied = true }
            emit(["missingHeadNoReset":headDenied,"missingProfileNoReset":profileDenied,"cachedSignerRevoked":cachedDenied]); return
        }
        exit(71)
    }
    static func signingTeam() -> String {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue:kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String:Any], let team = info[kSecCodeInfoTeamIdentifier as String] as? String else { exit(71) }
        return team
    }
    static func query(_ id: UUID, suffix: String) -> [String:Any] {
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.keylane.extension-build.protected.v2",
                kSecAttrAccount as String:id.uuidString+":"+suffix,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail,
                kSecAttrSynchronizable as String:false,kSecUseDataProtectionKeychain as String:true,kSecAttrAccessGroup as String:signingTeam()+"."+hostID]
    }
    static func legacyQuery(_ id: UUID, suffix: String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.keylane.extension-build.protected.v1",
         kSecAttrAccount as String:id.uuidString+":"+suffix,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
    }
    @MainActor
    static func exerciseOfficialUUID(profileID: UUID, restarting: Bool) async throws {
        let slug = "uuid-generator"
        let revision = "886cbd73fe377ad1d8f0c17083e6cd4c96748a33"
        let source = try RaycastStoreSource(slug: slug, catalog: .init(revision: revision, slugs: [slug]))
        var clipboardEffects: [String] = []
        var toastEffects: [String] = []
        let backend = try await MacOSStoreBuildInstallationService.open(
            id: profileID, application: .main, hostIdentifier: hostID,
            deliver: { presentation in
                switch presentation {
                case .clearSearch, .popToRoot, .closeWindow: break
                case .copy(let text): clipboardEffects.append(text)
                case .toast(let toast): toastEffects.append(toast.title)
                }
            }, requiresRuntime: true
        )
        let installed: RaycastStoreInstallation
        if restarting {
            guard let receipt = try await backend.installation(for: slug) else { exit(70) }
            installed = receipt
        } else {
            let artifact = try await backend.prepare(source)
            installed = try await backend.install(artifact)
        }
        guard installed.source == source, installed.enabled,
              let command = installed.manifest.commands.first(where: { $0.name == "formatUuid" }),
              Set(installed.manifest.commands.map(\.name)) == ["formatUuid", "packTypeID", "parseTypeID"] else { exit(70) }
        var missingArgumentRejected = false
        do {
            try await backend.launch(installed, commandID: command.id, arguments: [:])
        } catch MacOSExtensionRunAdmission.Failure.unsupportedCommand {
            missingArgumentRejected = clipboardEffects.isEmpty && toastEffects.isEmpty
        }
        let arguments = ["uuid": "550e8400e29b41d4a716446655440000"]
        try await backend.launch(installed, commandID: command.id, arguments: arguments)
        let formatted = "550e8400-e29b-41d4-a716-446655440000"
        let copyVerified = clipboardEffects == [formatted]
        let feedbackVerified = toastEffects.count == 1 && toastEffects[0].contains(formatted)
        guard let pack = installed.manifest.commands.first(where: { $0.name == "packTypeID" }),
              let parse = installed.manifest.commands.first(where: { $0.name == "parseTypeID" }) else { exit(70) }
        let uuid = "0195b514-74a3-7250-b9bb-70e07500ed8b"
        let typeID = "doctor_01jpth8x53e98bkevgw1tg1vcb"
        try await backend.launch(installed, commandID: pack.id, arguments: ["suffix": "doctor", "uuid": uuid])
        try await backend.launch(installed, commandID: parse.id, arguments: ["typeID": typeID])
        let conversionsVerified = Array(clipboardEffects.dropFirst()) == [typeID, uuid]
        if restarting {
            try await backend.uninstall(installationID: installed.id)
            let receipts = try await backend.installations()
            emit(["officialUUIDRestartAndUninstall": copyVerified && feedbackVerified && conversionsVerified && receipts.isEmpty])
        } else {
            emit(["officialUUIDInstalledAndRan": copyVerified && feedbackVerified && conversionsVerified,
                  "officialUUIDMissingArgumentRejected": missingArgumentRejected])
        }
    }

    @MainActor
    static func exerciseOfficialSilentMention(profileID: UUID, restarting: Bool) async throws {
        guard let entry = MacOSReviewedRaycastCommand.entry(forSlug: "silent-mention") else { exit(70) }
        let source = try RaycastStoreSource(slug: entry.slug, catalog: .init(revision: entry.revision, slugs: [entry.slug]))
        var copies: [String] = []
        var titles: [String] = []
        let backend = try await MacOSStoreBuildInstallationService.open(
            id: profileID, application: .main, hostIdentifier: hostID,
            deliver: { effect in
                switch effect {
                case .clearSearch, .popToRoot, .closeWindow: break
                case .copy(let text): copies.append(text)
                case .toast(let toast): titles.append(toast.title)
                }
            }, requiresRuntime: true)
        let receipt = try await officialInstallation(source, backend: backend, restarting: restarting)
        let activated = Set(receipt.manifest.commands.map(\.name)) == ["copy-zero-width-space", "index"]
        guard let textCommand = receipt.manifest.commands.first(where: { $0.name == "index" }) else { exit(70) }
        try await backend.launch(receipt, commandID: entry.commandID)
        try await backend.launch(receipt, commandID: textCommand.id, arguments: ["text": "@keylane #mac"])
        let verified = activated && copies == ["\u{2060}", "@\u{2060}keylane #\u{2060}mac"] &&
            titles == ["Copied to clipboard!", "Copied to clipboard!"]
        try await emitOfficialLifecycle(verified, name: "officialSilentMention", receipt: receipt, backend: backend, restarting: restarting)
    }

    @MainActor
    static func exerciseOfficialLoremMarkdown(profileID: UUID, restarting: Bool) async throws {
        guard let entry = MacOSReviewedRaycastCommand.entry(forSlug: "lorem-ipsum") else { exit(70) }
        let source = try RaycastStoreSource(slug: entry.slug, catalog: .init(revision: entry.revision, slugs: [entry.slug]))
        var effects: [String] = []
        let deliver: MacOSNoViewCapabilities.Presenter = { effect in
                switch effect {
                case .clearSearch, .popToRoot: break
                case .closeWindow(let clear, _): effects.append("close:" + String(clear))
                case .copy(let text): effects.append(text)
                case .toast(let toast): effects.append(toast.title)
                }
        }
        let backend = try await MacOSStoreBuildInstallationService.open(
            id: profileID, application: .main, hostIdentifier: hostID, deliver: deliver, requiresRuntime: true)
        let receipt = try await officialInstallation(source, backend: backend, restarting: restarting)
        let names = Set(["markdown", "html", "paragraphs", "sentences", "words"])
        var observed = Set<String>()
        for command in receipt.manifest.commands {
            effects.removeAll()
            let countField = MacOSReviewedRaycastCommand.entry(forCommandID: command.id)?.argument
            let arguments = countField.map { [$0: "3"] } ?? [:]
            try await backend.launch(receipt, commandID: command.id, arguments: arguments)
            guard effects.count == 3, effects.first == "close:true", !effects[1].isEmpty,
                  effects.last == "Copied to clipboard! 📋" else { continue }
            if command.name == "markdown", !effects[1].contains("# ") { continue }
            if command.name == "html", !effects[1].contains("<") { continue }
            if command.name == "words", effects[1].split(separator: " ").count != 3 { continue }
            if countField != nil {
                effects.removeAll()
                try await backend.launch(receipt, commandID: command.id)
                guard effects.count == 3, !effects[1].isEmpty, effects.last == "Copied to clipboard! 📋" else { continue }
            }
            observed.insert(command.name)
        }
        let verified = observed == names && Set(receipt.manifest.commands.map(\.name)) == names
        try await emitOfficialLifecycle(verified, name: "officialLoremMarkdown", receipt: receipt, backend: backend, restarting: restarting)
    }

    static func officialInstallation(_ source: RaycastStoreSource, backend: RaycastStoreInstallCoordinator,
                                     restarting: Bool) async throws -> RaycastStoreInstallation {
        if restarting {
            guard let receipt = try await backend.installation(for: source.slug), receipt.source == source, receipt.enabled else { exit(70) }
            return receipt
        }
        return try await backend.install(backend.prepare(source))
    }

    static func emitOfficialLifecycle(_ verified: Bool, name: String, receipt: RaycastStoreInstallation,
                                      backend: RaycastStoreInstallCoordinator, restarting: Bool) async throws {
        if restarting {
            try await backend.uninstall(installationID: receipt.id)
            let removed = try await backend.installation(for: receipt.source.slug) == nil
            emit([name + "RestartAndUninstall": verified && removed])
        } else {
            emit([name + "InstalledAndRan": verified])
        }
    }

    static func source(_ digit: String) throws -> RaycastStoreSource {
        try .init(slug:"m1-product-fixture",catalog:.init(revision:String(repeating:digit,count:40),slugs:["m1-product-fixture"]))
    }
    static func project(_ source: RaycastStoreSource) throws -> RaycastStoreBuildProject {
        var files: [String:Data] = [
            "package.json":Data(#"{"name":"m1-product-fixture","title":"First party","author":"fixture","platforms":["macOS"],"preferences":[{"name":"label","title":"Label","type":"textfield"}],"commands":[{"name":"main","title":"Main","mode":"no-view"}]}"#.utf8),
            "src/main.ts":Data("import {answer} from './value';globalThis.answer=answer;".utf8),
            "src/value.ts":Data("export const answer:number=42;".utf8),
            "assets/icon.txt":Data(source.revision.utf8), "LICENSE":Data("Self-authored test fixture".utf8)]
        if source.revision.first == "f", let manifest = files["package.json"],
           var metadata = try JSONSerialization.jsonObject(with: manifest) as? [String: Any] {
            metadata.removeValue(forKey: "preferences")
            files["package.json"] = try JSONSerialization.data(withJSONObject: metadata)
        }
        if source.revision.first == "d" {
            files["src/main.ts"] = Data((0..<150000).map { "export const value\($0)=\($0);" }.joined(separator:"\n").utf8)
        }
        if source.revision.first == "e" { files["src/main.ts"] = Data("const = ;".utf8) }
        let tree = files.map { path,data -> [String:Any] in
            let digest = Insecure.SHA1.hash(data:Data("blob \(data.count)\0".utf8)+data).map { String(format:"%02x",$0) }.joined()
            return ["path":path,"sha":digest,"size":data.count,"mode":"100644","type":"blob"]
        } + [["path":"src","sha":source.revision,"mode":"040000","type":"tree"],["path":"assets","sha":source.revision,"mode":"040000","type":"tree"]]
        let snapshot = try RaycastStoreSnapshot(source:source,treeSHA:source.revision,
            recursiveTreeJSON:JSONSerialization.data(withJSONObject:["sha":source.revision,"truncated":false,"tree":tree]))
        return try .init(source:.init(snapshot:snapshot,files:files),supportedRuntimeAPIVersions:[],tarballs:[:],target:.macOSArm64)
    }
}
