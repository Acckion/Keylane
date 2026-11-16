import AppKit
import CoreFoundation
import Darwin
import Foundation
import Security
import UniformTypeIdentifiers
import Virtualization

final class GuestProbe: NSObject, VZVirtioSocketListenerDelegate {
    let id = UUID()
    let started = ContinuousClock.now
    let expected: String?
    let phase: String
    let viewInput: String?
    let preferences: String?
    let paste: Bool
    let sensitiveFormSubmission: Bool
    private let applicationQueries: ApplicationQueries?
    private let clipboardReader: ClipboardTextReader?
    private let windowReader: WindowSnapshotReader?
    private let localStorage: GuestLocalStorage?
    let serial = Pipe()
    var serialBytes = 0
    var cancellation: DispatchSourceSignal?

    init(phase: String, expected: String?, viewInput: String?, preferences: String?, paste: Bool,
         sensitiveFormSubmission: Bool, applicationQueries: ApplicationQueries?, clipboardReader: ClipboardTextReader?,
         windowReader: WindowSnapshotReader?, localStorage: GuestLocalStorage?) {
        self.phase = phase
        self.expected = expected
        self.viewInput = viewInput
        self.preferences = preferences
        self.paste = paste
        self.sensitiveFormSubmission = sensitiveFormSubmission
        self.applicationQueries = applicationQueries
        self.clipboardReader = clipboardReader
        self.windowReader = windowReader
        self.localStorage = localStorage
    }

    func drainSerial() {
        let reader = serial.fileHandleForReading
        reader.readabilityHandler = { handle in
            let bytes = handle.availableData
            DispatchQueue.main.sync {
                guard !self.stopped else { return }
                if bytes.isEmpty {
                    reader.readabilityHandler = nil
                    return
                }
                let remaining = 32 * 1024 - self.serialBytes
                let prefix = Data(bytes.prefix(remaining))
                self.serialBytes += prefix.count
                if !self.sensitiveFormSubmission, self.clipboardReader == nil, self.windowReader == nil, self.localStorage == nil { FileHandle.standardError.write(prefix) }
                if prefix.count < bytes.count {
                    FileHandle.standardError.write(Data("\nguest serial output limit\n".utf8))
                    self.finish(success: false)
                }
            }
        }
    }

    var vm: VZVirtualMachine?
    var connection: VZVirtioSocketConnection?
    var stopped = false

    func listener(
        _ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        guard !stopped, self.connection == nil else { return false }
        self.connection = connection
        FileHandle.standardError.write(Data("host accepted guest socket\n".utf8))
        let id = self.id
        DispatchQueue.global().async {
            let result = Self.exchange(connection.fileDescriptor, id: id, phase: self.phase, viewInput: self.viewInput,
                                       preferences: self.preferences, paste: self.paste,
                                       sensitiveFormSubmission: self.sensitiveFormSubmission,
                                       applicationQueries: self.applicationQueries, clipboardReader: self.clipboardReader,
                                       windowReader: self.windowReader, localStorage: self.localStorage)
            let success: Bool
            if let expected = self.expected {
                success = result == expected
            } else {
                success = result.flatMap { Data(base64Encoded: $0) }.map { !$0.isEmpty } ?? false
            }
            if success, let result { print("guest-result=\(result)") }
            DispatchQueue.main.async { self.finish(success: success) }
        }
        return true
    }

    static func exchange(_ descriptor: Int32, id: UUID, phase: String, viewInput: String?,
                         preferences: String?, paste: Bool, sensitiveFormSubmission: Bool,
                         applicationQueries: ApplicationQueries?, clipboardReader: ClipboardTextReader?,
                         windowReader: WindowSnapshotReader?, localStorage: GuestLocalStorage?) -> String? {
        let io = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let noView = phase.hasPrefix("noview-")
        var grants: Set<ExtensionPrototypeSession.Capability> = [.echo]
        if noView { grants.formUnion([.clipboardCopy, .hud, .toast]) }
        if viewInput != nil { grants = [.viewInput, .viewResult] }
        var viewResult: String?
        let application = phase == "noview-app"
        if application {
            grants.remove(.clipboardCopy)
            grants.formUnion([.preferencesRead, paste ? .clipboardPaste : .clipboardCopy])
        }
        if !sensitiveFormSubmission, applicationQueries != nil { grants.insert(.applicationsQuery) }
        if !sensitiveFormSubmission, clipboardReader != nil { grants.insert(.clipboardRead) }
        if !sensitiveFormSubmission, windowReader != nil { grants.insert(.windowRead) }
        if !sensitiveFormSubmission, localStorage != nil { grants.insert(.localStorage) }
        var requestedClipboardText: String?
        let pasteboard = noView && !application ? NSPasteboard(name: .init("org.keylane.prototype.\(id.uuidString)")) : nil
        defer { pasteboard?.releaseGlobally() }
        var session = ExtensionPrototypeSession(id: id, generation: 1, grants: grants) { capability, text in
            switch capability {
            case .preferencesRead:
                guard let preferences, text.isEmpty else { throw CocoaError(.featureUnsupported) }
                return preferences
            case .viewInput:
                guard let viewInput, text.isEmpty else { throw CocoaError(.featureUnsupported) }
                return viewInput
            case .localStorage:
                guard let localStorage else { throw CocoaError(.featureUnsupported) }
                return try localStorage.reply(to: text)
            case .clipboardRead:
                guard let clipboardReader else { throw CocoaError(.featureUnsupported) }
                return try clipboardReader.reply(to: text)
            case .windowRead:
                guard let windowReader else { throw CocoaError(.featureUnsupported) }
                return try windowReader.reply(to: text)
            case .applicationsQuery:
                guard let applicationQueries else { throw CocoaError(.featureUnsupported) }
                return try applicationQueries.reply(to: text)
            case .viewResult:
                let data = Data(text.utf8)
                guard viewInput != nil, viewResult == nil, data.count <= 10_240,
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw CocoaError(.featureUnsupported)
                }
                if sensitiveFormSubmission {
                    guard let kind = object["kind"] as? String, ["action", "error", "formRejected"].contains(kind) else {
                        throw CocoaError(.featureUnsupported)
                    }
                    viewResult = try JSONSerialization.data(withJSONObject: ["kind": kind]).base64EncodedString()
                } else {
                    viewResult = data.base64EncodedString()
                }
                return ""
            case .echo:
                return text
            case .clipboardCopy, .clipboardPaste:
                if application {
                    guard requestedClipboardText == nil, UUID(uuidString: text) != nil else {
                        throw CocoaError(.fileWriteInvalidFileName)
                    }
                    requestedClipboardText = text
                    return ""
                }
                guard capability == .clipboardCopy, let pasteboard else { throw CocoaError(.featureUnsupported) }
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string),
                      pasteboard.string(forType: .string) == text else { throw CocoaError(.fileWriteUnknown) }
            case .hud, .toast:
                break // The headless verification host captures feedback as an event.
            }
            let event = try JSONSerialization.data(withJSONObject: ["capability": capability.rawValue, "text": text])
            FileHandle.standardError.write(Data("broker-event ".utf8) + event + Data([10]))
            return ""
        }
        var replies: [ExtensionPrototypeSession.Reply] = []
        var bytesReceived = 0
        var bytesSent = 0
        let byteLimit = 64 * 1024
        do {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                bytesReceived += count
                guard bytesReceived <= byteLimit else { throw ExtensionPrototypeSession.Rejection.limit }
                let chunk = Data(buffer.prefix(count))
                try session.receiveBytes(chunk) { reply in
                    replies.append(reply)
                    let data = try ExtensionPrototypeSession.encode(reply, session: id, generation: 1)
                    bytesSent += data.count
                    guard bytesSent <= byteLimit else { throw ExtensionPrototypeSession.Rejection.limit }
                    try io.write(contentsOf: data)
                }
            }
            try session.finishInput()
            if viewInput != nil, case .result(_, "")? = replies.last { return viewResult }
            if noView, case .result(_, "node-confirmed")? = replies.last {
                return application ? requestedClipboardText.map { "\(paste ? "paste" : "copy"):\($0)" } : "node-confirmed"
            }
            guard replies.count == 3, replies[0] == .ready(version: 1),
                  replies[1] == .denied(requestID: 1),
                  case .result(requestID: 2, text: let result) = replies[2] else { return nil }
            return result
        } catch {
            if bytesReceived > byteLimit || bytesSent > byteLimit {
                FileHandle.standardError.write(Data("guest protocol output limit\n".utf8))
            }
            let message = sensitiveFormSubmission ? "guest protocol rejected the sensitive request" : "guest protocol: \(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return nil
        }
    }

    func finish(success: Bool) {
        guard !stopped, let vm else { return }
        stopped = true
        serial.fileHandleForReading.readabilityHandler = nil
        if let connection { _ = shutdown(connection.fileDescriptor, SHUT_RDWR) }
        let elapsed = started.duration(to: .now)
        vm.stop { error in
            if let error {
                FileHandle.standardError.write(Data("VM stop failed: \(error)\n".utf8))
                exit(1)
            }
            print("guest probe \(success ? "passed" : "failed"), elapsed \(elapsed), state=\(vm.state.rawValue)")
            exit(success && vm.state == .stopped ? 0 : 1)
        }
    }
}

@main
struct Host {
    static func main() throws {
        let args = CommandLine.arguments
        guard (args.count == 6 || args.count == 7), ["probe", "build", "uuid-build", "view-build", "uuid-suite-build", "menu-bar-build", "view-app", "uuid-storage-app", "run", "stall", "hold", "malformed", "oversize", "replay", "partial",
                               "log-flood", "noview-wire", "noview-copy", "noview-denied", "noview-cancel", "noview-flood", "noview-backpressure", "noview-app"].contains(args[4]),
              !args[3].contains(where: \.isWhitespace), VZVirtualMachine.isSupported else {
            FileHandle.standardError.write(Data("usage: host kernel initramfs host-sentinel phase expected-result\n".utf8))
            exit(2)
        }
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let phase = args[4]
        let input = args.count == 7 ? args[6] : ""
        if phase == "noview-app" {
            guard input.utf8.count == 32, input.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }) else { exit(2) }
        } else if args.count != 6 { exit(2) }
        let building = ["build", "uuid-build", "view-build", "uuid-suite-build", "menu-bar-build"].contains(phase)
        var viewInput: String?
        var preferences: String?
        var paste = false
        var sensitiveFormSubmission = false
        var clipboardReader: ClipboardTextReader?
        var windowReader: WindowSnapshotReader?
        var localStorage: GuestLocalStorage?
        if ["view-app", "noview-app", "uuid-storage-app"].contains(phase) {
            let limit = phase == "noview-app" ? 2_048 : 8_192
            var bytes = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: limit + 1 - bytes.count), !chunk.isEmpty {
                bytes.append(chunk)
                guard bytes.count <= limit else { exit(2) }
            }
            guard let input = String(data: bytes, encoding: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { exit(2) }
            if phase != "noview-app" {
                sensitiveFormSubmission = object["sensitiveFormSubmission"] as? Bool == true
                if phase == "view-app" {
                    var base = object
                    if let cache = base.removeValue(forKey: "cache") {
                        guard !sensitiveFormSubmission,
                              let data = try? JSONSerialization.data(withJSONObject: cache, options: .withoutEscapingSlashes),
                              data.count <= 4_224 else { exit(2) }
                        if let entries = cache as? [[String]] {
                            guard entries.count <= 64, entries.allSatisfy({ $0.count == 2 }) else { exit(2) }
                        } else {
                            guard let entries = cache as? [String: String], entries.count <= 64,
                                  data.count <= 4_096 else { exit(2) }
                        }
                    }
                    let baseLimit = base["viewRoute"] == nil ? 2_048 : 4_096
                    guard let data = try? JSONSerialization.data(withJSONObject: base, options: .withoutEscapingSlashes),
                          data.count <= baseLimit else { exit(2) }
                }
                let clipboardMarker = object.removeValue(forKey: "clipboardReadChangeCount")
                let windowMarker = object.removeValue(forKey: "windowReadTargetPID")
                let suppliedClipboardGrant = object.removeValue(forKey: "clipboardReadAllowed")
                let suppliedWindowGrant = object.removeValue(forKey: "windowReadAllowed")
                let suppliedStorageGrant = object.removeValue(forKey: "localStorageAllowed")
                if !sensitiveFormSubmission, phase == "view-app", object["storage"] == nil {
                    localStorage = GuestLocalStorage.make(phase: phase, kernelPath: args[1], imagePath: args[2])
                }
                if !sensitiveFormSubmission, clipboardMarker != nil || windowMarker != nil,
                   let app = ReviewedViewReadAccess.bundle(
                       phase: phase, kernelPath: args[1], imagePath: args[2], request: object
                   ) {
                    clipboardReader = clipboardMarker.flatMap { ClipboardTextReader.make(app: app, marker: $0) }
                    windowReader = windowMarker.flatMap { WindowSnapshotReader.make(marker: $0) }
                }
                if clipboardReader != nil { object["clipboardReadAllowed"] = true }
                if windowReader != nil { object["windowReadAllowed"] = true }
                if localStorage != nil { object["localStorageAllowed"] = true }
                if clipboardMarker != nil || windowMarker != nil || suppliedClipboardGrant != nil || suppliedWindowGrant != nil ||
                    localStorage != nil || suppliedStorageGrant != nil {
                    let sanitized = try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)
                    viewInput = String(decoding: sanitized, as: UTF8.self)
                } else {
                    viewInput = input
                }
            } else {
                let values = object["preferences"] as? [String: Any] ?? object
                guard let action = values["defaultAction"] as? String, ["copy", "paste"].contains(action) else { exit(2) }
                let suppliedStorageGrant = object.removeValue(forKey: "localStorageAllowed")
                localStorage = GuestLocalStorage.make(phase: phase, kernelPath: args[1], imagePath: args[2])
                if localStorage != nil { object["localStorageAllowed"] = true }
                if localStorage != nil || suppliedStorageGrant != nil {
                    preferences = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                } else {
                    preferences = input
                }
                paste = action == "paste"
            }
        }
        let applicationQueries = ApplicationQueries.make(
            phase: phase, kernelPath: args[1], imagePath: args[2], sensitive: sensitiveFormSubmission
        )
        let probe = GuestProbe(phase: phase, expected: viewInput != nil || (building && args[5] == "-") ? nil : args[5],
                               viewInput: viewInput, preferences: preferences, paste: paste,
                               sensitiveFormSubmission: sensitiveFormSubmission, applicationQueries: applicationQueries,
                               clipboardReader: clipboardReader, windowReader: windowReader, localStorage: localStorage)
        let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: args[1]))
        boot.initialRamdiskURL = URL(fileURLWithPath: args[2])
        boot.commandLine = "console=hvc0 rdinit=/init KEYLANE_SESSION=\(probe.id.uuidString) KEYLANE_SENTINEL=\(args[3]) KEYLANE_PHASE=\(phase == "hold" ? "stall" : phase) KEYLANE_UUID=\(input)"
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = boot
        config.cpuCount = 1
        config.memorySize = (building || phase == "run" || phase.hasPrefix("noview-") || viewInput != nil ? 384 : 256) * 1024 * 1024
        config.networkDevices = []
        config.directorySharingDevices = []
        config.storageDevices = []
        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: probe.serial.fileHandleForWriting)
        config.serialPorts = [serial]
        try config.validate()
        probe.drainSerial()
        let vm = VZVirtualMachine(configuration: config)
        probe.vm = vm
        let listener = VZVirtioSocketListener()
        listener.delegate = probe
        let socket = vm.socketDevices[0] as! VZVirtioSocketDevice
        socket.setSocketListener(listener, forPort: 4050)
        vm.start { result in
            if case .failure(let error) = result {
                FileHandle.standardError.write(Data("VM start failed: \(error)\n".utf8))
                exit(1)
            }
        }
        let cancel = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        cancel.setEventHandler {
            FileHandle.standardError.write(Data("guest cancellation requested\n".utf8))
            probe.finish(success: false)
        }
        probe.cancellation = cancel
        cancel.resume()
        let timeout = ["stall": 2, "noview-backpressure": 4][phase] ?? 12
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout)) {
            FileHandle.standardError.write(Data("guest deadline expired\n".utf8))
            probe.finish(success: false)
        }
        dispatchMain()
    }
}

final class ApplicationQueries {
    private struct Request: Decodable {
        enum Operation: String, Decodable { case list, `default`, frontmost }
        let operation: Operation
        let `extension`: String?
        let directory: Bool?

        func type() throws -> UTType? {
            if directory != nil {
                guard directory == true, `extension` == nil else { throw CocoaError(.featureUnsupported) }
                return .folder
            }
            guard let `extension` else { return nil }
            guard `extension`.range(of: #"^[a-z0-9][a-z0-9_+-]{0,31}$"#, options: .regularExpression) != nil,
                  let type = UTType(filenameExtension: `extension`) else { throw CocoaError(.featureUnsupported) }
            return type
        }
    }

    fileprivate struct Application: Encodable {
        let name: String
        let localizedName: String?
        let path: String
        let bundleId: String?

        init?(url: URL, name: String? = nil, bundleId: String? = nil) {
            guard url.isFileURL, url.pathExtension.lowercased() == "app",
                  let path = Self.clean(url.standardizedFileURL.path, maximumBytes: 512) else { return nil }
            self.path = path
            let bundle = Bundle(url: url)
            let filename = url.deletingPathExtension().lastPathComponent
            guard let title = Self.clean(bundle?.infoDictionary?["CFBundleDisplayName"] as? String, maximumBytes: 128)
                    ?? Self.clean(bundle?.infoDictionary?["CFBundleName"] as? String, maximumBytes: 128)
                    ?? Self.clean(filename, maximumBytes: 128) else { return nil }
            self.name = title
            localizedName = Self.clean(name, maximumBytes: 128)
                ?? Self.clean(bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String, maximumBytes: 128)
                ?? Self.clean(bundle?.localizedInfoDictionary?["CFBundleName"] as? String, maximumBytes: 128)
            self.bundleId = Self.clean(bundleId ?? bundle?.bundleIdentifier, maximumBytes: 128)
        }

        private static func clean(_ value: String?, maximumBytes: Int) -> String? {
            guard let value, !value.isEmpty, value.utf8.count <= maximumBytes,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return value
        }
    }

    private static let maximumResults = 128
    private static let maximumReplyBytes = 6_000
    private let reviewedApp: URL?
    private var signatureIsValid: Bool?
    private var queriesLeft = 8
    private var installed: [Application]?

    private init(reviewedApp: URL? = nil) {
        self.reviewedApp = reviewedApp
    }

    static func make(phase: String, kernelPath: String, imagePath: String, sensitive: Bool) -> ApplicationQueries? {
        guard !sensitive, ["view-app", "uuid-storage-app", "noview-app"].contains(phase) else { return nil }
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        return ApplicationQueries()
        #else
        guard let app = reviewedLaunchBundle(phase: phase, kernelPath: kernelPath, imagePath: imagePath) else { return nil }
        return ApplicationQueries(reviewedApp: app)
        #endif
    }

    fileprivate static func reviewedLaunchBundle(phase: String, kernelPath: String, imagePath: String) -> URL? {
        func canonical(_ path: String) -> URL {
            URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        }
        let executable = canonical(CommandLine.arguments[0])
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "KeylaneReviewedExtensionHost", helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents", app.pathExtension == "app",
              let bundle = Bundle(url: app), let main = bundle.executableURL,
              ["org.keylane.launcher", "org.keylane.launcher.raycast-preview", "org.keylane.launcher.raycast-preview.test"].contains(bundle.bundleIdentifier ?? "")
        else { return nil }
        // The helper only enables the service for the Keylane app that owns this helper and the sealed guest files.
        var parentPath = [CChar](repeating: 0, count: 4096)
        let length = parentPath.withUnsafeMutableBytes { proc_pidpath(getppid(), $0.baseAddress, UInt32($0.count)) }
        guard length > 0, canonical(String(cString: parentPath)).path == canonical(main.path).path else { return nil }
        let assets = contents.appendingPathComponent("Resources/ReviewedRaycast", isDirectory: true)
        let image = canonical(imagePath)
        let approved: [String]
        switch phase {
        case "view-app": approved = ["view.cpio", "menu-bar.cpio"]
        case "uuid-storage-app": approved = ["uuid-suite.cpio"]
        case "noview-app": approved = ["noview.cpio"]
        default: return nil
        }
        guard canonical(kernelPath).path == assets.appendingPathComponent("Image").path,
              image.deletingLastPathComponent().path == assets.path, approved.contains(image.lastPathComponent)
        else { return nil }
        return app
    }

    private func canQueryApplications() -> Bool {
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        return true
        #else
        if let signatureIsValid { return signatureIsValid }
        guard let reviewedApp else { return false }
        let valid = Self.hasReviewedSignature(reviewedApp)
        signatureIsValid = valid
        return valid
        #endif
    }

    fileprivate static func hasReviewedSignature(_ app: URL) -> Bool {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckNestedCode | kSecCSStrictValidate))
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    func reply(to text: String) throws -> String {
        guard queriesLeft > 0, canQueryApplications() else { throw CocoaError(.featureUnsupported) }
        queriesLeft -= 1
        let data = Data(text.utf8)
        guard data.count <= 128, let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["operation", "extension", "directory"]),
              fields.values.allSatisfy({ !($0 is NSNull) }) else { throw CocoaError(.featureUnsupported) }
        let request = try JSONDecoder().decode(Request.self, from: data)
        let type = try request.type()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        switch request.operation {
        case .list:
            let applications = type.map(associatedApplications(for:)) ?? installedApplications()
            var results: [Application] = []
            for application in applications.prefix(Self.maximumResults) {
                results.append(application)
                if try encoder.encode(results).count > Self.maximumReplyBytes {
                    results.removeLast()
                    break
                }
            }
            return String(decoding: try encoder.encode(results), as: UTF8.self)
        case .default:
            guard let type, let application = defaultApplication(for: type) else { throw CocoaError(.featureUnsupported) }
            return String(decoding: try encoder.encode(application), as: UTF8.self)
        case .frontmost:
            guard type == nil, let application = frontmostApplication() else { throw CocoaError(.featureUnsupported) }
            return String(decoding: try encoder.encode(application), as: UTF8.self)
        }
    }

    private func installedApplications() -> [Application] {
        if let installed { return installed }
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        let results = syntheticApplications
        #else
        let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications",
                     "/System/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var results: [Application] = []
        for path in roots {
            let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
            guard let iterator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in iterator.prefix(2_048) {
                guard url.pathExtension.lowercased() == "app" else { continue }
                iterator.skipDescendants()
                let canonical = url.resolvingSymlinksInPath()
                guard canonical.path.hasPrefix(root.path + "/"), seen.insert(canonical.path).inserted,
                      let app = Application(url: canonical) else { continue }
                results.append(app)
            }
        }
        results.sort { first, second in
            let order = (first.localizedName ?? first.name).localizedStandardCompare(second.localizedName ?? second.name)
            return order == .orderedSame ? first.path < second.path : order == .orderedAscending
        }
        #endif
        installed = results
        return results
    }

    private func associatedApplications(for type: UTType) -> [Application] {
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        return type == .plainText ? syntheticApplications : []
        #else
        return NSWorkspace.shared.urlsForApplications(toOpen: type).prefix(Self.maximumResults).compactMap { Application(url: $0) }
        #endif
    }

    private func defaultApplication(for type: UTType) -> Application? {
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        return associatedApplications(for: type).first
        #else
        return NSWorkspace.shared.urlForApplication(toOpen: type).flatMap { Application(url: $0) }
        #endif
    }

    private func frontmostApplication() -> Application? {
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        return syntheticApplications.last
        #else
        guard let frontmost = NSWorkspace.shared.frontmostApplication, let url = frontmost.bundleURL else { return nil }
        return Application(url: url, name: frontmost.localizedName, bundleId: frontmost.bundleIdentifier)
        #endif
    }

    #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
    private var syntheticApplications: [Application] {
        ["Fixture Editor", "Fixture Viewer"].compactMap {
            Application(url: URL(fileURLWithPath: "/Applications/\($0).app"))
        }
    }
    #endif
}

final class ClipboardTextReader {
    private static let maximumTextBytes = 2_048
    private let read: () throws -> String?
    private var remaining = 4

    private init(read: @escaping () throws -> String?) {
        self.read = read
    }

    static func make(app: URL, marker: Any) -> ClipboardTextReader? {
        guard let changeCount = ReviewedViewReadAccess.integer(marker), changeCount >= 0 else { return nil }
        let name = Bundle(url: app)?.object(forInfoDictionaryKey: "KeylaneReviewedRaycastPasteboard") as? String
        return ClipboardTextReader {
            let board = name.map { NSPasteboard(name: .init($0)) } ?? .general
            guard board.changeCount == changeCount else { throw CocoaError(.featureUnsupported) }
            if board.types?.contains(.init("org.nspasteboard.ConcealedType")) == true { return nil }
            let value = board.string(forType: .string)
            guard board.changeCount == changeCount else { throw CocoaError(.featureUnsupported) }
            return value
        }
    }

    func reply(to text: String) throws -> String {
        guard text.isEmpty, remaining > 0 else { throw CocoaError(.featureUnsupported) }
        remaining -= 1
        var result: [String: String] = [:]
        if let value = try read() {
            guard value.utf8.count <= Self.maximumTextBytes else { throw CocoaError(.featureUnsupported) }
            result["text"] = value
        }
        let bytes = try JSONSerialization.data(withJSONObject: result, options: .withoutEscapingSlashes)
        return String(decoding: bytes, as: UTF8.self)
    }
}

private enum ReviewedViewReadAccess {
    static func bundle(phase: String, kernelPath: String, imagePath: String, request: [String: Any]) -> URL? {
        guard phase == "view-app", URL(fileURLWithPath: imagePath).lastPathComponent == "view.cpio",
              let action = request["action"] as? [String: Any], Set(action.keys) == ["row", "id"],
              let row = integer(action["row"]), (-1..<128).contains(row),
              let id = integer(action["id"]), (0..<12).contains(id),
              request["formValues"] == nil, request["pickedDate"] == nil,
              let app = ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: kernelPath, imagePath: imagePath),
              ApplicationQueries.hasReviewedSignature(app) else { return nil }
        return app
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }
}

final class WindowSnapshotReader {
    private struct Window: Encodable {
        struct Position: Encodable { let x: Double; let y: Double }
        struct Size: Encodable { let width: Double; let height: Double }
        struct Bounds: Encodable { let position: Position; let size: Size }

        let id: String
        let bounds: Bounds
        let application: ApplicationQueries.Application?
        let desktopId = "visible-desktop"
        let positionable = false
        let resizable = false
        let fullScreenSettable = false
        let active: Bool

        init(id: CGWindowID, rect: CGRect, application: ApplicationQueries.Application?, active: Bool) {
            self.id = String(id)
            bounds = Bounds(position: Position(x: rect.minX, y: rect.minY),
                            size: Size(width: rect.width, height: rect.height))
            self.active = active
            self.application = application
        }
    }

    private struct Snapshot {
        let windows: [Window]
        let active: Window?
    }

    private static let maximumWindows = 24
    private static let maximumReplyBytes = 6_000
    private let read: () throws -> Snapshot
    private var remaining = 4
    private var snapshot: Snapshot?

    private init(read: @escaping () throws -> Snapshot) {
        self.read = read
    }

    static func make(marker: Any) -> WindowSnapshotReader? {
        guard let value = ReviewedViewReadAccess.integer(marker), let pid = pid_t(exactly: value),
              pid > 0, pid != getppid(), let target = NSRunningApplication(processIdentifier: pid),
              target.activationPolicy == .regular, !target.isTerminated else { return nil }
        return WindowSnapshotReader { try readSnapshot(target: target) }
    }

    private static func readSnapshot(target: NSRunningApplication) throws -> Snapshot {
        guard !target.isTerminated,
              let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { throw CocoaError(.featureUnsupported) }

        let apps = Dictionary(NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getppid()
        }.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        return selectWindows(records, targetPID: target.processIdentifier, ownerPIDs: Set(apps.keys)) { pid in
            guard let app = apps[pid], let url = app.bundleURL?.standardizedFileURL,
                  ["/Applications/", "/System/Applications/", "/System/Library/CoreServices/"]
                    .contains(where: { url.path.hasPrefix($0) }) else { return nil }
            return ApplicationQueries.Application(url: url, name: app.localizedName, bundleId: app.bundleIdentifier)
        }
    }

    private static func selectWindows(_ records: [[String: Any]], targetPID: pid_t, ownerPIDs: Set<pid_t>,
                                      application: (pid_t) -> ApplicationQueries.Application?) -> Snapshot {
        var windows = [Window]()
        var active: Window?
        var seen = Set<CGWindowID>()
        for record in records.prefix(1_024) {
            guard record[kCGWindowLayer as String] as? Int == 0,
                  let id = record[kCGWindowNumber as String] as? CGWindowID, id != kCGNullWindowID,
                  let pid = record[kCGWindowOwnerPID as String] as? pid_t, ownerPIDs.contains(pid),
                  let bounds = record[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0, seen.insert(id).inserted else { continue }
            let isActive = active == nil && pid == targetPID
            if windows.count < Self.maximumWindows || isActive {
                let window = Window(id: id, rect: rect, application: application(pid), active: isActive)
                if isActive { active = window }
                if windows.count < Self.maximumWindows { windows.append(window) }
            }
            if active != nil, windows.count == Self.maximumWindows { break }
        }
        return Snapshot(windows: windows, active: active)
    }

    func reply(to text: String) throws -> String {
        guard remaining > 0, text == "active" || text == "desktop" else { throw CocoaError(.featureUnsupported) }
        remaining -= 1
        let value = try snapshot ?? read()
        snapshot = value
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        if text == "active" {
            return String(decoding: try encoder.encode(value.active), as: UTF8.self)
        }
        var windows = value.windows
        var data = try encoder.encode(windows)
        while data.count > Self.maximumReplyBytes {
            windows.removeLast()
            data = try encoder.encode(windows)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

final class GuestLocalStorage {
    private enum Operation: String { case get, set, remove, all, clear }
    private static let capacity = 4_096
    private let file: URL
    private let app: URL
    private lazy var signatureIsValid = ApplicationQueries.hasReviewedSignature(app)

    private init(file: URL, app: URL) {
        self.file = file
        self.app = app
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.keylane.launcher.reviewed.LocalStorage",
            kSecAttrAccount as String: file.path,
        ]
    }

    static func make(phase: String, kernelPath: String, imagePath: String) -> GuestLocalStorage? {
        guard let path = ProcessInfo.processInfo.environment["KEYLANE_REVIEWED_LOCAL_STORAGE"],
              path.hasPrefix("/"), path.utf8.count <= 4_096,
              let app = ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: kernelPath, imagePath: imagePath)
        else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.lastPathComponent == "local-storage.json" else { return nil }
        return GuestLocalStorage(file: file, app: app)
    }

    func reply(to text: String) throws -> String {
        guard signatureIsValid else { throw CocoaError(.featureUnsupported) }
        let data = Data(text.utf8)
        guard data.count <= Self.capacity + 256,
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = request["operation"] as? String, let operation = Operation(rawValue: name)
        else { throw CocoaError(.featureUnsupported) }
        let key = request["key"] as? String
        let expected: Set<String>
        switch operation {
        case .get, .remove: expected = ["operation", "key"]
        case .set: expected = ["operation", "key", "value"]
        case .all, .clear: expected = ["operation"]
        }
        guard Set(request.keys) == expected, key.map(Self.validKey) ?? !expected.contains("key")
        else { throw CocoaError(.featureUnsupported) }

        let lockPath = file.deletingLastPathComponent().appendingPathComponent("local-storage.lock").path
        let lock = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }

        var values = try load()
        switch operation {
        case .get:
            let result: [String: Any] = key.flatMap { values[$0] }.map { ["value": $0] } ?? [:]
            return String(decoding: try Self.encode(result), as: UTF8.self)
        case .all:
            return String(decoding: try Self.encode(values), as: UTF8.self)
        case .set:
            guard let key, let value = request["value"], Self.validValue(value) else { throw CocoaError(.featureUnsupported) }
            values[key] = value
        case .remove:
            guard let key, values.removeValue(forKey: key) != nil else { return "" }
        case .clear:
            values.removeAll()
        }

        let encoded = try Self.encode(values)
        guard encoded.count <= Self.capacity else { throw CocoaError(.fileWriteOutOfSpace) }
        let query = keychainQuery
        if values.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw CocoaError(.fileWriteUnknown) }
        } else {
            let attributes = [kSecValueData as String: encoded]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { current, _ in current } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        }
        return ""
    }

    private func load() throws -> [String: Any] {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else { throw CocoaError(.fileReadUnknown) }
        guard data.count <= Self.capacity,
              let values = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              values.allSatisfy({ Self.validKey($0.key) && Self.validValue($0.value) }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return values
    }

    private static func validKey(_ key: String) -> Bool {
        key.utf8.count <= capacity && key.utf8.count.isMultiple(of: 4) &&
            key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validValue(_ value: Any) -> Bool {
        if value is String { return true }
        return (value as? NSNumber)?.doubleValue.isFinite == true
    }

    private static func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .withoutEscapingSlashes)
    }
}
