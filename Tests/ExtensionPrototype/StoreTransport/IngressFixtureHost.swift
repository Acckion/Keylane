import Foundation
import Virtualization
import Security
import CryptoKit
import Darwin

// Controlled ingress/build fixture harness, not an application runner or installation API.
final class Harness: NSObject, VZVirtioSocketListenerDelegate {
    var vm: VZVirtualMachine!
    var connection: VZVirtioSocketConnection?
    var listener: VZVirtioSocketListener!
    let serial = Pipe()
    var ended = false
    var serialRemaining = 8192
    // The async completion is only used by the typed fixture adapter.
    let completion: ((Bool, Data?) -> Void)?
    let timeout: Double
    var artifactResult: Data?
    let mode: String
    let payload: Data
    let sessionID=UUID()
    let realAPI=FileManager.default.fileExists(atPath:Bundle.main.resourceURL!.appendingPathComponent("real-api").path)
    static let sourceText="import { showToast } from '@raycast/api'; export default async function(){await showToast({title:'sealed-build-run-ok'});}"
    static func provenance() throws -> [String:Any] {
        let resources=Bundle.main.resourceURL!
        var hash=SHA256()
        for name in ["Image","ingress.cpio"] {hash.update(data:try Data(contentsOf:resources.appendingPathComponent(name)))}
        return ["version":1,"sourceDigest":SHA256.hash(data:Data(sourceText.utf8)).map{String(format:"%02x",$0)}.joined(),
                "recipe":"fixture-esbuild-node22-cjs-v1","runtimeDigest":hash.finalize().map{String(format:"%02x",$0)}.joined(),
                "installationID":"controlled-fixture","installationGeneration":1]
    }
    let transfer = String(repeating: "a", count: 32)
    init(mode: String, envelope: Data? = nil, timeout: Double = 25, completion: ((Bool, Data?) -> Void)? = nil) throws {
        self.mode = mode
        self.timeout = timeout
        self.completion = completion
        if let envelope { payload = envelope; return }

        let body: Data
        if mode == "build" || mode == "recipe-reject" {
            body=Data(Self.sourceText.utf8)
        } else if mode == "run" {
            guard CommandLine.arguments.count == 4 else { throw NSError(domain:"artifact input",code:1) }
            let url=URL(fileURLWithPath:CommandLine.arguments[2])
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 99999
            guard size<=8192 else { throw NSError(domain:"artifact bound",code:1) }
            let json=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any]
            guard let encoded=json?["artifact"] as? String, let decoded=Data(base64Encoded:encoded), decoded.count<=4096,
                  json?["sha256"] as? String == SHA256.hash(data:decoded).map({String(format:"%02x",$0)}).joined() else { throw NSError(domain:"artifact digest",code:1) }
            guard let provenance=json?["provenance"] as? [String:Any], try JSONSerialization.data(withJSONObject:provenance,options:.sortedKeys) == JSONSerialization.data(withJSONObject:Self.provenance(),options:.sortedKeys) else {throw NSError(domain:"artifact provenance",code:1)}
            // Expected output identity comes from the trusted caller/build receipt, NOT the package.
            guard json?["sha256"] as? String == CommandLine.arguments[3] else {throw NSError(domain:"artifact receipt",code:1)}
            body=decoded
        } else { body=Data(String(repeating: "controlled inert fixture\n", count: 1500).utf8) }
        payload = try JSONSerialization.data(withJSONObject: ["version":1,"files":[[
            "path":mode == "build" ? "src/fixture.ts" : mode == "run" ? "bundle.cjs" : "src/fixture.txt", "body":body.base64EncodedString(),
            "sha256":SHA256.hash(data:body).map { String(format:"%02x",$0) }.joined()
        ]]])
    }
    func end(_ success: Bool) {
        guard !ended else { return }; ended = true
        connection = nil
        vm.stop { error in
            print("fixture=\(success ? "passed" : "failed") vmStopped=\(error == nil)")
            if let completion = self.completion { completion(success && error == nil, self.artifactResult) }
            else { exit(success && error == nil ? 0 : 1) }
        }
    }
    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                  from socketDevice: VZVirtioSocketDevice) -> Bool {
        guard self.connection == nil, !ended, mode != "timeout" else { return false }
        print("fixture socket accepted")
        self.connection = connection
        DispatchQueue.global().async {
            let ok = self.exchange(connection.fileDescriptor)
            DispatchQueue.main.async { self.end(ok) }
        }
        return true
    }
    func exchange(_ fd: Int32) -> Bool {
        func send(_ object: [String:Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject:object); bytes.append(10)
            var offset=0
            while offset<bytes.count {
                var p=pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
                guard poll(&p,1,1000)>0 else { throw NSError(domain:"write timeout",code:1) }
                let n=bytes.withUnsafeBytes { Darwin.write(fd,$0.baseAddress!.advanced(by:offset),bytes.count-offset) }
                guard n>0 else { throw NSError(domain:"write",code:1) };offset+=n
            }
        }
        func read() throws -> [String:Any] {
            var data=Data()
            let deadline=Date().addingTimeInterval(5)
            while data.count<=16384 && Date()<deadline {
                var p=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
                guard poll(&p,1,100)>0 else { continue }
                var byte:UInt8=0
                guard Darwin.read(fd,&byte,1)==1 else { break }
                if byte==10 { return try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:] }
                data.append(byte)
            }
            throw NSError(domain:"frame/timeout",code:1)
        }
        var toastReceipts=0
        var deniedReceipts=0
        var broker=ExtensionPrototypeSession(id:sessionID,generation:1,grants:[.toast,.echo]) { capability,text in
            if capability == .toast {
                let object=try JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any]
                guard object?["operation"] as? String == "show", object?["title"] as? String == "sealed-build-run-ok", toastReceipts==0 else {throw CocoaError(.coderInvalidValue)}
                toastReceipts+=1
                print("real-host-toast-received=true")
                return ""
            }
            guard capability == .echo, text == "real-api-host-receipt", toastReceipts==1 else {throw CocoaError(.coderInvalidValue)}
            return text
        }
        defer {broker.cancel()}
        do {
            try send(["transfer":transfer,"bytes":mode == "oversize" ? 48*1024*1024 : payload.count,
                      "sha256":SHA256.hash(data:payload).map { String(format:"%02x",$0) }.joined()])
            var offset=0
            for _ in 0..<128 {
                let request=try read()
                if realAPI, request["kind"] != nil {
                    do {
                        let reply=try broker.receive(try JSONSerialization.data(withJSONObject:request))
                        if case .denied = reply {deniedReceipts+=1}
                        let encoded=try ExtensionPrototypeSession.encode(reply,session:sessionID,generation:1)
                        try send(JSONSerialization.jsonObject(with:encoded) as! [String:Any])
                    } catch ExtensionPrototypeSession.Rejection.stale {continue}
                    continue
                }
                if request["received"] as? Bool == true { guard offset==payload.count else {return false}; continue }
                if let encoded=request["artifact"] as? String {
                    guard mode=="build", offset==payload.count, encoded.count<=5464,
                          let data=Data(base64Encoded:encoded), data.count<=4096,
                          request["sha256"] as? String == SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() else {return false}
                    // Printed as data only. The host NEVER evaluates this command artifact.
                    artifactResult = data
                    var output=request; output["provenance"]=try Self.provenance()
                    print("ARTIFACT:" + String(data:try JSONSerialization.data(withJSONObject:output),encoding:.utf8)!)
                    return true
                }
                if request["executed"] as? Bool == true, realAPI {
                    let confirmed=mode=="run" && request["realAPI"] as? Bool == true && request["receipt"] as? String == "real-api-host-receipt" && toastReceipts==1 && deniedReceipts==1
                    print("real-api-roundtrip=\(confirmed) toastReceipts=\(toastReceipts) deniedReceipts=\(deniedReceipts)")
                    return confirmed
                }
                if request["executed"] as? Bool == true {return mode=="run" && request["stub"] as? Bool == true && request["result"] as? String == "sealed-build-run-ok"}
                if request["rejected"] as? Bool == true { return ["oversize","replay","corrupt","recipe-reject"].contains(mode) }
                if request["done"] as? Bool == true {
                    return mode == "valid" && offset == payload.count && request["files"] as? Int == 1 && request["bytes"] as? Int == 37500
                }
                guard request["transfer"] as? String == transfer, request["offset"] as? Int == offset,
                      let length=request["length"] as? Int, length == min(8192,payload.count-offset),length>0 else { return false }
                let chunk=payload.subdata(in:offset..<(offset+length))
                try send(["transfer":transfer,"offset":mode == "replay" ? offset+1 : offset,
                          "body":mode == "corrupt" ? Data(repeating:0,count:length).base64EncodedString() : chunk.base64EncodedString()])
                offset+=length
            }
        } catch { print("exchange rejected: \(error)") }
        return false
    }
    static func verifyBundle(_ bundle: Bundle) throws {
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckNestedCode | kSecCSStrictValidate))
        var code: SecStaticCode?
        guard bundle.bundleIdentifier == "site.keylane.store-ingress-fixture",
              SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw NSError(domain: "signed bundle required", code: 1)
        }
    }
    func start(resources: StoreSignedGuestEngine.Resources? = nil) throws {
        let bundle=Bundle.main
        guard let directory=bundle.resourceURL else { throw NSError(domain:"bundle",code:1) }
        try Self.verifyBundle(bundle)
        let boot=VZLinuxBootLoader(kernelURL:resources?.kernelURL ?? directory.appendingPathComponent("Image"))
        boot.initialRamdiskURL=resources?.ramdiskURL ?? directory.appendingPathComponent("ingress.cpio")
        boot.commandLine="console=hvc0 rdinit=/init KEYLANE_SESSION=\(sessionID.uuidString) KEYLANE_SENTINEL=/host-only-fixture KEYLANE_PHASE=\((mode == "build" || mode == "recipe-reject") ? "fixture-build" : (mode == "run" || mode == "timeout") ? "fixture-run" : "view-app")"
        let config=VZVirtualMachineConfiguration();config.bootLoader=boot;config.cpuCount=1;config.memorySize=384*1024*1024
        config.socketDevices=[VZVirtioSocketDeviceConfiguration()]
        let port=VZVirtioConsoleDeviceSerialPortConfiguration()
        port.attachment=VZFileHandleSerialPortAttachment(fileHandleForReading:nil,fileHandleForWriting:serial.fileHandleForWriting)
        config.serialPorts=[port];try config.validate()
        serial.fileHandleForReading.readabilityHandler = { handle in
            let data=handle.availableData
            if self.serialRemaining > 0 { let portion=data.prefix(self.serialRemaining); self.serialRemaining -= portion.count; FileHandle.standardError.write(portion) }
        }
        vm=VZVirtualMachine(configuration:config)
        listener=VZVirtioSocketListener();listener.delegate=self
        (vm.socketDevices[0] as! VZVirtioSocketDevice).setSocketListener(listener,forPort:4050)
        vm.start { result in
            switch result {
            case .success:
                DispatchQueue.main.asyncAfter(deadline:.now()+self.timeout) {
                    if !self.ended { print("fixture deadline exceeded"); self.end(false) }
                }
            case .failure(let error):
                self.ended = true
                print(error)
                if let completion = self.completion { completion(false, nil) } else { exit(1) }
            }
        }
    }
}
// Test-only implementation of the app-side bridge contract. This accepts only
// the self-authored fixed recipe sealed into this fixture's signed guest.
@MainActor
private final class FixtureDriver: StoreSignedGuestEngine.Driver {
    let timeoutOnly: Bool
    init(timeoutOnly: Bool) { self.timeoutOnly = timeoutOnly }

    func buildInFreshGuest(resources: StoreSignedGuestEngine.Resources, envelope projectEnvelope: Data,
                           entry: String) async throws -> Data {
        guard entry == "src/fixture.ts" else { throw StoreRuntimeBridge.Rejection.invalidProject }
        let root = try JSONSerialization.jsonObject(with: projectEnvelope) as? [String: Any]
        let files = root?["files"] as? [[String: Any]]
        guard files?.count == 1, files?.first?["path"] as? String == entry,
              files?.first?["body"] as? String == Data(Harness.sourceText.utf8).base64EncodedString() else {
            throw StoreRuntimeBridge.Rejection.invalidProject
        }
        guard let artifact = try await exchange(mode: timeoutOnly ? "timeout" : "build", envelope: projectEnvelope, resources: resources) else {
            throw StoreRuntimeBridge.Rejection.artifactIdentity
        }
        return artifact
    }

    func runInFreshGuest(resources: StoreSignedGuestEngine.Resources, artifact: Data,
                         receipt: StoreRuntimeBridge.Receipt, installation: StoreRuntimeBridge.Installation) async throws {
        guard installation.generation == 1 else { throw StoreRuntimeBridge.Rejection.staleInstallation }
        let envelope = try JSONSerialization.data(withJSONObject: ["version": 1, "files": [[
            "path": "bundle.cjs", "body": artifact.base64EncodedString(), "sha256": receipt.artifactDigest
        ]]])
        _ = try await exchange(mode: "run", envelope: envelope, resources: resources)
    }

    private func exchange(mode: String, envelope: Data, resources: StoreSignedGuestEngine.Resources) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            do {
                let harness = try Harness(mode: mode, envelope: envelope, timeout: timeoutOnly ? 1 : 25) { ok, result in
                    if ok { continuation.resume(returning: result) }
                    else { continuation.resume(throwing: NSError(domain: "VM stopped with failure", code: 1)) }
                }
                try harness.start(resources: resources)
            } catch { continuation.resume(throwing: error) }
        }
    }
}

@MainActor
private func testBridge(timeoutOnly: Bool) async throws {
    let staged = StoreRuntimeBridge.Installation(id: "controlled-fixture", generation: 0)
    let enabled = StoreRuntimeBridge.Installation(id: staged.id, generation: 1)
    guard CommandLine.arguments.count == 3 else { throw StoreRuntimeBridge.Rejection.runtimeIdentity }
    let engine = StoreSignedGuestEngine(bundle: .main, trust: .init(
        signingIdentifier: "site.keylane.store-ingress-fixture", teamIdentifier: CommandLine.arguments[2],
        recipeIdentifier: "fixture-esbuild-node22-cjs-v1"
    ), driver: FixtureDriver(timeoutOnly: timeoutOnly))
    let bridge = StoreRuntimeBridge(engine: engine) { candidate, operation in
        operation == .stagingBuild ? candidate == staged : candidate == enabled
    }
    let built = try await bridge.prepare(installation: staged, entry: "src/fixture.ts",
        files: [.init(path: "src/fixture.ts", body: Data(Harness.sourceText.utf8))])
    try await bridge.run(artifact: built.artifact, expectedReceipt: built.receipt, installation: enabled)
    print("typed bridge built and ran digest=\(built.receipt.artifactDigest)")
}

signal(SIGPIPE,SIG_IGN)
let mode=CommandLine.arguments.dropFirst().first ?? "valid"
if mode == "bridge" || mode == "bridge-timeout" {
    Task { @MainActor in
        do { try await testBridge(timeoutOnly: mode == "bridge-timeout"); exit(0) }
        catch { print(error); exit(1) }
    }
    dispatchMain()
}
guard ["valid","oversize","replay","corrupt","build","run","recipe-reject"].contains(mode) else { exit(2) }
do { let harness=try Harness(mode:mode);try harness.start();withExtendedLifetime(harness) { dispatchMain() } }
catch { print(error);exit(1) }
