import Foundation
import CoreFoundation
import Darwin
import UniformTypeIdentifiers

/// Host-owned admission state for a single extension process.
struct ExtensionPrototypeSession {
    static let maxFrameBytes = 16_384
    static let messageBudget = 128
    static let messagesPerSecond = 32

    enum Capability: String, Codable, Hashable {
        case echo
        case localStorage = "storage.request"
        case cacheCommit = "cache.commit"
        case cacheReadChunk = "cache.readChunk"
        case cacheWriteChunk = "cache.writeChunk"
        case commandMetadata = "command.updateMetadata"
        case preferencesRead = "preferences.read"
        case viewInput = "view.input"
        case viewResult = "view.result"
        case viewReadIDs = "view.readIDs"
        case viewReadPreferences = "view.readPreferences"
        case viewWriteIDs = "view.writeIDs"
        case viewProgress = "view.progress"
        case viewMemorySample = "view.memorySample"
        case reportException = "diagnostics.exception"
        case applicationsQuery = "applications.query"
        case applicationListPage = "applications.listPage"
        case clipboardRead = "clipboard.read"
        case clipboardReadChunk = "clipboard.readChunk"
        case windowRead = "window.read"
        case clipboardCopy = "clipboard.copy"
        case clipboardPaste = "clipboard.paste"
        case clipboardClear = "clipboard.clear"
        case clipboardWrite = "clipboard.write"
        case hud = "feedback.hud"
        case confirmAlert = "feedback.confirmAlert"
        case closeWindow = "navigation.closeWindow"
        case clearSearch = "navigation.clearSearch"
        case popToRoot = "navigation.popToRoot"
        case openPreferences = "preferences.open"
        case revealFile = "files.reveal"
        case trashFiles = "files.trash"
        case openTarget = "files.open"
        case toast = "feedback.toast"
        case toastAction = "feedback.toastAction"
    }

    struct Message: Decodable {
        enum Kind: String, Decodable { case hello, request }
        let kind: Kind
        let session: UUID
        let generation: UInt64
        let versions: [Int]?
        let version: Int?
        let requestID: UInt64?
        let capability: String?
        let text: String?
    }

    enum Reply: Equatable {
        case ready(version: Int)
        case result(requestID: UInt64, text: String)
        case denied(requestID: UInt64)
        case failed(requestID: UInt64)
    }

    enum Rejection: Error, Equatable {
        case closed, stale, limit, malformed, unsupportedVersion
    }

    let id: UUID
    let generation: UInt64
    private let grants: Set<Capability>
    private let handler: (Capability, String) throws -> String
    private var ready = false
    private var closed = false
    private var remaining = Self.messageBudget
    private var lastRequest: UInt64 = 0
    private var windowStart: ContinuousClock.Instant?
    private var messagesInWindow = 0
    private var applicationPagesRemaining = ExtensionApplicationListTransport.maximumPages
    private var clipboardChunksRemaining = ExtensionClipboardReadTransport.maximumChunks
    private var partialFrame = Data()

    init(id: UUID = UUID(), generation: UInt64, grants: Set<Capability>,
         handler: @escaping (Capability, String) throws -> String = { capability, text in
             guard capability == .echo else { throw CocoaError(.featureUnsupported) }
             return text
         }) {
        self.id = id
        self.generation = generation
        self.grants = grants
        self.handler = handler
    }

    static func encode(_ reply: Reply, session: UUID, generation: UInt64) throws -> Data {
        var fields: [String: Any] = ["session": session.uuidString, "generation": generation, "version": 1]
        switch reply {
        case .ready(let version):
            fields["kind"] = "ready"
            fields["version"] = version
        case .result(let requestID, let text):
            fields["kind"] = "result"
            fields["requestID"] = requestID
            fields["text"] = text
        case .denied(let requestID):
            fields["kind"] = "denied"
            fields["requestID"] = requestID
            fields["error"] = "Capability unavailable for this command"
        case .failed(let requestID):
            fields["kind"] = "failed"
            fields["requestID"] = requestID
            fields["error"] = "Host action failed"
        }
        return try JSONSerialization.data(withJSONObject: fields, options: .withoutEscapingSlashes) + Data([10])
    }

    mutating func cancel() {
        closed = true
        partialFrame.removeAll(keepingCapacity: false)
    }

    /// A frame is delivered only by the transport owned by this session.
    /// Fields inside the frame are routing assertions, never credentials.
    mutating func receiveBytes(
        _ bytes: Data, now: ContinuousClock.Instant = .now,
        charge: ((Int, Capability?) throws -> Void)? = nil, emit: (Reply) throws -> Void
    ) throws {
        guard !closed else { throw Rejection.closed }
        for byte in bytes {
            if byte == 10 {
                let frame = partialFrame
                partialFrame.removeAll(keepingCapacity: true)
                let reply: Reply
                do {
                    reply = try receive(frame, now: now, charge: charge)
                } catch Rejection.stale {
                    continue
                }
                try emit(reply)
            } else {
                guard partialFrame.count < Self.maxFrameBytes else {
                    cancel()
                    throw Rejection.limit
                }
                partialFrame.append(byte)
            }
        }
    }

    mutating func finishInput() throws {
        guard !closed else { throw Rejection.closed }
        let complete = ready && partialFrame.isEmpty
        cancel()
        guard complete else { throw Rejection.malformed }
    }

    mutating func receive(_ frame: Data, now: ContinuousClock.Instant = .now,
                          charge: ((Int, Capability?) throws -> Void)? = nil) throws -> Reply {
        guard !closed else { throw Rejection.closed }
        guard frame.count <= Self.maxFrameBytes else {
            cancel()
            throw Rejection.limit
        }
        if windowStart.map({ $0.duration(to: now) >= .seconds(1) }) ?? true {
            windowStart = now
            messagesInWindow = 0
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: frame) else {
            cancel()
            throw Rejection.malformed
        }
        let current = message.session == id && message.generation == generation
        let requested = message.capability.flatMap(Capability.init(rawValue:))
        let trusted = current && ready && message.kind == .request && requested.map(grants.contains) == true
        if trusted, requested == .applicationListPage {
            guard applicationPagesRemaining > 0 else {
                cancel()
                throw Rejection.limit
            }
            applicationPagesRemaining -= 1
        } else {
            guard remaining > 0 else {
                cancel()
                throw Rejection.limit
            }
            remaining -= 1
            if trusted, requested == .clipboardReadChunk {
                guard clipboardChunksRemaining > 0 else {
                    cancel()
                    throw Rejection.limit
                }
                clipboardChunksRemaining -= 1
            } else {
                guard messagesInWindow < Self.messagesPerSecond else {
                    cancel()
                    throw Rejection.limit
                }
                messagesInWindow += 1
            }
        }
        guard current else {
            try charge?(frame.count + 1, nil)
            throw Rejection.stale
        }

        switch message.kind {
        case .hello:
            guard !ready, let versions = message.versions, message.version == nil,
                  message.requestID == nil, message.capability == nil, message.text == nil else {
                cancel()
                throw Rejection.malformed
            }
            guard versions.contains(1) else {
                cancel()
                throw Rejection.unsupportedVersion
            }
            try charge?(frame.count + 1, nil)
            ready = true
            return .ready(version: 1)
        case .request:
            guard ready, message.version == 1, message.versions == nil,
                  let requestID = message.requestID, requestID > lastRequest,
                  let name = message.capability, let text = message.text else {
                cancel()
                throw Rejection.malformed
            }
            lastRequest = requestID
            guard let capability = Capability(rawValue: name), grants.contains(capability) else {
                try charge?(frame.count + 1, nil)
                return .denied(requestID: requestID)
            }
            try charge?(frame.count + 1, capability)
            do {
                return .result(requestID: requestID, text: try handler(capability, text))
            } catch {
                return .failed(requestID: requestID)
            }
        }
    }
}

enum ExtensionApplicationListTransport {
    static let maximumPages = 1_024
    static let maximumTrafficBytes = 8 * 1024 * 1024
}

public struct RaycastApplicationValue: Codable, Equatable, Sendable {
    public let name: String
    public let localizedName: String?
    public let path: String
    public let bundleId: String?

    public init?(url: URL, name: String? = nil, bundleId: String? = nil) {
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let path = Self.clean(url.standardizedFileURL.path, maximumBytes: 512) else { return nil }
        self.path = path
        let bundle = Bundle(url: url)
        let filename = url.deletingPathExtension().lastPathComponent
        guard let title = Self.clean(bundle?.infoDictionary?["CFBundleDisplayName"] as? String, maximumBytes: 128)
                ?? Self.clean(bundle?.infoDictionary?["CFBundleName"] as? String, maximumBytes: 128)
                ?? Self.clean(name, maximumBytes: 128)
                ?? Self.clean(filename, maximumBytes: 128) else { return nil }
        self.name = title
        localizedName = Self.clean(name, maximumBytes: 128)
            ?? Self.clean(bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String, maximumBytes: 128)
            ?? Self.clean(bundle?.localizedInfoDictionary?["CFBundleName"] as? String, maximumBytes: 128)
        self.bundleId = Self.clean(bundleId ?? bundle?.bundleIdentifier, maximumBytes: 128)
    }

    init?(indexedURL url: URL, localizedName: String?, bundleId: String?) {
        guard url.pathExtension.lowercased() == "app",
              let path = Self.clean(url.path, maximumBytes: 512),
              let name = Self.clean(url.deletingPathExtension().lastPathComponent, maximumBytes: 128) else { return nil }
        self.path = path
        self.name = name
        self.localizedName = Self.clean(localizedName, maximumBytes: 128)
        self.bundleId = Self.clean(bundleId, maximumBytes: 128)
    }

    private static func clean(_ value: String?, maximumBytes: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximumBytes,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
}


/// Extra bounded room for value and field definition snapshots in reviewed view requests.
public enum ExtensionViewPreferencesTransport {
    public static let inlineBytes = 2_048
    public static let maximumBytes = 16_384
    public static let chunkBytes = 8_192
    public static let keys = ["preferences", "preferenceDefinitions"]

    public static func snapshot(in request: [String: Any]) throws -> Data? {
        let fields = request.filter { keys.contains($0.key) }
        guard !fields.isEmpty else { return nil }
        let data = try JSONSerialization.data(withJSONObject: fields, options: .withoutEscapingSlashes)
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }
}

/// One audited view package in the preview application's sealed resources.
public struct ReviewedViewArtifact: Decodable {
    public let slug: String
    public let owner: String
    private let command: String?
    private let commands: [Command]?
    public let revision: String
    public let title: String
    public let description: String

    public struct Command: Decodable {
        public enum Mode: String, Decodable { case view, noView = "no-view" }

        public let name: String
        public let title: String
        public let description: String
        fileprivate let mode: Mode?
        public var entryMode: Mode { mode ?? .view }
    }

    public var artifactName: String { "view-" + slug }
    public var usesNamedEntryPoints: Bool { commands != nil }
    public var entryPoints: [Command] {
        commands ?? command.map { [Command(name: $0, title: title, description: description, mode: nil)] } ?? []
    }

    public static func isViewImage(_ name: String) -> Bool {
        guard name != "view.cpio" else { return true }
        return name.hasPrefix("view-") && name.hasSuffix(".cpio") &&
            validIdentifier(String(name.dropFirst(5).dropLast(5)))
    }

    public static func loadCatalog(in resourceDirectory: URL) -> [Self] {
        let path = resourceDirectory.appendingPathComponent("view-catalog.json")
        guard let attributes = try? path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink == false,
              let file = try? FileHandle(forReadingFrom: path) else { return [] }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 16_385), data.count <= 16_384,
              let entries = try? JSONDecoder().decode([Self].self, from: data),
              entries.count <= 32,
              Set(entries.map(\.slug)).count == entries.count,
              entries.allSatisfy(\.isValid) else { return [] }
        return entries
    }

    private var isValid: Bool {
        let entries = entryPoints
        return Self.validIdentifier(slug) && slug == slug.lowercased() &&
            !["chmod-lookup", "uuid-generator", "work-time-countdown"].contains(slug) &&
            Self.validIdentifier(owner) && (command == nil) != (commands == nil) &&
            revision.utf8.count == 40 && revision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            Self.validText(title: title, description: description) &&
            (1...16).contains(entries.count) && Set(entries.map(\.name)).count == entries.count &&
            entries.allSatisfy {
                Self.validIdentifier($0.name) && Self.validText(title: $0.title, description: $0.description)
            }
    }

    private static func validText(title: String, description: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.utf8.count <= 128 &&
            description.utf8.count <= 512 &&
            ![title, description].flatMap(\.unicodeScalars).contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func validIdentifier(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count), let first = text.utf8.first, (97...122).contains(first) else { return false }
        return text.utf8.allSatisfy { (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0)
            || $0 == 95 || $0 == 45
        }
    }
}

/// Validated feedback shared by the app and its isolated extension helper.
public struct ExtensionHUDRequest: Codable {
    public static let prefix = "guest-hud="
    public static let accepted = "hud:shown"
    public static let rejected = "hud:rejected"

    public static func replyFrame(shown: Bool) -> Data {
        Data(((shown ? accepted : rejected) + "\n").utf8)
    }

    public enum PopToRootType: String, Codable { case `default`, immediate, suspended }

    public let text: String
    public let clearRootSearch: Bool
    public let popToRootType: PopToRootType

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        clearRootSearch = try values.decode(Bool.self, forKey: .clearRootSearch)
        popToRootType = try values.decode(PopToRootType.self, forKey: .popToRootType)
        guard text.utf8.count <= 2_048 else {
            throw DecodingError.dataCorruptedError(forKey: .text, in: values, debugDescription: "HUD title exceeds the feedback limit")
        }
    }

    private enum CodingKeys: String, CodingKey { case text, clearRootSearch, popToRootType }
}


/// Exception reports carry a fixed category only. Guest values never cross this API.
public enum ExtensionExceptionCategory: String, Codable {
    case error, undefined, boolean, number, bigint, string, symbol, function, object

    public static let maximumReports = 16
    public static let outputPrefix = "guest-exception="

    public init?(line: Data) {
        guard line.starts(with: Self.outputPrefix.utf8), line.count <= Self.outputPrefix.utf8.count + 9 else { return nil }
        self.init(rawValue: String(decoding: line.dropFirst(Self.outputPrefix.utf8.count), as: UTF8.self))
    }
}

/// A checkpoint contains heap sizes and an optional display label, never a heap dump.
public struct ExtensionMemorySample: Codable {
    public static let prefix = "guest-memory-sample="
    public static let maximumCount = 16

    public let label: String?
    public let heapUsed: Int
    public let heapTotal: Int

    public var isValid: Bool {
        heapUsed >= 0 && heapUsed <= heapTotal && heapTotal <= 384 * 1024 * 1024 &&
            (label.map { $0.utf8.count <= 384 &&
                $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } } ?? true)
    }
}

/// View IDs travel apart from the render payload and never enlarge the per-frame limit.
public enum ExtensionViewIDTransport {
    public static let maximumEntries = 96
    public static let maximumSnapshotBytes = 6_144
    public static let maximumResultBytes = 10_240 + maximumSnapshotBytes + 32
    public static let chunkBytes = 8_192
    public static let maximumRequestBytes = (maximumSnapshotBytes + 1) * 6 + 32
    public static let mountSeedSlot = 9_007_199_254_740_991

    public static func validSeed(_ text: String) -> Bool {
        text.utf8.count == 12 && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    public static func validateSnapshot(_ entries: Any) throws -> Data {
        guard let entries = entries as? [[Any]], entries.count <= maximumEntries else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var slots: Set<Int> = []
        for entry in entries {
            guard entry.count == 2, let number = entry[0] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), let slot = Int(number.stringValue),
                  (0...mountSeedSlot).contains(slot), slots.insert(slot).inserted,
                  let value = entry[1] as? String, value.utf8.count <= 256, slot != mountSeedSlot || validSeed(value)
            else { throw CocoaError(.fileReadCorruptFile) }
        }
        let data = try JSONSerialization.data(withJSONObject: entries, options: .withoutEscapingSlashes)
        guard data.count <= maximumSnapshotBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    public static func splitRequest(_ object: inout [String: Any]) throws -> Data? {
        func take(_ frame: inout [String: Any]) throws -> Any {
            guard let entries = frame.removeValue(forKey: "viewIDs") else { return NSNull() }
            _ = try validateSnapshot(entries)
            return entries
        }
        var snapshots = [try take(&object)]
        if var popped = object["poppedFrame"] as? [String: Any] {
            snapshots.append(try take(&popped))
            object["poppedFrame"] = popped
        } else {
            snapshots.append(NSNull())
        }
        if var route = object["viewRoute"] as? [[String: Any]] {
            guard route.count <= 4 else { throw CocoaError(.fileReadCorruptFile) }
            for index in route.indices { snapshots.append(try take(&route[index])) }
            object["viewRoute"] = route
        }
        guard snapshots.contains(where: { !($0 is NSNull) }) else { return nil }
        let data = try JSONSerialization.data(withJSONObject: snapshots, options: .withoutEscapingSlashes)
        guard data.count <= maximumRequestBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    public static func requestBaseFits(_ data: Data, within limit: Int) -> Bool {
        if data.count <= limit { return true }
        do {
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            _ = try splitRequest(&object)
            _ = try ExtensionViewPreferencesTransport.snapshot(in: object)
            for key in ExtensionViewPreferencesTransport.keys { object.removeValue(forKey: key) }
            return try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes).count <= limit
        } catch {
            return false
        }
    }
}

/// Cache snapshots have a separate bounded transfer so view and navigation payloads retain their limits.
public enum ExtensionCacheTransport {
    public static let maximumSnapshotBytes = 32 * 1024 + 128
    public static let maximumInputBytes = 8_192 + maximumSnapshotBytes
    public static let maximumTrafficBytes = 52 * 1024
    public static let inlineBytes = 4_224
    public static let chunkBytes = 8_192
    public static let outputPrefix = "guest-cache="

    public static func entries(_ data: Data) throws -> [[String]] {
        guard data.count <= maximumSnapshotBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let entries = try JSONDecoder().decode([[String]].self, from: data)
        guard entries.count <= 64, entries.allSatisfy({ $0.count == 2 }) else { throw CocoaError(.fileReadCorruptFile) }
        return entries
    }

    public static func decodeOutput(_ line: Data) -> [[String]]? {
        guard line.starts(with: outputPrefix.utf8),
              line.count <= outputPrefix.count + (maximumSnapshotBytes + 2) / 3 * 4,
              let data = Data(base64Encoded: Data(line.dropFirst(outputPrefix.count))) else { return nil }
        return try? entries(data)
    }
}

/// Clears the active extension query and optionally resets the results scroll position.
public struct ExtensionClearSearchRequest: Codable {
    public static let prefix = "guest-clear-search="
    public static let accepted = "clear-search:done"
    public static let rejected = "clear-search:rejected"

    public let forceScrollToTop: Bool

    public static func replyFrame(cleared: Bool) -> Data {
        Data(((cleared ? accepted : rejected) + "\n").utf8)
    }
}

/// Return to the launcher root and optionally clear its saved query.
public struct ExtensionPopToRootRequest: Codable {
    public static let prefix = "guest-pop-to-root="
    public static let accepted = "pop-to-root:done"
    public static let rejected = "pop-to-root:rejected"

    public let clearSearchBar: Bool
}

/// The isolated command supplies window policy only, without access to native windows.
public struct ExtensionCloseWindowRequest: Codable {
    public static let prefix = "guest-close-window="
    public static let accepted = "close:done"
    public static let rejected = "close:rejected"

    public static func replyFrame(closed: Bool) -> Data {
        Data(((closed ? accepted : rejected) + "\n").utf8)
    }

    public let clearRootSearch: Bool
    public let popToRootType: ExtensionHUDRequest.PopToRootType
}


/// Bounded alert configuration from a reviewed extension command.
public struct ExtensionAlertRequest: Codable {
    public struct Action: Codable {
        public enum Style: String, Codable { case `default`, cancel, destructive }
        public let title: String?
        public let style: Style
    }

    public let title: String
    public let message: String?
    public let primaryAction: Action
    public let dismissAction: Action
    public let rememberUserChoice: Bool
    public let icon: Data?

    public var isValid: Bool {
        func validTitle(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && value.utf8.count <= 256 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        return validTitle(title) && (message?.utf8.count ?? 0) <= 2048
            && (primaryAction.title.map(validTitle) ?? true) && (dismissAction.title.map(validTitle) ?? true)
            && (icon?.count ?? 0) <= 4096
    }
}

/// The helper generates a fresh identity for each presentation.
public struct ExtensionAlertEvent: Codable {
    public enum Reply: String { case shown, primary, dismiss, unavailable }

    public static let requestPrefix = "guest-confirm-alert="
    public static let expiredPrefix = "guest-alert-expired="
    public let id: UUID
    public let request: ExtensionAlertRequest

    private var replyPrefix: String { "alert:\(id.uuidString):" }

    public func replyFrame(_ reply: Reply) -> Data {
        Data((replyPrefix + reply.rawValue + "\n").utf8)
    }

    func decodeReply(_ line: String) -> Reply? {
        guard line.hasPrefix(replyPrefix) else { return nil }
        return Reply(rawValue: String(line.dropFirst(replyPrefix.count)))
    }
}

/// Accounts for command time separately from time spent in a native confirmation.
final class ExtensionExecutionBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: ContinuousClock.Instant
    private var confirmationRemaining: Duration
    private var confirmationStart: ContinuousClock.Instant?

    init(deadline: ContinuousClock.Instant, confirmationAllowance: Duration = .seconds(60)) {
        self.deadline = deadline
        confirmationRemaining = confirmationAllowance
    }

    var watchdogDeadline: ContinuousClock.Instant {
        lock.withLock { confirmationStart == nil ? deadline : deadline + confirmationRemaining }
    }

    var replyDeadline: ContinuousClock.Instant {
        lock.withLock { deadline - .seconds(2) }
    }

    func beginConfirmation(at now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant? {
        lock.withLock {
            guard confirmationStart == nil, now < deadline - .seconds(2), confirmationRemaining > .zero else { return nil }
            confirmationStart = now
            return now + confirmationRemaining
        }
    }

    func endConfirmation(at now: ContinuousClock.Instant = .now) {
        lock.withLock {
            guard let start = confirmationStart else { return }
            let elapsed = min(confirmationRemaining, max(.zero, start.duration(to: now)))
            confirmationRemaining -= elapsed
            deadline += elapsed
            confirmationStart = nil
        }
    }
}

enum ReviewedExtensionStateDirectory {
    static func localStorageURL(path: String, slug: String) -> URL? {
        guard path.hasPrefix("/"), path.utf8.count <= 4_096 else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let directory = file.deletingLastPathComponent()
        let extensions = directory.deletingLastPathComponent()
        guard file.lastPathComponent == "local-storage.json", directory.lastPathComponent == slug,
              extensions.lastPathComponent == "Extensions",
              directory.resolvingSymlinksInPath().path ==
                extensions.resolvingSymlinksInPath().appendingPathComponent(slug).path else { return nil }
        return file
    }
}

/// Serializes extension storage transactions within the broker's reply budget.
enum ExtensionStorageLock {
    static func acquire(_ descriptor: Int32, until deadline: ContinuousClock.Instant) throws {
        while ContinuousClock.now < deadline {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            let failure = errno
            if failure == EINTR { continue }
            guard failure == EWOULDBLOCK else { throw CocoaError(.fileWriteUnknown) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw CocoaError(.fileLocking)
    }
}

/// One subtitle per installed command. The guest never selects a host filename.
public struct ReviewedRaycastCommandMetadata {
    public static let changeLine = "guest-command-metadata-changed"
    private let file: URL

    public init?(installationDirectory: URL, command: String) {
        guard (1...64).contains(command.utf8.count),
              command.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 95
              }) else { return nil }
        file = installationDirectory.appendingPathComponent("command-subtitle-" + command + ".txt")
    }

    public var subtitle: String? {
        guard let attributes = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            let data = try handle.read(upToCount: 1_025) ?? Data()
            return data.count <= 1_024 ? String(data: data, encoding: .utf8) : nil
        } catch {
            return nil
        }
    }

    public func update(subtitle: String?) throws {
        if let subtitle {
            guard subtitle.utf8.count <= 1_024,
                  !subtitle.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
                throw CocoaError(.featureUnsupported)
            }
            try Data(subtitle.utf8).write(to: file, options: .atomic)
        } else {
            do {
                try FileManager.default.removeItem(at: file)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
    }

    public static func removeAll(installationDirectory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: installationDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for file in files where file.lastPathComponent.hasPrefix("command-subtitle-") && file.pathExtension == "txt" {
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if attributes.isRegularFile == true || attributes.isSymbolicLink == true {
                try FileManager.default.removeItem(at: file)
            }
        }
    }
}


/// A request can select an owning extension or its running command, never an arbitrary settings page.
public struct ExtensionPreferencesEvent: Codable {
    public enum Target: String, Codable { case `extension`, command }

    public static let prefix = "guest-open-preferences="
    public let id: UUID
    public let target: Target

    public func replyFrame(opened: Bool) -> Data {
        Data("preferences:\(id.uuidString):\(opened ? "opened" : "rejected")\n".utf8)
    }
}

/// A selected view action waits for Finder to accept the validated file.
public struct ExtensionFinderRevealEvent: Codable {
    public static let prefix = "guest-reveal-file="
    public let id: UUID
    public let path: String

    public static func isValidPath(_ path: String) -> Bool {
        path.utf8.count <= 2_048 && path.hasPrefix("/") && !path.hasPrefix("//") &&
            !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) &&
            !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    /// Resolves the guest home alias only for the host's Finder operation.
    public static func hostURL(for path: String, homeDirectory: URL) -> URL? {
        guard isValidPath(path) else { return nil }
        let guestHome = "/keylane-host-home"
        let source = path == guestHome || path.hasPrefix(guestHome + "/")
            ? homeDirectory.path + String(path.dropFirst(guestHome.count))
            : path
        return URL(fileURLWithPath: source).standardizedFileURL
    }

    public func replyFrame(revealed: Bool) -> Data {
        Data("finder:\(id.uuidString):\(revealed ? "revealed" : "rejected")\n".utf8)
    }
}

/// A host-owned confirmation and its eventual file operation result.
public struct ExtensionTrashEvent: Codable {
    public enum Reply: String { case shown, moved, cancelled, failed }

    public static let prefix = "guest-trash-files="
    public static let expiredPrefix = "guest-trash-expired="
    public let id: UUID
    public let paths: [String]

    public var isValid: Bool {
        (1...8).contains(paths.count) && Set(paths).count == paths.count &&
            paths.allSatisfy { $0 != "/" && ExtensionFinderRevealEvent.isValidPath($0) } &&
            paths.reduce(0) { $0 + $1.utf8.count } <= 4_096
    }

    private var replyPrefix: String { "trash:\(id.uuidString):" }

    public func replyFrame(_ reply: Reply) -> Data {
        Data((replyPrefix + reply.rawValue + "\n").utf8)
    }

    func decodeReply(_ line: String) -> Reply? {
        guard line.hasPrefix(replyPrefix) else { return nil }
        return Reply(rawValue: String(line.dropFirst(replyPrefix.count)))
    }
}

/// An open request is acknowledged only after Launch Services finishes.
public struct ExtensionOpenEvent: Codable {
    public struct Request: Codable {
        public struct Application: Codable {
            public let path: String?
            public let bundleId: String?
            public let name: String?
        }

        public let url: String?
        public let path: String?
        public let application: Application?

        public init(url: String?, path: String?, application: Application?) {
            self.url = url
            self.path = path
            self.application = application
        }

        public var isValid: Bool {
            guard (url != nil) != (path != nil) else { return false }
            if let url, url.isEmpty || url.utf8.count > 2_048 { return false }
            if let path {
                let absolutePath = path.hasPrefix("~/") ? String(path.dropFirst()) : path
                guard ExtensionFinderRevealEvent.isValidPath(absolutePath) else { return false }
            }
            if let application {
                guard application.path != nil || application.bundleId != nil || application.name != nil else { return false }
                if let path = application.path, !ExtensionFinderRevealEvent.isValidPath(path) { return false }
                let identifiers = [application.bundleId, application.name].compactMap { $0 }
                guard identifiers.allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 &&
                        !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                }) else { return false }
            }
            return true
        }
    }

    public static func safeFile(_ url: URL) -> URL? {
        let resolved = url.resolvingSymlinksInPath()
        guard let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .contentTypeKey]),
              values.isPackage != true, values.contentType?.conforms(to: .applicationBundle) != true else { return nil }
        if values.isDirectory == true { return resolved }
        guard values.isRegularFile == true,
              values.contentType?.conforms(to: .executable) != true,
              values.contentType?.conforms(to: .script) != true,
              !FileManager.default.isExecutableFile(atPath: resolved.path) else { return nil }
        return resolved
    }

    public static let prefix = "guest-open-target="
    public let id: UUID
    public let request: Request

    public init(id: UUID, request: Request) {
        self.id = id
        self.request = request
    }

    public func confirmation(title: String, message: String) -> ExtensionAlertEvent {
        ExtensionAlertEvent(id: id, request: ExtensionAlertRequest(
            title: title, message: message,
            primaryAction: .init(title: "打开", style: .default),
            dismissAction: .init(title: "取消", style: .cancel),
            rememberUserChoice: false, icon: nil
        ))
    }

    public var shownFrame: Data { Data("open:\(id.uuidString):shown\n".utf8) }

    func decodeReply(_ line: String) -> String? {
        let prefix = "open:\(id.uuidString):"
        guard line.hasPrefix(prefix) else { return nil }
        let reply = String(line.dropFirst(prefix.count))
        return ["shown", "opened", "rejected"].contains(reply) ? reply : nil
    }

    public func replyFrame(opened: Bool) -> Data {
        Data("open:\(id.uuidString):\(opened ? "opened" : "rejected")\n".utf8)
    }
}

/// The host confirms a clipboard mutation without accepting contents from the guest.
public struct ExtensionClipboardClearEvent: Codable {
    public enum Reply: String { case shown, cleared, cancelled, changed, failed }

    public static let prefix = "guest-clear-clipboard="
    public let id: UUID

    public var confirmation: ExtensionAlertEvent {
        ExtensionAlertEvent(id: id, request: ExtensionAlertRequest(
            title: "允许此扩展清空剪贴板？", message: nil,
            primaryAction: .init(title: "清空", style: .destructive),
            dismissAction: .init(title: "取消", style: .cancel),
            rememberUserChoice: false, icon: nil
        ))
    }

    private var replyPrefix: String { "clipboard-clear:\(id.uuidString):" }

    public func replyFrame(_ reply: Reply) -> Data {
        Data((replyPrefix + reply.rawValue + "\n").utf8)
    }

    func decodeReply(_ line: String) -> Reply? {
        guard line.hasPrefix(replyPrefix) else { return nil }
        return Reply(rawValue: String(line.dropFirst(replyPrefix.count)))
    }
}
