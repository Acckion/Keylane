import AppKit
import CoreFoundation
import CoreServices
import Darwin
import Foundation
import Security
import UniformTypeIdentifiers
import Virtualization

final class GuestProbe: NSObject, VZVirtioSocketListenerDelegate {
    let id = UUID()
    let started: ContinuousClock.Instant
    let executionBudget: ExtensionExecutionBudget
    let expected: String?
    let phase: String
    let viewInput: String?
    let preferences: String?
    let acknowledgesHUD: Bool
    let framedToast: Bool
    let paste: Bool
    let sensitiveFormSubmission: Bool
    let interactiveToast: Bool
    private let applicationQueries: ApplicationQueries?
    private let clipboardReader: ClipboardContentReader?
    private let windowReader: WindowSnapshotReader?
    private let localStorage: GuestLocalStorage?
    private let commandMetadata: ReviewedRaycastCommandMetadata?
    let serial = Pipe()
    var serialBytes = 0
    var cancellation: DispatchSourceSignal?
    private var deadlineCheck: DispatchWorkItem?

    init(phase: String, expected: String?, viewInput: String?, preferences: String?, acknowledgesHUD: Bool, framedToast: Bool, paste: Bool,
         sensitiveFormSubmission: Bool, interactiveToast: Bool, applicationQueries: ApplicationQueries?, clipboardReader: ClipboardContentReader?,
         windowReader: WindowSnapshotReader?, localStorage: GuestLocalStorage?, commandMetadata: ReviewedRaycastCommandMetadata?) {
        let started = ContinuousClock.now
        self.started = started
        let timeout = ["stall": 2, "noview-backpressure": 4][phase] ?? 12
        executionBudget = ExtensionExecutionBudget(deadline: started + .seconds(timeout))
        self.phase = phase
        self.expected = expected
        self.viewInput = viewInput
        self.preferences = preferences
        self.acknowledgesHUD = acknowledgesHUD
        self.framedToast = framedToast
        self.paste = paste
        self.sensitiveFormSubmission = sensitiveFormSubmission
        self.interactiveToast = interactiveToast
        self.applicationQueries = applicationQueries
        self.clipboardReader = clipboardReader
        self.windowReader = windowReader
        self.localStorage = localStorage
        self.commandMetadata = commandMetadata
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
                                       preferences: self.preferences, expected: self.expected, acknowledgesHUD: self.acknowledgesHUD, framedToast: self.framedToast, paste: self.paste,
                                       sensitiveFormSubmission: self.sensitiveFormSubmission, interactiveToast: self.interactiveToast,
                                       applicationQueries: self.applicationQueries, clipboardReader: self.clipboardReader,
                                       windowReader: self.windowReader, localStorage: self.localStorage, commandMetadata: self.commandMetadata,
                                       executionBudget: self.executionBudget, alertWaitEnded: {
                                           DispatchQueue.main.async { self.checkDeadline() }
                                       })
            let success: Bool
            if let expected = self.expected {
                success = result?.value == expected
            } else {
                success = result.flatMap { Data(base64Encoded: $0.value) }.map { !$0.isEmpty } ?? false
            }
            DispatchQueue.main.async {
                guard !self.stopped else { return }
                if success, let result {
                    if let cache = result.cache {
                        FileHandle.standardOutput.write(Data("\(ExtensionCacheTransport.outputPrefix)\(cache.base64EncodedString())\n".utf8))
                    }
                    print("guest-result=\(result.value)")
                }
                self.finish(success: success)
            }
        }
        return true
    }

    static func exchange(_ descriptor: Int32, id: UUID, phase: String, viewInput: String?,
                         preferences: String?, expected: String?, acknowledgesHUD: Bool, framedToast: Bool, paste: Bool, sensitiveFormSubmission: Bool, interactiveToast: Bool,
                         applicationQueries: ApplicationQueries?, clipboardReader: ClipboardContentReader?,
                         windowReader: WindowSnapshotReader?, localStorage: GuestLocalStorage?,
                         commandMetadata: ReviewedRaycastCommandMetadata?, executionBudget: ExtensionExecutionBudget, alertWaitEnded: @escaping () -> Void) -> (value: String, cache: Data?)? {
        let io = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let noView = phase.hasPrefix("noview-")
        var grants: Set<ExtensionPrototypeSession.Capability> = [.echo]
        if noView { grants.formUnion([.clipboardCopy, .hud, .toast]) }
        if viewInput != nil { grants = [.viewInput, .viewResult] }
        let liveViewToast = phase == "view-app" && !sensitiveFormSubmission &&
            viewInput.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .map { input in
                    guard input["action"] is [String: Any] else { return false }
                    if input["formValues"] != nil {
                        return interactiveToast && input["liveFormToast"] as? Bool == true
                    }
                    return input["liveToast"] as? Bool == true
                } == true

        let application = phase == "noview-app"
        let liveMenuToast = phase == "view-app" && interactiveToast &&
            viewInput.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .map { $0["mode"] as? String == "menuBar" && $0["menuAlertAllowed"] as? Bool == true } == true
        if liveViewToast || liveMenuToast { grants.insert(.toast) }
        let allowsToastAction = interactiveToast && (liveViewToast || liveMenuToast || application)
        if allowsToastAction { grants.insert(.toastAction) }
        let liveViewClose = phase == "view-app" && !sensitiveFormSubmission &&
            viewInput.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .map { $0["navigationCloseAllowed"] as? Bool == true } == true
        let validatedViewInput = viewInput.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let initialViewWindow = phase == "view-app" && !sensitiveFormSubmission &&
            validatedViewInput?["initialPreferencesAllowed"] as? Bool == true &&
            validatedViewInput?["mountNavigation"] as? Bool == true
        if liveViewClose { grants.formUnion([.clearSearch, .popToRoot]) }
        if phase == "view-app", !sensitiveFormSubmission,
           validatedViewInput?["searchClearAllowed"] as? Bool == true {
            grants.insert(.clearSearch)
        }
        if liveMenuToast || initialViewWindow { grants.insert(.closeWindow) }
        let liveCatalogNavigation = phase == "view-app" && framedToast && validatedViewInput?["catalogNoView"] as? Bool == true
        if liveCatalogNavigation { grants.formUnion([.hud, .clearSearch, .popToRoot, .closeWindow]) }
        if liveViewClose || liveMenuToast || initialViewWindow { grants.insert(.hud) }
        if liveViewClose || (application && framedToast && interactiveToast) {
            grants.formUnion([.closeWindow, .confirmAlert, .openPreferences])
        }
        if phase == "view-app", !sensitiveFormSubmission, let viewInput,
           let input = try? JSONSerialization.jsonObject(with: Data(viewInput.utf8)) as? [String: Any],
           input["menuAlertAllowed"] as? Bool == true {
            grants.formUnion([.confirmAlert, .openPreferences, .popToRoot, .clearSearch])
        }
        if phase == "view-app", let viewInput,
           let input = try? JSONSerialization.jsonObject(with: Data(viewInput.utf8)) as? [String: Any],
           input["initialPreferencesAllowed"] as? Bool == true {
            grants.formUnion([.openPreferences, .popToRoot])
        }
        let interactiveNoView = application && framedToast && interactiveToast
        if interactiveNoView { grants.formUnion([.popToRoot, .clearSearch]) }
        if validatedViewInput?["finderRevealAllowed"] as? Bool == true || interactiveNoView {
            grants.formUnion([.revealFile, .trashFiles, .clipboardClear])
        }
        if phase == "view-app", validatedViewInput?["finderRevealAllowed"] as? Bool == true {
            grants.insert(.clipboardWrite)
        }
        if interactiveNoView && !paste { grants.insert(.clipboardWrite) }
        if validatedViewInput?["openTargetAllowed"] as? Bool == true || interactiveNoView {
            grants.insert(.openTarget)
        }
        let interactiveSuite = phase == "uuid-storage-app" && validatedViewInput?["suitePreferencesAllowed"] as? Bool == true
        if interactiveSuite {
            grants.formUnion([.openPreferences, .popToRoot, .clearSearch, .closeWindow, .hud])
        }
        if commandMetadata != nil { grants.insert(.commandMetadata) }
        if phase == "view-app", !sensitiveFormSubmission, validatedViewInput?["progressUpdates"] as? Bool == true,
           validatedViewInput?["mode"] == nil, validatedViewInput?["action"] == nil {
            grants.insert(.viewProgress)
        }
        var viewResult: String?
        var publishedProgress = 0
        var cacheUpdate: Data?
        var pendingCache = Data()
        var readOffset = 0
        var cacheInput: Data?
        var viewIDInput: Data?
        var viewIDUpdate: Any?
        var viewIDOffset = 0
        var viewPreferencesInput: Data?
        var viewPreferencesOffset = 0
        var viewPayload = viewInput
        var preferencePayload = preferences
        func prepareCache(_ payload: String?) throws -> String? {
            guard let payload, var object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
            else { return payload }
            object.removeValue(forKey: "cacheSnapshotBytes")
            object.removeValue(forKey: "viewIDSnapshotBytes")
            if phase == "view-app", let snapshots = try ExtensionViewIDTransport.splitRequest(&object) {
                viewIDInput = snapshots
                object["viewIDSnapshotBytes"] = snapshots.count
            }
            object.removeValue(forKey: "viewPreferencesSnapshotBytes")
            if phase == "view-app", let snapshot = try ExtensionViewPreferencesTransport.snapshot(in: object),
               snapshot.count > ExtensionViewPreferencesTransport.inlineBytes {
                viewPreferencesInput = snapshot
                for key in ExtensionViewPreferencesTransport.keys { object.removeValue(forKey: key) }
                object["viewPreferencesSnapshotBytes"] = snapshot.count
            }
            if let snapshot = object["cache"], !sensitiveFormSubmission {
                let data = try JSONSerialization.data(withJSONObject: snapshot, options: .withoutEscapingSlashes)
                if snapshot is [[String]] {
                    _ = try ExtensionCacheTransport.entries(data)
                } else {
                    guard let legacy = snapshot as? [String: String], legacy.count <= 64,
                          data.count <= ExtensionCacheTransport.inlineBytes else { throw CocoaError(.featureUnsupported) }
                }
                if data.count > ExtensionCacheTransport.inlineBytes {
                    cacheInput = data
                    object.removeValue(forKey: "cache")
                    object["cacheSnapshotBytes"] = data.count
                }
                grants.insert(.cacheWriteChunk)
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes), as: UTF8.self)
        }
        do {
            if viewInput != nil { viewPayload = try prepareCache(viewInput) }
            if application { preferencePayload = try prepareCache(preferences) }
        } catch { return nil }
        if cacheInput != nil { grants.insert(.cacheReadChunk) }
        if viewIDInput != nil { grants.insert(.viewReadIDs) }
        if viewPreferencesInput != nil { grants.insert(.viewReadPreferences) }
        if phase == "view-app", !sensitiveFormSubmission { grants.insert(.viewWriteIDs) }
        if application {
            grants.remove(.clipboardCopy)
            grants.formUnion([.preferencesRead, paste ? .clipboardPaste : .clipboardCopy])
            if grants.contains(.cacheWriteChunk) { grants.insert(.cacheCommit) }
        }
        if phase == "view-app", !sensitiveFormSubmission,
           validatedViewInput?["memoryReporting"] as? Bool == true, validatedViewInput?["mode"] == nil,
           validatedViewInput?["action"] == nil {
            grants.insert(.viewMemorySample)
        }
        var memorySampleCount = 0
        var exceptionCount = 0
        if !sensitiveFormSubmission, applicationQueries != nil { grants.insert(.reportException) }
        if !sensitiveFormSubmission, applicationQueries != nil { grants.formUnion([.applicationsQuery, .applicationListPage]) }
        if !sensitiveFormSubmission, clipboardReader != nil { grants.formUnion([.clipboardRead, .clipboardReadChunk]) }
        if !sensitiveFormSubmission, windowReader != nil { grants.insert(.windowRead) }
        if !sensitiveFormSubmission, localStorage != nil { grants.insert(.localStorage) }
        var requestedClipboardText: String?
        var requestedPresentation = false
        var acknowledgedPresentation = false
        var toastState = GuestToastState()
        let pasteboard = noView && !application ? NSPasteboard(name: .init("org.keylane.prototype.\(id.uuidString)")) : nil
        defer { pasteboard?.releaseGlobally() }
        func writeClipboard(_ request: ExtensionClipboardWriteEvent.Request, deadline: ContinuousClock.Instant) throws {
            let event = ExtensionClipboardWriteEvent(id: UUID(), request: request)
            try FileHandle.standardOutput.write(contentsOf: Data(ExtensionClipboardWriteEvent.prefix.utf8) +
                (try JSONEncoder().encode(event)) + Data([10]))
            let accepted = String(decoding: event.replyFrame(written: true).dropLast(), as: UTF8.self)
            let rejected = String(decoding: event.replyFrame(written: false).dropLast(), as: UTF8.self)
            guard try toastState.readPresentationReply(accepted, rejected: rejected, deadline: deadline) else {
                throw CocoaError(.featureUnsupported)
            }
        }
        var session = ExtensionPrototypeSession(id: id, generation: 1, grants: grants) { capability, text in
            switch capability {
            case .preferencesRead:
                guard let preferencePayload, text.isEmpty else { throw CocoaError(.featureUnsupported) }
                return preferencePayload
            case .viewInput:
                guard let viewPayload, text.isEmpty else { throw CocoaError(.featureUnsupported) }
                return viewPayload
            case .commandMetadata:
                guard let commandMetadata, text.utf8.count <= 4_096,
                      let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      Set(object.keys) == ["subtitle"], let subtitle = object["subtitle"],
                      subtitle is NSNull || subtitle is String else { throw CocoaError(.featureUnsupported) }
                try commandMetadata.update(subtitle: subtitle as? String)
                try FileHandle.standardOutput.write(contentsOf: Data((ReviewedRaycastCommandMetadata.changeLine + "\n").utf8))
                return ""
            case .cacheCommit:
                let data = Data(text.utf8)
                guard cacheUpdate == nil, pendingCache.isEmpty, data.count <= ExtensionCacheTransport.inlineBytes
                else { throw CocoaError(.featureUnsupported) }
                _ = try ExtensionCacheTransport.entries(data)
                cacheUpdate = data
                return ""
            case .cacheReadChunk:
                guard let cacheInput, Int(text) == readOffset, readOffset < cacheInput.count
                else { throw CocoaError(.featureUnsupported) }
                let end = min(readOffset + ExtensionCacheTransport.chunkBytes, cacheInput.count)
                let chunk = cacheInput[readOffset..<end].base64EncodedString()
                readOffset = end
                return chunk
            case .cacheWriteChunk:
                guard viewResult == nil, cacheUpdate == nil else { throw CocoaError(.featureUnsupported) }
                if text.isEmpty {
                    _ = try ExtensionCacheTransport.entries(pendingCache)
                    cacheUpdate = pendingCache
                    pendingCache = Data()
                } else {
                    guard text.utf8.count <= (ExtensionCacheTransport.chunkBytes + 2) / 3 * 4,
                          let chunk = Data(base64Encoded: text), !chunk.isEmpty,
                          chunk.count <= ExtensionCacheTransport.chunkBytes,
                          pendingCache.count + chunk.count <= ExtensionCacheTransport.maximumSnapshotBytes
                    else { throw CocoaError(.featureUnsupported) }
                    pendingCache.append(chunk)
                }
                return ""
            case .localStorage:
                guard let localStorage else { throw CocoaError(.featureUnsupported) }
                return try localStorage.reply(to: text)
            case .clipboardRead:
                guard let clipboardReader else { throw CocoaError(.featureUnsupported) }
                let parts = text.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 2 {
                    guard framedToast || interactiveSuite, ["text", "content"].contains(parts[0]),
                          parts[1].utf8.count == 1, let offset = Int(parts[1]), (1...5).contains(offset)
                    else { throw CocoaError(.featureUnsupported) }
                    try clipboardReader.claimRequest()
                    let event = ExtensionClipboardHistoryReadEvent(id: UUID(), offset: offset, includesRichContent: parts[0] == "content")
                    try FileHandle.standardOutput.write(contentsOf: Data(ExtensionClipboardHistoryReadEvent.prefix.utf8) +
                        (try JSONEncoder().encode(event)) + Data([10]))
                    do {
                        let result = try toastState.readConfirmationReply(budget: executionBudget, waitEnded: alertWaitEnded,
                            maximumLineBytes: ExtensionClipboardHistoryReadEvent.maximumReplyLineBytes, decode: event.decodeReply)
                        guard result != "rejected", clipboardReader.isCurrent else { throw CocoaError(.featureUnsupported) }
                        return clipboardReader.transfer(result)
                    } catch {
                        try? FileHandle.standardOutput.write(contentsOf: Data((ExtensionAlertEvent.expiredPrefix + event.id.uuidString + "\n").utf8))
                        throw error
                    }
                }
                return try clipboardReader.reply(to: text)
            case .clipboardReadChunk:
                guard let clipboardReader else { throw CocoaError(.featureUnsupported) }
                return try clipboardReader.chunk(text)
            case .windowRead:
                guard let windowReader else { throw CocoaError(.featureUnsupported) }
                return try windowReader.reply(to: text)
            case .applicationsQuery, .applicationListPage:
                guard let applicationQueries else { throw CocoaError(.featureUnsupported) }
                return try applicationQueries.reply(to: text, continuation: capability == .applicationListPage)
            case .reportException:
                guard exceptionCount < ExtensionExceptionCategory.maximumReports, text.utf8.count <= 9,
                      let category = ExtensionExceptionCategory(rawValue: text),
                      applicationQueries?.hasSignedParent() == true else { throw CocoaError(.featureUnsupported) }
                exceptionCount += 1
                try FileHandle.standardOutput.write(contentsOf: Data((ExtensionExceptionCategory.outputPrefix + category.rawValue + "\n").utf8))
                return ""
            case .viewMemorySample:
                let data = Data(text.utf8)
                guard viewResult == nil, memorySampleCount < ExtensionMemorySample.maximumCount, data.count <= 1024,
                      let sample = try? JSONDecoder().decode(ExtensionMemorySample.self, from: data),
                      sample.isValid else { throw CocoaError(.featureUnsupported) }
                memorySampleCount += 1
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionMemorySample.prefix.utf8) +
                    (try JSONEncoder().encode(sample)) + Data([10]))
                return ""
            case .viewProgress:
                let data = Data(text.utf8)
                guard viewResult == nil, publishedProgress < 4, data.count <= 10_240,
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = payload["kind"] as? String, ["detail", "view", "grid"].contains(kind) else {
                    throw CocoaError(.featureUnsupported)
                }
                publishedProgress += 1
                try FileHandle.standardOutput.write(contentsOf: Data(("guest-progress=" + data.base64EncodedString() + "\n").utf8))
                return ""
            case .viewReadIDs:
                guard let input = viewIDInput, text == String(viewIDOffset), viewIDOffset < input.count else {
                    throw CocoaError(.featureUnsupported)
                }
                let end = min(viewIDOffset + ExtensionViewIDTransport.chunkBytes, input.count)
                let reply = input[viewIDOffset..<end].base64EncodedString()
                viewIDOffset = end
                return reply
            case .viewReadPreferences:
                guard viewResult == nil, let input = viewPreferencesInput,
                      text == String(viewPreferencesOffset), viewPreferencesOffset < input.count else {
                    throw CocoaError(.featureUnsupported)
                }
                let end = min(viewPreferencesOffset + ExtensionViewPreferencesTransport.chunkBytes, input.count)
                let reply = input[viewPreferencesOffset..<end].base64EncodedString()
                viewPreferencesOffset = end
                return reply
            case .viewWriteIDs:
                guard viewResult == nil, viewIDUpdate == nil,
                      text.utf8.count <= ExtensionViewIDTransport.maximumSnapshotBytes else { throw CocoaError(.featureUnsupported) }
                let entries = try JSONSerialization.jsonObject(with: Data(text.utf8))
                _ = try ExtensionViewIDTransport.validateSnapshot(entries)
                viewIDUpdate = entries
                return ""
            case .viewResult:
                let data = Data(text.utf8)
                guard viewInput != nil, viewResult == nil, data.count <= 10_240,
                      var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw CocoaError(.featureUnsupported)
                }
                if sensitiveFormSubmission {
                    guard let kind = object["kind"] as? String, ["action", "error", "formRejected"].contains(kind) else {
                        throw CocoaError(.featureUnsupported)
                    }
                    viewResult = try JSONSerialization.data(withJSONObject: ["kind": kind]).base64EncodedString()
                } else if let viewIDUpdate {
                    guard object["viewIDs"] == nil, object["kind"] as? String != "error" else {
                        throw CocoaError(.featureUnsupported)
                    }
                    object["viewIDs"] = viewIDUpdate
                    let combined = try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)
                    guard combined.count <= ExtensionViewIDTransport.maximumResultBytes else { throw CocoaError(.featureUnsupported) }
                    viewResult = combined.base64EncodedString()
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
                    if capability == .clipboardCopy && interactiveNoView {
                        guard expected == "copy:\(text)" else { throw CocoaError(.fileWriteInvalidFileName) }
                        try writeClipboard(.init(content: ExtensionClipboardContent(text: text), concealed: false),
                                           deadline: executionBudget.replyDeadline)
                    }
                    requestedClipboardText = text
                    return ""
                }
                guard capability == .clipboardCopy, let pasteboard else { throw CocoaError(.featureUnsupported) }
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string),
                      pasteboard.string(forType: .string) == text else { throw CocoaError(.fileWriteUnknown) }
            case .toastAction:
                guard viewResult == nil else { throw CocoaError(.featureUnsupported) }
                let polling = text.hasSuffix(":poll")
                let token = polling ? String(text.dropLast(5)) : text
                return try toastState.readAction(token: token, polling: polling, deadline: executionBudget.replyDeadline)
            case .toast:
                try toastState.accept(text, allowsInteraction: allowsToastAction)
                if application || liveViewToast || liveMenuToast {
                    FileHandle.standardOutput.write(Data("guest-toast=".utf8) + Data(text.utf8) + Data([10]))
                }
            case .openPreferences:
                guard let target = ExtensionPreferencesEvent.Target(rawValue: text) else { throw CocoaError(.featureUnsupported) }
                let event = ExtensionPreferencesEvent(id: UUID(), target: target)
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionPreferencesEvent.prefix.utf8) + (try JSONEncoder().encode(event)) + Data([10]))
                let accepted = String(decoding: event.replyFrame(opened: true).dropLast(), as: UTF8.self)
                let rejected = String(decoding: event.replyFrame(opened: false).dropLast(), as: UTF8.self)
                guard try toastState.readPresentationReply(accepted, rejected: rejected, deadline: executionBudget.replyDeadline) else {
                    throw CocoaError(.featureUnsupported)
                }
                return ""
            case .revealFile:
                guard ExtensionFinderRevealEvent.isValidPath(text) else {
                    throw CocoaError(.featureUnsupported)
                }
                let event = ExtensionFinderRevealEvent(id: UUID(), path: text)
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionFinderRevealEvent.prefix.utf8) +
                    (try JSONEncoder().encode(event)) + Data([10]))
                let accepted = String(decoding: event.replyFrame(revealed: true).dropLast(), as: UTF8.self)
                let rejected = String(decoding: event.replyFrame(revealed: false).dropLast(), as: UTF8.self)
                guard try toastState.readPresentationReply(accepted, rejected: rejected, deadline: executionBudget.replyDeadline) else {
                    throw CocoaError(.featureUnsupported)
                }
                return ""
            case .clipboardWrite:
                let data = Data(text.utf8)
                guard data.count <= 12_288,
                      let request = try? JSONDecoder().decode(ExtensionClipboardWriteEvent.Request.self, from: data),
                      request.content.isValid else { throw CocoaError(.featureUnsupported) }
                if application {
                    guard requestedClipboardText == nil, let value = request.content.text,
                          request.content.html == nil, request.content.file == nil,
                          UUID(uuidString: value) != nil, expected == "copy:\(value)" else {
                        throw CocoaError(.featureUnsupported)
                    }
                }
                try writeClipboard(request, deadline: executionBudget.replyDeadline)
                if application { requestedClipboardText = request.content.text }
                return ""
            case .clipboardClear:
                guard text.isEmpty else { throw CocoaError(.featureUnsupported) }
                let event = ExtensionClipboardClearEvent(id: UUID())
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionClipboardClearEvent.prefix.utf8) +
                    (try JSONEncoder().encode(event)) + Data([10]))
                do {
                    return try toastState.readConfirmationReply(budget: executionBudget, waitEnded: alertWaitEnded) {
                        event.decodeReply($0)?.rawValue
                    }
                } catch {
                    try? FileHandle.standardOutput.write(contentsOf: Data((ExtensionAlertEvent.expiredPrefix + event.id.uuidString + "\n").utf8))
                    throw error
                }
            case .openTarget:
                let data = Data(text.utf8)
                guard data.count <= 8_192,
                      let request = try? JSONDecoder().decode(ExtensionOpenEvent.Request.self, from: data),
                      request.isValid else { throw CocoaError(.featureUnsupported) }
                let event = ExtensionOpenEvent(id: UUID(), request: request)
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionOpenEvent.prefix.utf8) +
                    (try JSONEncoder().encode(event)) + Data([10]))
                do {
                    let choice = try toastState.readConfirmationReply(budget: executionBudget, waitEnded: alertWaitEnded, decode: event.decodeReply)
                    guard choice == "opened" else { throw CocoaError(.featureUnsupported) }
                } catch {
                    try? FileHandle.standardOutput.write(contentsOf: Data((ExtensionAlertEvent.expiredPrefix + event.id.uuidString + "\n").utf8))
                    throw error
                }
                return ""
            case .trashFiles:
                let data = Data(text.utf8)
                guard data.count <= 8_256,
                      let paths = try? JSONDecoder().decode([String].self, from: data) else {
                    throw CocoaError(.featureUnsupported)
                }
                let event = ExtensionTrashEvent(id: UUID(), paths: paths)
                guard event.isValid else { throw CocoaError(.featureUnsupported) }
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionTrashEvent.prefix.utf8) +
                    (try JSONEncoder().encode(event)) + Data([10]))
                do {
                    return try toastState.readConfirmationReply(budget: executionBudget, waitEnded: alertWaitEnded) {
                        event.decodeReply($0)?.rawValue
                    }
                } catch {
                    try? FileHandle.standardOutput.write(contentsOf: Data((ExtensionTrashEvent.expiredPrefix + event.id.uuidString + "\n").utf8))
                    throw error
                }
            case .confirmAlert:
                let data = Data(text.utf8)
                guard data.count <= 12_288,
                      let request = try? JSONDecoder().decode(ExtensionAlertRequest.self, from: data),
                      request.isValid else { throw CocoaError(.featureUnsupported) }
                let event = ExtensionAlertEvent(id: UUID(), request: request)
                FileHandle.standardOutput.write(Data(ExtensionAlertEvent.requestPrefix.utf8) + (try JSONEncoder().encode(event)) + Data([10]))
                do {
                    let choice = try toastState.readConfirmationReply(budget: executionBudget, waitEnded: alertWaitEnded) {
                        event.decodeReply($0)?.rawValue
                    }
                    guard choice != ExtensionAlertEvent.Reply.unavailable.rawValue else { throw CocoaError(.featureUnsupported) }
                    return choice
                } catch {
                    FileHandle.standardOutput.write(Data((ExtensionAlertEvent.expiredPrefix + event.id.uuidString + "\n").utf8))
                    throw error
                }
            case .clearSearch:
                let data = Data(text.utf8)
                guard data.count <= 128, viewResult == nil,
                      let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(fields.keys) == ["forceScrollToTop"] else { throw CocoaError(.featureUnsupported) }
                let request = try JSONDecoder().decode(ExtensionClearSearchRequest.self, from: data)
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionClearSearchRequest.prefix.utf8) +
                    (try JSONEncoder().encode(request)) + Data([10]))
                guard try toastState.readPresentationReply(ExtensionClearSearchRequest.accepted,
                                                          rejected: ExtensionClearSearchRequest.rejected,
                                                          deadline: executionBudget.replyDeadline) else {
                    throw CocoaError(.featureUnsupported)
                }
                return ""
            case .popToRoot:
                let data = Data(text.utf8)
                guard data.count <= 128, viewResult == nil,
                      let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(fields.keys) == ["clearSearchBar"] else { throw CocoaError(.featureUnsupported) }
                let request = try JSONDecoder().decode(ExtensionPopToRootRequest.self, from: data)
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionPopToRootRequest.prefix.utf8) +
                    (try JSONEncoder().encode(request)) + Data([10]))
                guard try toastState.readPresentationReply(ExtensionPopToRootRequest.accepted,
                                                          rejected: ExtensionPopToRootRequest.rejected,
                                                          deadline: executionBudget.replyDeadline) else {
                    throw CocoaError(.featureUnsupported)
                }
                return ""
            case .closeWindow:
                let data = Data(text.utf8)
                guard data.count <= 128, viewResult == nil,
                      let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(fields.keys) == ["clearRootSearch", "popToRootType"] else {
                    throw CocoaError(.featureUnsupported)
                }
                let request = try JSONDecoder().decode(ExtensionCloseWindowRequest.self, from: data)
                try FileHandle.standardOutput.write(contentsOf: Data(ExtensionCloseWindowRequest.prefix.utf8) +
                    (try JSONEncoder().encode(request)) + Data([10]))
                guard try toastState.readPresentationReply(ExtensionCloseWindowRequest.accepted,
                                                          rejected: ExtensionCloseWindowRequest.rejected,
                                                          deadline: executionBudget.replyDeadline) else {
                    throw CocoaError(.featureUnsupported)
                }
                return ""
            case .hud:
                let hud = try JSONDecoder().decode(ExtensionHUDRequest.self, from: Data(text.utf8))
                if liveViewClose || liveMenuToast || initialViewWindow || interactiveSuite || liveCatalogNavigation {
                    guard viewResult == nil else { throw CocoaError(.featureUnsupported) }
                    try FileHandle.standardOutput.write(contentsOf: Data(ExtensionHUDRequest.prefix.utf8) +
                        (try JSONEncoder().encode(hud)) + Data([10]))
                    guard try toastState.readPresentationReply(ExtensionHUDRequest.accepted,
                                                               rejected: ExtensionHUDRequest.rejected,
                                                               deadline: executionBudget.replyDeadline) else {
                        throw CocoaError(.featureUnsupported)
                    }
                    return ""
                }
                if application {
                    if acknowledgesHUD {
                        guard let requestedClipboardText, !requestedPresentation,
                              expected == "\(paste ? "paste" : "copy"):\(requestedClipboardText)" else {
                            throw CocoaError(.featureUnsupported)
                        }
                        requestedPresentation = true
                    }
                    FileHandle.standardOutput.write(Data(ExtensionHUDRequest.prefix.utf8) + (try JSONEncoder().encode(hud)) + Data([10]))
                    if acknowledgesHUD {
                        let presented = try framedToast
                            ? toastState.readPresentationReply(ExtensionHUDRequest.accepted, rejected: ExtensionHUDRequest.rejected, deadline: executionBudget.replyDeadline)
                            : FileHandle.standardInput.read(upToCount: 2) == Data([1])
                        guard presented else {
                            throw CocoaError(.featureUnsupported)
                        }
                        acknowledgedPresentation = true
                    }
                    return ""
                }
            }
            let event = try JSONSerialization.data(withJSONObject: ["capability": capability.rawValue, "text": text])
            FileHandle.standardError.write(Data("broker-event ".utf8) + event + Data([10]))
            return ""
        }
        var replies: [ExtensionPrototypeSession.Reply] = []
        var rawReceived = 0
        var received = (ordinary: 0, storage: 0, cache: 0, clipboard: 0, viewIDs: 0, preferences: 0, applicationPages: 0)
        var sent = (ordinary: 0, storage: 0, cache: 0, clipboard: 0, viewIDs: 0, preferences: 0, applicationPages: 0)
        var capability: ExtensionPrototypeSession.Capability?
        let byteLimit = 64 * 1024
        let storageLimit = localStorage == nil ? 0 : 288 * 1024
        let cacheLimit = grants.contains(.cacheWriteChunk) ? ExtensionCacheTransport.maximumTrafficBytes : 0
        let clipboardLimit = clipboardReader == nil ? 0 : ExtensionClipboardReadTransport.maximumTrafficBytes
        let viewIDLimit = grants.contains(.viewReadIDs) || grants.contains(.viewWriteIDs) ? 52 * 1024 : 0
        let preferencesLimit = viewPreferencesInput == nil ? 0 : 24 * 1024
        let applicationListLimit = applicationQueries == nil ? 0 : ExtensionApplicationListTransport.maximumTrafficBytes
        let rawLimit = byteLimit + storageLimit + cacheLimit + clipboardLimit + viewIDLimit + preferencesLimit + applicationListLimit
        func charge(_ bytes: Int, to counter: inout (ordinary: Int, storage: Int, cache: Int, clipboard: Int, viewIDs: Int, preferences: Int, applicationPages: Int)) throws {
            switch capability {
            case .localStorage: counter.storage += bytes
            case .cacheReadChunk, .cacheWriteChunk: counter.cache += bytes
            case .clipboardRead, .clipboardReadChunk: counter.clipboard += bytes
            case .viewReadIDs, .viewWriteIDs: counter.viewIDs += bytes
            case .viewReadPreferences: counter.preferences += bytes
            case .applicationListPage: counter.applicationPages += bytes
            default: counter.ordinary += bytes
            }
            guard counter.ordinary <= byteLimit, counter.storage <= storageLimit, counter.cache <= cacheLimit,
                  counter.clipboard <= clipboardLimit, counter.viewIDs <= viewIDLimit,
                  counter.preferences <= preferencesLimit, counter.applicationPages <= applicationListLimit else {
                throw ExtensionPrototypeSession.Rejection.limit
            }
        }
        do {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                rawReceived += count
                guard rawReceived <= rawLimit else { throw ExtensionPrototypeSession.Rejection.limit }
                let chunk = Data(buffer.prefix(count))
                try session.receiveBytes(chunk, charge: { count, requestCapability in
                    capability = requestCapability
                    try charge(count, to: &received)
                }) { reply in
                    replies.append(reply)
                    let data = try ExtensionPrototypeSession.encode(reply, session: id, generation: 1)
                    try charge(data.count, to: &sent)
                    try io.write(contentsOf: data)
                }
            }
            try session.finishInput()
            guard pendingCache.isEmpty else { return nil }
            if viewInput != nil, case .result(_, "")? = replies.last { return viewResult.map { ($0, cacheUpdate) } }
            if noView, !requestedPresentation || acknowledgedPresentation,
               case .result(_, "node-confirmed")? = replies.last {
                return application
                    ? requestedClipboardText.map { ("\(paste ? "paste" : "copy"):\($0)", cacheUpdate) }
                    : ("node-confirmed", nil)
            }
            guard replies.count == 3, replies[0] == .ready(version: 1),
                  replies[1] == .denied(requestID: 1),
                  case .result(requestID: 2, text: let result) = replies[2] else { return nil }
            return (result, nil)
        } catch {
            if rawReceived > rawLimit || received.ordinary > byteLimit || sent.ordinary > byteLimit ||
                received.storage > storageLimit || sent.storage > storageLimit ||
                received.cache > cacheLimit || sent.cache > cacheLimit ||
                received.clipboard > clipboardLimit || sent.clipboard > clipboardLimit ||
                received.viewIDs > viewIDLimit || sent.viewIDs > viewIDLimit ||
                received.preferences > preferencesLimit || sent.preferences > preferencesLimit ||
                received.applicationPages > applicationListLimit || sent.applicationPages > applicationListLimit {
                FileHandle.standardError.write(Data("guest protocol output limit\n".utf8))
            }
            let message = sensitiveFormSubmission ? "guest protocol rejected the sensitive request" : "guest protocol: \(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            return nil
        }
    }

    func checkDeadline() {
        deadlineCheck?.cancel()
        guard !stopped else { return }
        let remaining = ContinuousClock.now.duration(to: executionBudget.watchdogDeadline)
        if remaining > .zero {
            let time = remaining.components
            let seconds = Double(time.seconds) + Double(time.attoseconds) / 1e18
            let check = DispatchWorkItem { [weak self] in self?.checkDeadline() }
            deadlineCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: check)
            return
        }
        FileHandle.standardError.write(Data("guest deadline expired\n".utf8))
        finish(success: false)
    }

    func finish(success: Bool) {
        guard !stopped, let vm else { return }
        stopped = true
        deadlineCheck?.cancel()
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
    private static func metadataTarget(phase: String, kernelPath: String, imagePath: String,
                                       input: [String: Any]) -> ReviewedRaycastCommandMetadata? {
        guard let environment = input["environment"] as? [String: Any],
              let slug = environment["extensionName"] as? String,
              let command = environment["entryPointName"] as? String,
              let app = ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: kernelPath, imagePath: imagePath),
              ApplicationQueries.hasReviewedSignature(app),
              let path = ProcessInfo.processInfo.environment["KEYLANE_REVIEWED_LOCAL_STORAGE"],
              path.hasPrefix("/"), path.utf8.count <= 4_096 else { return nil }
        let storage = URL(fileURLWithPath: path).standardizedFileURL
        let installed = storage.deletingLastPathComponent()
        guard storage.lastPathComponent == "local-storage.json", installed.lastPathComponent == slug,
              installed.deletingLastPathComponent().lastPathComponent == "Extensions" else { return nil }
        return ReviewedRaycastCommandMetadata(installationDirectory: installed, command: command)
    }

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
        let acknowledgesHUD = phase == "noview-app" && ProcessInfo.processInfo.environment["KEYLANE_ACKNOWLEDGE_HUD"] == "1"
        let framedToast = (phase == "view-app" || acknowledgesHUD)
            && ProcessInfo.processInfo.environment["KEYLANE_INTERACTIVE_TOAST"] == "1"
        let framedPreferences = phase == "uuid-storage-app" &&
            ProcessInfo.processInfo.environment["KEYLANE_SETTINGS_INTERACTION"] == "1"
        let readsFrames = acknowledgesHUD || framedToast || framedPreferences
        var interactiveToast = false
        var paste = false
        var sensitiveFormSubmission = false
        var clipboardReader: ClipboardContentReader?
        var windowReader: WindowSnapshotReader?
        var localStorage: GuestLocalStorage?
        var commandMetadata: ReviewedRaycastCommandMetadata?
        var applicationQueryFiles: [String] = []
        if ["view-app", "noview-app", "uuid-storage-app"].contains(phase) {
            let limit = ExtensionCacheTransport.maximumInputBytes + (phase == "view-app" ? ExtensionViewIDTransport.maximumRequestBytes + ExtensionViewPreferencesTransport.maximumBytes : 0)
            var bytes = Data()
            let stdin = FileHandle.standardInput
            while let chunk = try stdin.read(upToCount: readsFrames ? 1 : limit + 1 - bytes.count), !chunk.isEmpty {
                if readsFrames, chunk == Data([10]) { break }
                bytes.append(chunk)
                guard bytes.count <= limit else { exit(2) }
            }
            guard let input = String(data: bytes, encoding: .utf8),
                  var object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { exit(2) }
            guard object["viewEntryPoint"] == nil, object["catalogNoView"] == nil else { exit(2) }
            let imageName = URL(fileURLWithPath: args[2]).lastPathComponent
            var viewEntryPoint: String?
            var noViewBundle: URL?
            if phase == "view-app", imageName != "view.cpio", imageName != "menu-bar.cpio" {
                guard object["mode"] == nil,
                      let app = ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: args[1], imagePath: args[2]),
                      ApplicationQueries.hasReviewedSignature(app),
                      let environment = object["environment"] as? [String: Any],
                      let name = environment["entryPointName"] as? String,
                      let artifact = ReviewedViewArtifact.loadCatalog(in: app.appendingPathComponent("Contents/Resources/ReviewedRaycast")).first(where: {
                          $0.artifactName + ".cpio" == imageName && $0.slug == environment["extensionName"] as? String &&
                              $0.owner == environment["ownerOrAuthorName"] as? String
                      }), let entry = artifact.entryPoints.first(where: { $0.name == name }),
                      environment["entryPointMode"] as? String == entry.entryMode.rawValue else { exit(2) }
                if artifact.usesNamedEntryPoints { viewEntryPoint = name }
                if entry.entryMode == .noView {
                    let fields: Set<String> = ["query", "environment", "clipboardReadChangeCount", "cache", "applicationQueryPreferenceFields"]
                    guard environment["launchType"] as? String == "userInitiated",
                          object["query"] as? String == "",
                          Set(object.keys).isSubset(of: fields.union(ExtensionViewPreferencesTransport.keys)) else { exit(2) }
                    noViewBundle = app
                }
            }
            sensitiveFormSubmission = object["sensitiveFormSubmission"] as? Bool == true
            let suppliedMetadataGrant = object.removeValue(forKey: "commandMetadataAllowed")
            let selectedPreferenceFields = object.removeValue(forKey: "applicationQueryPreferenceFields")
            let selectedFormFields = object.removeValue(forKey: "applicationQueryFormFields")
            let selectedFormEvents = object.removeValue(forKey: "applicationQueryFormEvents")
            if object["sensitiveFormSubmission"] as? Bool != true {
                commandMetadata = metadataTarget(phase: phase, kernelPath: args[1], imagePath: args[2], input: object)
            }
            if phase != "noview-app" {
                if phase == "view-app", ReviewedViewArtifact.isViewImage(URL(fileURLWithPath: args[2]).lastPathComponent),
                   !sensitiveFormSubmission, object["mode"] == nil,
                   selectedPreferenceFields != nil || selectedFormFields != nil || selectedFormEvents != nil,
                   ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: args[1], imagePath: args[2])
                       .map(ApplicationQueries.hasReviewedSignature) == true {
                    if let names = selectedPreferenceFields as? [String],
                       let values = object["preferences"] as? [String: Any],
                       let definitions = object["preferenceDefinitions"] as? [[String: Any]],
                       let paths = ApplicationQueries.selectedPreferencePaths(names, values: values, definitions: definitions) {
                        applicationQueryFiles = paths
                        object["applicationQueryPreferenceFields"] = names
                    }
                    let submitting = object["action"] is [String: Any] && object["formValues"] is [String: Any]
                    if submitting, let fieldIDs = selectedFormFields as? [String],
                       let values = object["formValues"] as? [String: Any],
                       let paths = ApplicationQueries.selectedPaths(fieldIDs.map { values[$0] }, uniqueIDs: fieldIDs) {
                        applicationQueryFiles += paths
                        object["applicationQueryFormFields"] = fieldIDs
                    }
                    let changing = object["formRefresh"] as? Bool == true && object["action"] == nil
                    if submitting || changing, let events = object["formEvents"] as? [[String: Any]], events.count <= 16,
                       let indexes = selectedFormEvents as? [Any] {
                        let ordered = indexes.compactMap(ReviewedViewReadAccess.integer)
                        if ordered.count == indexes.count,
                           ordered.allSatisfy({ events.indices.contains($0) && events[$0]["kind"] as? String == "change" }),
                           let paths = ApplicationQueries.selectedPaths(ordered.map { events[$0]["value"] }, uniqueIDs: ordered) {
                            applicationQueryFiles += paths
                            object["applicationQueryFormEvents"] = ordered
                        }
                    }
                }
                let suppliedToastGrant = object.removeValue(forKey: "interactiveToast")
                let suppliedCloseGrant = object.removeValue(forKey: "navigationCloseAllowed")
                let suppliedMenuAlertGrant = object.removeValue(forKey: "menuAlertAllowed")
                let suppliedSuiteGrant = object.removeValue(forKey: "suitePreferencesAllowed")
                let suppliedFinderGrant = object.removeValue(forKey: "finderRevealAllowed")
                let suppliedOpenGrant = object.removeValue(forKey: "openTargetAllowed")
                let requestsOpen = phase == "view-app" && object["liveOpen"] as? Bool == true &&
                    ReviewedViewArtifact.isViewImage(URL(fileURLWithPath: args[2]).lastPathComponent) &&
                    object["action"] is [String: Any] && object["fileReceipt"] == nil
                let clipboardMarker = object.removeValue(forKey: "clipboardReadChangeCount")
                let suppliedClipboardGrant = object.removeValue(forKey: "clipboardReadAllowed")
                let suppliedInitialPreferencesGrant = object.removeValue(forKey: "initialPreferencesAllowed")
                let initialPreferencesRequested = object.removeValue(forKey: "initialPreferences") as? Bool == true
                let suppliedSearchClearGrant = object.removeValue(forKey: "searchClearAllowed")
                let searchChangeRequested = object.removeValue(forKey: "liveSearchChange") as? Bool == true
                let preferenceFields = ExtensionViewPreferencesTransport.keys
                let initialViewFields: Set<String> = Set(["query", "dropdownValue", "dropdownPreferences", "cache", "environment",
                                                      "mountNavigation", "progressUpdates"]).union(preferenceFields)
                let searchViewFields = initialViewFields.union(["viewRoute", "viewIDs", "selectedItemId"])
                let requestsSearchClear = phase == "view-app" && searchChangeRequested &&
                    ReviewedViewArtifact.isViewImage(URL(fileURLWithPath: args[2]).lastPathComponent) &&
                    (object["query"] as? String).map { $0.utf8.count <= 256 } == true &&
                    Set(object.keys).isSubset(of: searchViewFields)
                let requestsInitialPreferences = phase == "view-app" && initialPreferencesRequested &&
                    ReviewedViewArtifact.isViewImage(URL(fileURLWithPath: args[2]).lastPathComponent) &&
                    object["query"] as? String == "" && Set(object.keys).isSubset(of: initialViewFields)
                let suiteMode = object["mode"] as? String
                let interactiveSuite = suiteMode == "history" ? object["action"] is [String: Any]
                    : ["generate", "generateV5", "generateV7", "generateUlid", "generateTypeID", "parseTypeID", "packTypeID"].contains(suiteMode ?? "")
                let suiteBundle = (framedPreferences && interactiveSuite && !sensitiveFormSubmission)
                    ? ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: args[1], imagePath: args[2])
                    : nil
                let signedSuiteBundle = suiteBundle.flatMap { ApplicationQueries.hasReviewedSignature($0) ? $0 : nil }
                let allowsSuitePreferences = signedSuiteBundle != nil
                let requestsToast = object["liveToast"] as? Bool == true
                let suppliedFormToast = object.removeValue(forKey: "liveFormToast")
                let formAction = object["action"] as? [String: Any]
                let requestsFormToast = phase == "view-app" && suppliedFormToast as? Bool == true &&
                    ReviewedViewArtifact.isViewImage(URL(fileURLWithPath: args[2]).lastPathComponent) &&
                    object["formValues"] is [String: Any] && formAction.map { Set($0.keys) == ["row", "id"] } == true &&
                    ReviewedViewReadAccess.integer(formAction?["row"]) == 0 &&
                    ReviewedViewReadAccess.integer(formAction?["id"]).map { (0..<12).contains($0) } == true
                let requestsClose = phase == "view-app" && object["liveNavigation"] as? Bool == true &&
                    object["action"] is [String: Any] && object["fileReceipt"] == nil
                let requestsMenuAlert = phase == "view-app" && URL(fileURLWithPath: args[2]).lastPathComponent == "menu-bar.cpio" &&
                    object["mode"] as? String == "menuBar" && object["action"] == nil &&
                    (object["menuAction"] as? Int).map { (0..<64).contains($0) } == true
                let interactiveBundle = framedToast && !sensitiveFormSubmission &&
                    (requestsToast || requestsFormToast || requestsClose || requestsMenuAlert || requestsInitialPreferences || requestsOpen || requestsSearchClear)
                    ? ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: args[1], imagePath: args[2])
                    : nil
                let signedInteractiveBundle = interactiveBundle.flatMap { ApplicationQueries.hasReviewedSignature($0) ? $0 : nil }
                let signedInteractiveParent = signedInteractiveBundle != nil
                let environment = object["environment"] as? [String: Any]
                let menuUserInitiated = environment?["entryPointMode"] as? String == "menu-bar" &&
                    environment?["launchType"] as? String == "userInitiated"
                interactiveToast = signedInteractiveParent && (requestsToast || requestsFormToast || (requestsMenuAlert && menuUserInitiated))
                if signedInteractiveParent && requestsFormToast { object["liveFormToast"] = true }
                let allowsClose = signedInteractiveParent && requestsClose
                let allowsViewFinderReveal = allowsClose && requestsToast &&
                    ReviewedViewArtifact.isViewImage(URL(fileURLWithPath: args[2]).lastPathComponent) &&
                    ["formValues", "copyReceipt", "openReceipt", "dateReceipt"].allSatisfy { object[$0] == nil }
                let allowsMenuAlert = signedInteractiveParent && requestsMenuAlert
                let allowsFinderReveal = allowsViewFinderReveal || allowsMenuAlert || allowsSuitePreferences
                let allowsOpen = signedInteractiveParent && requestsOpen || allowsMenuAlert || allowsSuitePreferences
                let allowsInitialPreferences = signedInteractiveParent && requestsInitialPreferences
                let allowsSearchClear = signedInteractiveParent && requestsSearchClear
                if phase == "view-app" {
                    var base = object
                    if let cache = base.removeValue(forKey: "cache") {
                        guard !sensitiveFormSubmission,
                              let data = try? JSONSerialization.data(withJSONObject: cache, options: .withoutEscapingSlashes),
                              data.count <= ExtensionCacheTransport.maximumSnapshotBytes else { exit(2) }
                        if let entries = cache as? [[String]] {
                            guard entries.count <= 64, entries.allSatisfy({ $0.count == 2 }) else { exit(2) }
                        } else {
                            guard let entries = cache as? [String: String], entries.count <= 64,
                                  data.count <= ExtensionCacheTransport.maximumSnapshotBytes else { exit(2) }
                        }
                    }
                    _ = try ExtensionViewIDTransport.splitRequest(&base)
                    _ = try ExtensionViewPreferencesTransport.snapshot(in: base)
                    for key in preferenceFields { base.removeValue(forKey: key) }
                    let baseLimit = base["viewRoute"] == nil && base["poppedFrame"] == nil ? 2_048 : 4_096
                    guard let data = try? JSONSerialization.data(withJSONObject: base, options: .withoutEscapingSlashes),
                          data.count <= baseLimit else { exit(2) }
                }
                let windowMarker = object.removeValue(forKey: "windowReadTargetPID")
                let suppliedWindowGrant = object.removeValue(forKey: "windowReadAllowed")
                let suppliedStorageGrant = object.removeValue(forKey: "localStorageAllowed")
                if !sensitiveFormSubmission, phase == "view-app", object["storage"] == nil {
                    localStorage = GuestLocalStorage.make(phase: phase, kernelPath: args[1], imagePath: args[2])
                }
                if !sensitiveFormSubmission, clipboardMarker != nil || windowMarker != nil,
                   let app = ReviewedViewReadAccess.bundle(
                       phase: phase, kernelPath: args[1], imagePath: args[2], request: object
                   ) {
                    clipboardReader = clipboardMarker.flatMap { ClipboardContentReader.make(app: app, marker: $0) }
                    windowReader = windowMarker.flatMap { WindowSnapshotReader.make(marker: $0) }
                }
                if allowsInitialPreferences, let app = signedInteractiveBundle, let clipboardMarker,
                   object["mountNavigation"] as? Bool == true,
                   let environment = object["environment"] as? [String: Any],
                   environment["entryPointMode"] as? String == "view",
                   environment["launchType"] as? String == "userInitiated" {
                    clipboardReader = ClipboardContentReader.make(app: app, marker: clipboardMarker)
                }
                if allowsMenuAlert, let clipboardMarker,
                   let environment = object["environment"] as? [String: Any],
                   environment["entryPointMode"] as? String == "menu-bar",
                   environment["launchType"] as? String == "userInitiated",
                   let app = ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: args[1], imagePath: args[2]) {
                    clipboardReader = ClipboardContentReader.make(app: app, marker: clipboardMarker)
                }
                if let app = signedSuiteBundle, let clipboardMarker,
                   let environment = object["environment"] as? [String: Any],
                   environment["entryPointMode"] as? String == (suiteMode == "history" ? "view" : "no-view"),
                   environment["launchType"] as? String == "userInitiated",
                   suiteMode == "history" || object["action"] == nil {
                    clipboardReader = ClipboardContentReader.make(app: app, marker: clipboardMarker)
                }
                if let noViewBundle, let clipboardMarker {
                    clipboardReader = ClipboardContentReader.make(app: noViewBundle, marker: clipboardMarker)
                }
                if clipboardReader != nil { object["clipboardReadAllowed"] = true }
                if windowReader != nil { object["windowReadAllowed"] = true }
                if localStorage != nil { object["localStorageAllowed"] = true }
                if selectedPreferenceFields != nil || selectedFormFields != nil || selectedFormEvents != nil || clipboardMarker != nil || windowMarker != nil || suppliedClipboardGrant != nil || suppliedWindowGrant != nil ||
                    localStorage != nil || suppliedStorageGrant != nil || interactiveToast || suppliedToastGrant != nil || suppliedFormToast != nil ||
                    allowsClose || suppliedCloseGrant != nil || allowsMenuAlert || suppliedMenuAlertGrant != nil ||
                    commandMetadata != nil || suppliedMetadataGrant != nil || allowsSuitePreferences || suppliedSuiteGrant != nil ||
                    initialPreferencesRequested || suppliedInitialPreferencesGrant != nil ||
                    searchChangeRequested || suppliedSearchClearGrant != nil ||
                    allowsFinderReveal || suppliedFinderGrant != nil || allowsOpen || suppliedOpenGrant != nil || viewEntryPoint != nil {
                    if let viewEntryPoint { object["viewEntryPoint"] = viewEntryPoint }
                    if noViewBundle != nil { object["catalogNoView"] = true }
                    if allowsOpen { object["openTargetAllowed"] = true }
                    if allowsFinderReveal { object["finderRevealAllowed"] = true }
                    if allowsInitialPreferences { object["initialPreferencesAllowed"] = true }
                    if allowsSearchClear { object["searchClearAllowed"] = true }
                    if allowsSuitePreferences { object["suitePreferencesAllowed"] = true }
                    if commandMetadata != nil { object["commandMetadataAllowed"] = true }
                    if allowsClose { object["navigationCloseAllowed"] = true }
                    if allowsMenuAlert { object["menuAlertAllowed"] = true }
                    if interactiveToast { object["interactiveToast"] = true }
                    let sanitized = try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)
                    viewInput = String(decoding: sanitized, as: UTF8.self)
                } else {
                    viewInput = input
                }
            } else {
                let suppliedToastGrant = object.removeValue(forKey: "interactiveToast")
                let suppliedCache = object.removeValue(forKey: "cache")
                let clipboardMarker = object.removeValue(forKey: "clipboardReadChangeCount")
                let suppliedClipboardGrant = object.removeValue(forKey: "clipboardReadAllowed")
                let base = try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes)
                guard base.count <= 2_048 else { exit(2) }
                let values = object["preferences"] as? [String: Any] ?? object
                guard let action = values["defaultAction"] as? String, ["copy", "paste"].contains(action) else { exit(2) }
                var cacheAllowed = false
                if framedToast || suppliedCache != nil,
                   let app = ApplicationQueries.reviewedLaunchBundle(phase: phase, kernelPath: args[1], imagePath: args[2]),
                   ApplicationQueries.hasReviewedSignature(app) {
                    interactiveToast = framedToast
                    if framedToast, object["sensitiveFormSubmission"] as? Bool != true,
                       let environment = object["environment"] as? [String: Any],
                       environment["entryPointMode"] as? String == "no-view",
                       environment["launchType"] as? String == "userInitiated",
                       let clipboardMarker {
                        clipboardReader = ClipboardContentReader.make(app: app, marker: clipboardMarker)
                        if clipboardReader != nil { object["clipboardReadAllowed"] = true }
                    }
                    if let suppliedCache {
                        guard let entries = suppliedCache as? [[String]], entries.count <= 64,
                              entries.allSatisfy({ $0.count == 2 }),
                              try JSONSerialization.data(withJSONObject: entries, options: .withoutEscapingSlashes).count <= ExtensionCacheTransport.maximumSnapshotBytes
                        else { exit(2) }
                        cacheAllowed = true
                        object["cache"] = entries
                    }
                }
                let suppliedStorageGrant = object.removeValue(forKey: "localStorageAllowed")
                localStorage = GuestLocalStorage.make(phase: phase, kernelPath: args[1], imagePath: args[2])
                if localStorage != nil { object["localStorageAllowed"] = true }
                if interactiveToast { object["interactiveToast"] = true }
                if localStorage != nil || suppliedStorageGrant != nil || interactiveToast || suppliedToastGrant != nil || suppliedCache != nil ||
                   suppliedMetadataGrant != nil || selectedPreferenceFields != nil || selectedFormFields != nil || selectedFormEvents != nil ||
                   clipboardMarker != nil || suppliedClipboardGrant != nil {
                    if object["preferences"] == nil, interactiveToast || cacheAllowed { object["preferences"] = values }
                    preferences = String(decoding: try JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes), as: UTF8.self)
                } else {
                    preferences = input
                }
                paste = action == "paste"
            }
        }
        let applicationQueries = ApplicationQueries.make(
            phase: phase, kernelPath: args[1], imagePath: args[2], sensitive: sensitiveFormSubmission,
            selectedFiles: applicationQueryFiles
        )
        let probe = GuestProbe(phase: phase, expected: viewInput != nil || (building && args[5] == "-") ? nil : args[5],
                               viewInput: viewInput, preferences: preferences, acknowledgesHUD: acknowledgesHUD, framedToast: framedToast, paste: paste,
                               sensitiveFormSubmission: sensitiveFormSubmission, interactiveToast: interactiveToast, applicationQueries: applicationQueries,
                               clipboardReader: clipboardReader, windowReader: windowReader, localStorage: localStorage, commandMetadata: commandMetadata)
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
        probe.checkDeadline()
        dispatchMain()
    }
}

final class ApplicationQueries {
    private enum Target: Equatable {
        case contentType(UTType)
        case url(URL)
        case namedFile(String)
    }

    private enum ExtensionlessFile: String, Decodable {
        case generic, authors, copying, license, makefile, readme

        var canonicalName: String? {
            switch self {
            case .generic: nil
            case .makefile: "Makefile"
            case .authors, .copying, .license, .readme: rawValue.uppercased()
            }
        }
    }

    private struct Request: Decodable {
        enum Operation: String, Decodable { case list, `default`, frontmost }
        let operation: Operation
        let `extension`: String?
        let directory: Bool?
        let scheme: String?
        let extensionless: ExtensionlessFile?
        let symlink: Bool?
        let selectedFile: Int?
        let offset: Int?

        func target(selectedFiles: [String]) throws -> Target? {
            let selectors = [scheme != nil, directory != nil, `extension` != nil, extensionless != nil, symlink != nil, selectedFile != nil]
            guard selectors.filter({ $0 }).count <= 1 else { throw CocoaError(.featureUnsupported) }
            if let selectedFile {
                guard operation != .frontmost, selectedFiles.indices.contains(selectedFile) else {
                    throw CocoaError(.featureUnsupported)
                }
                return .url(URL(fileURLWithPath: selectedFiles[selectedFile]))
            }
            if let symlink {
                guard symlink, operation == .list else { throw CocoaError(.featureUnsupported) }
                return .contentType(.symbolicLink)
            }
            if let extensionless {
                return extensionless.canonicalName.map(Target.namedFile) ?? .contentType(.data)
            }
            if let scheme {
                guard scheme != "file",
                      scheme.wholeMatch(of: #/[a-z][a-z0-9+.-]{0,31}/#) != nil,
                      let url = URL(string: scheme == "mailto" ? "mailto:recipient@example.invalid" : "\(scheme)://example.invalid")
                else { throw CocoaError(.featureUnsupported) }
                return .url(url)
            }
            if directory != nil {
                guard directory == true else { throw CocoaError(.featureUnsupported) }
                return .contentType(.folder)
            }
            guard let `extension` else { return nil }
            guard `extension`.wholeMatch(of: #/[a-z0-9][a-z0-9_+-]{0,31}/#) != nil,
                  let type = UTType(filenameExtension: `extension`) else { throw CocoaError(.featureUnsupported) }
            return .contentType(type)
        }
    }

    fileprivate typealias Application = RaycastApplicationValue

    private struct ListPage: Encodable {
        let items: [Application]
        let nextOffset: Int?
    }

    private struct ListCursor {
        let target: Target?
        let applications: [Application]
        let offset: Int
    }

    private static let maximumReplyBytes = 6_000
    private let reviewedApp: URL?
    private let selectedFiles: [String]
    private var signatureIsValid: Bool?
    private var queriesLeft = 8
    private var installed: [Application]?
    private var listCursor: ListCursor?

    private init(reviewedApp: URL? = nil, selectedFiles: [String] = []) {
        self.reviewedApp = reviewedApp
        self.selectedFiles = selectedFiles
    }

    static func make(phase: String, kernelPath: String, imagePath: String, sensitive: Bool, selectedFiles: [String]) -> ApplicationQueries? {
        guard !sensitive, ["view-app", "uuid-storage-app", "noview-app"].contains(phase) else { return nil }
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        return ApplicationQueries()
        #else
        guard let app = reviewedLaunchBundle(phase: phase, kernelPath: kernelPath, imagePath: imagePath) else { return nil }
        return ApplicationQueries(reviewedApp: app, selectedFiles: selectedFiles)
        #endif
    }

    fileprivate static func selectedPreferencePaths(
        _ names: [String], values: [String: Any], definitions: [[String: Any]]
    ) -> [String]? {
        guard !names.isEmpty, Set(names).count == names.count else { return nil }
        let paths = names.compactMap { name -> String? in
            guard let definition = definitions.first(where: { $0["name"] as? String == name }),
                  let type = definition["type"] as? String, ["file", "directory"].contains(type),
                  let path = values[name] as? String, ExtensionFinderRevealEvent.isValidPath(path) else { return nil }
            return path
        }
        return paths.count == names.count ? paths : nil
    }

    fileprivate static func selectedPaths<ID: Hashable>(_ values: [Any?], uniqueIDs: [ID]) -> [String]? {
        let selections = values.compactMap { $0 as? [String] }
        guard !uniqueIDs.isEmpty, Set(uniqueIDs).count == uniqueIDs.count, selections.count == uniqueIDs.count,
              selections.allSatisfy({ !$0.isEmpty && $0.count <= 16 && $0.allSatisfy(ExtensionFinderRevealEvent.isValidPath) })
        else { return nil }
        return selections.flatMap { $0 }
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
        case "view-app":
            if ["view.cpio", "menu-bar.cpio"].contains(image.lastPathComponent) {
                approved = ["view.cpio", "menu-bar.cpio"]
            } else {
                approved = ReviewedViewArtifact.loadCatalog(in: assets).map { $0.artifactName + ".cpio" }
            }
        case "uuid-storage-app": approved = ["uuid-suite.cpio"]
        case "noview-app": approved = ["noview.cpio"]
        default: return nil
        }
        guard canonical(kernelPath).path == assets.appendingPathComponent("Image").path,
              image.lastPathComponent == URL(fileURLWithPath: imagePath).lastPathComponent,
              image.deletingLastPathComponent().path == assets.path, approved.contains(image.lastPathComponent)
        else { return nil }
        return app
    }

    private func canQueryApplications() -> Bool {
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        return true
        #else
        return hasSignedParent()
        #endif
    }

    func hasSignedParent() -> Bool {
        if let signatureIsValid { return signatureIsValid }
        guard let reviewedApp else { return false }
        let valid = Self.hasReviewedSignature(reviewedApp)
        signatureIsValid = valid
        return valid
    }

    fileprivate static func hasReviewedSignature(_ app: URL) -> Bool {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckNestedCode | kSecCSStrictValidate))
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    func reply(to text: String, continuation: Bool) throws -> String {
        guard canQueryApplications() else { throw CocoaError(.featureUnsupported) }
        let data = Data(text.utf8)
        guard data.count <= 128, let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys).isSubset(of: ["operation", "extension", "directory", "scheme", "extensionless", "symlink", "selectedFile", "offset"]),
              fields.values.allSatisfy({ !($0 is NSNull) }) else { throw CocoaError(.featureUnsupported) }
        let request = try JSONDecoder().decode(Request.self, from: data)
        let target = try request.target(selectedFiles: selectedFiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if continuation || (request.operation == .list && (request.offset ?? 0) > 0) {
            guard request.operation == .list, let offset = request.offset, offset > 0,
                  let cursor = listCursor, cursor.offset == offset, cursor.target == target else {
                throw CocoaError(.featureUnsupported)
            }
            return try listPage(cursor, encoder: encoder)
        }
        guard queriesLeft > 0, request.offset == nil || (request.operation == .list && request.offset == 0) else {
            throw CocoaError(.featureUnsupported)
        }
        queriesLeft -= 1
        switch request.operation {
        case .list:
            let applications = target.map(associatedApplications(for:)) ?? installedApplications()
            return try listPage(ListCursor(target: target, applications: applications, offset: 0), encoder: encoder)
        case .default:
            guard let target, let application = defaultApplication(for: target) else { throw CocoaError(.featureUnsupported) }
            return String(decoding: try encoder.encode(application), as: UTF8.self)
        case .frontmost:
            guard target == nil, let application = frontmostApplication() else { throw CocoaError(.featureUnsupported) }
            return String(decoding: try encoder.encode(application), as: UTF8.self)
        }
    }

    private func listPage(_ cursor: ListCursor, encoder: JSONEncoder) throws -> String {
        var items: [Application] = []
        var next = cursor.offset
        var bytes = 0
        for app in cursor.applications.dropFirst(cursor.offset) {
            let nextOffset = next + 1
            let remainder = nextOffset < cursor.applications.count ? nextOffset : nil
            let itemBytes = try encoder.encode(app).count
            let separatorBytes = items.isEmpty ? 0 : 1
            let envelopeBytes = try encoder.encode(ListPage(items: [], nextOffset: remainder)).count
            guard bytes + itemBytes + separatorBytes + envelopeBytes <= Self.maximumReplyBytes else { break }
            items.append(app)
            bytes += itemBytes + separatorBytes
            next = nextOffset
        }
        guard cursor.applications.isEmpty || next > cursor.offset else { throw CocoaError(.fileReadTooLarge) }
        let remainder = next < cursor.applications.count ? next : nil
        let response = try encoder.encode(ListPage(items: items, nextOffset: remainder))
        listCursor = remainder.map { ListCursor(target: cursor.target, applications: cursor.applications, offset: $0) }
        return String(decoding: response, as: UTF8.self)
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
        results.append(contentsOf: indexedApplications(excluding: &seen))
        results.sort { first, second in
            let order = (first.localizedName ?? first.name).localizedStandardCompare(second.localizedName ?? second.name)
            return order == .orderedSame ? first.path < second.path : order == .orderedAscending
        }
        #endif
        installed = results
        return results
    }

    private func indexedApplications(excluding seen: inout Set<String>) -> [Application] {
        let expression = "kMDItemContentType == 'com.apple.application-bundle'"
        guard let query = MDQueryCreate(kCFAllocatorDefault, expression as CFString, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, [kMDQueryScopeComputerIndexed!] as CFArray, 0)
        MDQuerySetMaxCount(query, 16_384)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        defer { MDQueryStop(query) }
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            guard let result = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(result).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String, !seen.contains(path) else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
            guard !seen.contains(url.path),
                  !url.pathComponents.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") })
            else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let app = Application(indexedURL: url,
                                        localizedName: MDItemCopyAttribute(item, kMDItemDisplayName) as? String,
                                        bundleId: MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String)
            else { return nil }
            seen.insert(url.path)
            return app
        }
    }

    private func associatedApplications(for target: Target) -> [Application] {
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        switch target {
        case .contentType(.plainText): return syntheticApplications
        case .url(let url) where url.scheme == "https" || url.scheme == "mailto": return syntheticApplications
        default: return []
        }
        #else
        let workspace = NSWorkspace.shared
        let urls: [URL]
        switch target {
        case .contentType(let type): urls = workspace.urlsForApplications(toOpen: type)
        case .url(let url): urls = workspace.urlsForApplications(toOpen: url)
        case .namedFile(let name):
            urls = Self.withExampleFile(named: name, workspace.urlsForApplications(toOpen:)) ?? []
        }
        return urls.compactMap { Application(url: $0) }
        #endif
    }

    private func defaultApplication(for target: Target) -> Application? {
        #if KEYLANE_SYNTHETIC_APPLICATION_QUERIES
        return associatedApplications(for: target).first
        #else
        let workspace = NSWorkspace.shared
        let url: URL?
        switch target {
        case .contentType(let type): url = workspace.urlForApplication(toOpen: type)
        case .url(let targetURL): url = workspace.urlForApplication(toOpen: targetURL)
        case .namedFile(let name):
            url = Self.withExampleFile(named: name, workspace.urlForApplication(toOpen:)) ?? nil
        }
        return url.flatMap { Application(url: $0) }
        #endif
    }

    private static func withExampleFile<Result>(named name: String, _ query: (URL) -> Result) -> Result? {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("keylane-app-query-\(UUID())", isDirectory: true)
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
        defer { try? files.removeItem(at: directory) }

        // Launch Services recognizes these fixed names on an existing file.
        let file = directory.appendingPathComponent(name, isDirectory: false)
        guard files.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { return nil }
        return query(file)
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

final class ClipboardContentReader {
    private static let concealment = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private let board: NSPasteboard
    private let changeCount: Int
    private var remaining = ExtensionClipboardReadTransport.maximumReads
    private var transfers: [UUID: (data: Data, next: Int)] = [:]

    private init(board: NSPasteboard, changeCount: Int) {
        self.board = board
        self.changeCount = changeCount
    }

    static func make(app: URL, marker: Any) -> ClipboardContentReader? {
        guard let changeCount = ReviewedViewReadAccess.integer(marker), changeCount >= 0 else { return nil }
        let name = Bundle(url: app)?.object(forInfoDictionaryKey: "KeylaneReviewedRaycastPasteboard") as? String
        let board = name.map { NSPasteboard(name: .init($0)) } ?? .general
        return ClipboardContentReader(board: board, changeCount: changeCount)
    }

    var isCurrent: Bool { board.changeCount == changeCount }

    func claimRequest() throws {
        guard remaining > 0, isCurrent else { throw CocoaError(.featureUnsupported) }
        remaining -= 1
    }

    func reply(to request: String) throws -> String {
        guard request.isEmpty || request == "content" else { throw CocoaError(.featureUnsupported) }
        try claimRequest()
        var result: [String: String] = [:]
        if board.types?.contains(Self.concealment) != true {
            if let text = board.string(forType: .string) {
                result["text"] = text
            }
            if request == "content" {
                if let html = board.string(forType: .html) {
                    result["html"] = html
                }
                if let rawURL = board.string(forType: .fileURL), let file = URL(string: rawURL), file.isFileURL,
                   file.host == nil || file.host == "" || file.host == "localhost",
                   file.user == nil, file.password == nil, file.query == nil, file.fragment == nil,
                   ExtensionFinderRevealEvent.isValidPath(file.path) {
                    result["file"] = file.path
                }
            }
        }
        guard isCurrent else { throw CocoaError(.featureUnsupported) }
        return transfer(try ExtensionClipboardReadTransport.encode(result))
    }

    func transfer(_ payload: String) -> String {
        let data = Data(payload.utf8)
        if data.count <= 4_096 { return payload }
        let id = UUID()
        transfers[id] = (data, 0)
        return "{\"transfer\":\"\(id.uuidString)\",\"bytes\":\(data.count)}"
    }

    func chunk(_ selector: String) throws -> String {
        let parts = selector.split(separator: ":", omittingEmptySubsequences: false)
        guard isCurrent, parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              let offset = Int(parts[1]), String(offset) == parts[1],
              let pending = transfers[id], offset == pending.next else { throw CocoaError(.featureUnsupported) }
        let end = min(offset + ExtensionClipboardReadTransport.chunkBytes, pending.data.count)
        let result = pending.data[offset..<end].base64EncodedString()
        if end == pending.data.count {
            transfers.removeValue(forKey: id)
        } else {
            transfers[id]?.next = end
        }
        return result
    }
}

private struct GuestToastState {
    private struct Event: Decodable {
        enum Operation: String, Decodable { case show, update, hide }
        let operation: Operation
        let id: Int
        let title: String?
        let message: String?
        let style: String?
        let interaction: Interaction?
    }

    private struct Interaction: Decodable {
        let token: String
        let primary: String?
        let secondary: String?
        let primaryShortcut: Shortcut?
        let secondaryShortcut: Shortcut?

        struct Shortcut: Decodable {
            let key: String
            let modifiers: [String]

            var valid: Bool {
                let special = ["return", "enter", "delete", "backspace", "deleteForward", "tab", "escape",
                               "space", "arrowLeft", "arrowRight", "arrowUp", "arrowDown", "pageUp", "pageDown", "home", "end"]
                let printable = "abcdefghijklmnopqrstuvwxyz0123456789.,;=+[]{}«»()/\\'`§^@$-"
                return (special.contains(key) || (key.count == 1 && printable.contains(key)))
                    && modifiers.count <= 4 && Set(modifiers).count == modifiers.count
                    && modifiers.allSatisfy { ["cmd", "ctrl", "opt", "shift"].contains($0) }
            }
        }

        var valid: Bool {
            UUID(uuidString: token) != nil && [primary, secondary].compactMap { $0 }.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 80 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            } && (primary != nil || secondary != nil)
                && (primaryShortcut == nil || (primary != nil && primaryShortcut?.valid == true))
                && (secondaryShortcut == nil || (secondary != nil && secondaryShortcut?.valid == true))
        }
    }

    private var interaction: Interaction?
    private var publishedTokens = Set<UUID>()

    private var newestID = 0
    private var visibleID: Int?

    mutating func accept(_ text: String, allowsInteraction: Bool) throws {
        guard !text.contains("\n"), !text.contains("\r") else { throw CocoaError(.featureUnsupported) }
        let event = try JSONDecoder().decode(Event.self, from: Data(text.utf8))
        if event.operation != .hide {
            guard let title = event.title, let style = event.style,
                  ["SUCCESS", "FAILURE", "ANIMATED"].contains(style),
                  title.utf8.count + (event.message?.utf8.count ?? 0) <= 2048 else {
                throw CocoaError(.featureUnsupported)
            }
        }
        let eventToken: UUID?
        if let candidate = event.interaction {
            guard allowsInteraction, candidate.valid, event.operation != .hide,
                  let token = UUID(uuidString: candidate.token), !publishedTokens.contains(token)
            else { throw CocoaError(.featureUnsupported) }
            eventToken = token
        } else {
            eventToken = nil
        }
        switch event.operation {
        case .show:
            guard event.id > newestID else { throw CocoaError(.featureUnsupported) }
            newestID = event.id
            visibleID = event.id
        case .update, .hide:
            guard event.id == visibleID else { throw CocoaError(.featureUnsupported) }
            if event.operation == .hide { visibleID = nil }
        }
        if let eventToken { publishedTokens.insert(eventToken) }
        interaction = event.interaction
    }

    private var inputLine = Data()
    private var pendingInput = Data()

    mutating func readAction(token: String, polling: Bool, deadline: ContinuousClock.Instant) throws -> String {
        guard let interaction, interaction.token == token else { throw CocoaError(.featureUnsupported) }
        let end = min(deadline, ContinuousClock.now + .seconds(5))
        var selection = ""
        defer {
            if !polling || !selection.isEmpty { self.interaction = nil }
        }
        while let choice = try readParentInput(until: end, polling: polling) {
            if choice == token + ":dismiss" {
                selection = "dismiss"
                break
            }
            if interaction.primary != nil && choice == token + ":primary" {
                selection = "primary"
                break
            }
            if interaction.secondary != nil && choice == token + ":secondary" {
                selection = "secondary"
                break
            }
        }
        return selection
    }

    mutating func readConfirmationReply(budget: ExtensionExecutionBudget, waitEnded: () -> Void,
                                        maximumLineBytes: Int = 80, decode: (String) -> String?) throws -> String {
        interaction = nil
        var waiting = false
        var deadline = budget.replyDeadline
        defer {
            if waiting {
                budget.endConfirmation()
                waitEnded()
            }
        }
        while let reply = try readParentInput(until: deadline, polling: false, maximumBytes: maximumLineBytes) {
            guard let choice = decode(reply) else { continue }
            if choice != "shown" { return choice }
            if !waiting {
                guard let until = budget.beginConfirmation() else { throw CocoaError(.featureUnsupported) }
                waiting = true
                deadline = until
            }
        }
        throw CocoaError(.featureUnsupported)
    }

    mutating func readPresentationReply(_ accepted: String, rejected: String, deadline: ContinuousClock.Instant) throws -> Bool {
        interaction = nil
        while let reply = try readParentInput(until: deadline, polling: false) {
            if reply == accepted { return true }
            if reply == rejected { return false }
        }
        return false
    }

    private mutating func readParentInput(until deadline: ContinuousClock.Instant, polling: Bool, maximumBytes: Int = 80) throws -> String? {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while ContinuousClock.now < deadline {
            if let end = pendingInput.firstIndex(of: 10) {
                let prefix = pendingInput.prefix(upTo: end)
                guard inputLine.count + prefix.count <= maximumBytes else { throw CocoaError(.featureUnsupported) }
                inputLine.append(contentsOf: prefix)
                pendingInput.removeSubrange(...end)
                let line = String(decoding: inputLine, as: UTF8.self)
                inputLine.removeAll(keepingCapacity: true)
                return line
            }
            guard inputLine.count + pendingInput.count <= maximumBytes else { throw CocoaError(.featureUnsupported) }
            inputLine.append(pendingInput)
            pendingInput.removeAll(keepingCapacity: true)
            var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&input, 1, polling ? 0 : 100)
            if ready < 0 && errno == EINTR { continue }
            if ready < 0 || (polling && ready == 0) { return nil }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            pendingInput.append(contentsOf: buffer.prefix(count))
        }
        return nil
    }
}

private enum ReviewedViewReadAccess {
    static func bundle(phase: String, kernelPath: String, imagePath: String, request: [String: Any]) -> URL? {
        guard phase == "view-app", ReviewedViewArtifact.isViewImage(URL(fileURLWithPath: imagePath).lastPathComponent),
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
    private enum Operation: String { case get, set, remove, all, clear, getPage, upload, commit }
    private static let capacity = 96 * 1_024
    private static let pageSize = 8_192
    private static let uploadChunkSize = 8_192
    private var upload = Data()
    private var snapshot: (data: Data, operation: Operation)?
    private var nextOffset = 0
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
        let storage = GuestLocalStorage(file: file, app: app)
        return storage.signatureIsValid ? storage : nil
    }

    func reply(to text: String) throws -> String {
        guard signatureIsValid else { throw CocoaError(.featureUnsupported) }
        let data = Data(text.utf8)
        guard data.count <= (Self.uploadChunkSize * 4 / 3) + 256,
              let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = request["operation"] as? String, let operation = Operation(rawValue: name)
        else { throw CocoaError(.featureUnsupported) }
        switch operation {
        case .upload:
            return try appendUpload(request)
        case .commit:
            let contents = upload
            upload = Data()
            guard Set(request.keys) == ["operation", "size"],
                  Self.integer(request["size"]) == contents.count, contents.count > Self.pageSize,
                  let decoded = try JSONSerialization.jsonObject(with: contents) as? [String: Any],
                  let name = decoded["operation"] as? String, let entryOperation = Operation(rawValue: name),
                  [.get, .set, .remove].contains(entryOperation) else { throw CocoaError(.featureUnsupported) }
            return try perform(entryOperation, request: decoded)
        default:
            upload = Data()
            return try perform(operation, request: request)
        }
    }

    private func appendUpload(_ request: [String: Any]) throws -> String {
        guard Set(request.keys) == ["operation", "offset", "chunk"],
              let offset = Self.integer(request["offset"]), offset >= 0,
              let encoded = request["chunk"] as? String, let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty, bytes.count <= Self.uploadChunkSize, bytes.base64EncodedString() == encoded else {
            upload = Data()
            throw CocoaError(.featureUnsupported)
        }
        if offset == 0 { upload = Data() }
        guard offset == upload.count, offset.isMultiple(of: Self.uploadChunkSize),
              offset + bytes.count <= Self.capacity + 256 else {
            upload = Data()
            throw CocoaError(.featureUnsupported)
        }
        upload.append(bytes)
        return ""
    }

    private func perform(_ operation: Operation, request: [String: Any]) throws -> String {
        let key = request["key"] as? String
        let expected: Set<String>
        switch operation {
        case .get, .remove: expected = ["operation", "key"]
        case .set: expected = ["operation", "key", "value"]
        case .all, .getPage: expected = ["operation", "offset"]
        case .clear: expected = ["operation"]
        case .upload, .commit: throw CocoaError(.featureUnsupported)
        }
        guard Set(request.keys) == expected, key.map(Self.validKey) ?? !expected.contains("key")
        else { throw CocoaError(.featureUnsupported) }

        if operation == .all || operation == .getPage {
            guard let offset = Self.integer(request["offset"]), offset >= 0 else { throw CocoaError(.featureUnsupported) }
            if offset != 0 {
                guard offset == nextOffset, snapshot?.operation == operation else { throw CocoaError(.featureUnsupported) }
                return try storagePage(offset: offset)
            }
            guard operation == .all else { throw CocoaError(.featureUnsupported) }
        }
        snapshot = nil
        nextOffset = 0

        let lockPath = file.deletingLastPathComponent().appendingPathComponent("local-storage.lock").path
        let lock = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }

        var values = try load()
        switch operation {
        case .get:
            let result: [String: Any] = key.flatMap { values[$0] }.map { ["value": $0] } ?? [:]
            let encoded = try Self.encode(result)
            if encoded.count <= Self.pageSize { return String(decoding: encoded, as: UTF8.self) }
            snapshot = (encoded, .getPage)
            return try storagePage(offset: 0)
        case .all:
            snapshot = (try Self.encode(values), .all)
            return try storagePage(offset: 0)
        case .set:
            guard let key, let value = request["value"], Self.validValue(value) else { throw CocoaError(.featureUnsupported) }
            values[key] = value
        case .remove:
            guard let key, values.removeValue(forKey: key) != nil else { return "" }
        case .clear:
            values.removeAll()
        case .getPage, .upload, .commit:
            throw CocoaError(.featureUnsupported)
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

    private func storagePage(offset: Int) throws -> String {
        guard let data = snapshot?.data, offset < data.count else {
            throw CocoaError(.featureUnsupported)
        }
        let end = min(offset + Self.pageSize, data.count)
        let chunk = data[offset..<end].base64EncodedString()
        nextOffset = end < data.count ? end : 0
        if nextOffset == 0 { snapshot = nil }
        return String(decoding: try Self.encode(["chunk": chunk, "nextOffset": nextOffset]), as: UTF8.self)
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

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(number.stringValue)
    }

    private static func validKey(_ key: String) -> Bool {
        key.utf8.count < capacity && key.utf8.count.isMultiple(of: 4) &&
            key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validValue(_ value: Any) -> Bool {
        if value is String { return true }
        if let encoded = value as? [String: String], encoded.count == 1 {
            if encoded["number"] == "-0" { return true }
            if let bits = encoded["numberBits"], bits.utf8.count == 16,
               bits.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return true }
            if let utf16 = encoded["utf16"], let bytes = Data(base64Encoded: utf16),
               !bytes.isEmpty, bytes.count.isMultiple(of: 2),
               bytes.base64EncodedString() == utf16 { return true }
        }
        return (value as? NSNumber)?.doubleValue.isFinite == true
    }

    private static func encode(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .withoutEscapingSlashes)
    }
}
