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
        if mode == "setup" {
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
        guard ids.count == 1 else { exit(71) }; let id = ids[0]
        if mode == "cleanup" {
            for suffix in ["head","profile"] {
                let result = SecItemDelete(query(id,suffix:suffix) as CFDictionary)
                guard result == errSecSuccess || result == errSecItemNotFound else { emit(["cleanupFailed":true]); exit(74) }
            }
            try FileManager.default.removeItem(at:intent); emit(["cleaned":true]); return
        }
        if mode == "foreign" {
            SecKeychainSetUserInteractionAllowed(false) // this test process only
            var q = query(id,suffix:"profile"); q[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary,&result)
            emit(["foreignReadDenied": status != errSecSuccess && status != errSecItemNotFound]); return
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
    static func query(_ id: UUID, suffix: String) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.keylane.extension-build.protected.v1",
         kSecAttrAccount as String:id.uuidString+":"+suffix,kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
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
