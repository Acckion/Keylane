import Foundation
import Combine
import KeylaneCore

@MainActor
private func verifyApprovedPickerRoute() async throws {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("KeylanePickerRoute-" + UUID().uuidString)
    let approved = fixture.appendingPathComponent("approved", isDirectory: true)
    let other = fixture.appendingPathComponent("other", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    for folder in [approved, other] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let selected = approved.appendingPathComponent("picked.txt")
    try Data("first approved snapshot".utf8).write(to: selected)
    let route = try AIFileAttachment.ApprovedPickerRoute(selected)
    var readCallback = false
    do {
        try route.withValidatedParent(of: other.appendingPathComponent("picked.txt")) { _ in readCallback = true }
        preconditionFailure("Mismatched picker parent was accepted")
    } catch AIActionError.staleSource {}
    precondition(!readCallback)
    let recoveryFolder = fixture.appendingPathComponent(".keylane-ai-recovery", isDirectory: true)
    try FileManager.default.createDirectory(at: recoveryFolder, withIntermediateDirectories: false)
    let recoveryName = recoveryFolder.appendingPathComponent("inert-fixture.txt")
    try Data("synthetic fixture, not recovery data".utf8).write(to: recoveryName)
    do {
        _ = try AIFileAttachment.ApprovedPickerRoute(recoveryName)
        preconditionFailure("Recovery namespace was accepted")
    } catch AIActionError.staleSource {}

    let reader = AIFileAttachment.resourceReader(selected)
    let original = try await reader.read()
    guard let previous = original.resourceSnapshot else { throw AIActionError.unavailable }
    try Data("replacement in the same approved directory".utf8).write(to: selected, options: .atomic)
    let refreshed = try await reader.read(replacing: previous)
    guard let next = refreshed.resourceSnapshot else { throw AIActionError.unavailable }
    precondition(original.text == "first approved snapshot" && previous.matches(original.text))
    precondition(refreshed.text == "replacement in the same approved directory" && next.matches(refreshed.text))
    precondition(previous.reference == next.reference && previous.revision != next.revision)
    print("PASS retained picker: parent mismatch rejected before reading, recovery namespace excluded, same-directory atomic replacement refreshes version")
    let deniedRoute = AIFileAttachment.resourceReader(selected) { _ in
        throw AIFileAttachment.PickerBindingFailure.parentAccess(try AIFileAttachment.ApprovedPickerRoute.selectionPath(selected))
    }
    precondition(!deniedRoute.allowsRefresh)
    let composer = AIConversationComposer()
    composer.loadResourceReaders([deniedRoute])
    for _ in 0..<100 where composer.loadingFiles { try await Task.sleep(for: .milliseconds(10)) }
    guard let staticAttachment = composer.attachments.first, let staticSnapshot = staticAttachment.resourceSnapshot else {
        throw AIActionError.unavailable
    }
    precondition(staticAttachment.text == refreshed.text && staticSnapshot.matches(staticAttachment.text))
    precondition(!composer.canReread(staticAttachment) && composer.snapshot.resourceReaders.isEmpty)
    try Data("later version must not be read".utf8).write(to: selected, options: .atomic)
    composer.rereadAttachment(staticAttachment.id)
    precondition(!composer.loadingFiles && composer.attachments == [staticAttachment])
    do {
        _ = try await deniedRoute.read(replacing: staticSnapshot)
        preconditionFailure("Static picker snapshot unexpectedly refreshed")
    } catch AIActionError.staleSource {}
    let rejected = AIFileAttachment.resourceReader(selected) { _ in throw AIActionError.staleSource }
    do {
        _ = try await rejected.read()
        preconditionFailure("Stale binding unexpectedly fell back to a file read")
    } catch AIActionError.staleSource {}
    print("PASS explicit picker fallback: static snapshot retains no reader and schedules no refresh; stale binding fails closed")

    var opens = 0, stops = 0
    func startDenied() -> Bool { false }
    func stop() { stops += 1 }
    func descriptorCallback() { opens += 1 }
    do {
        try AIFileAttachment.ApprovedPickerRoute.withPickerScope(required: true, start: startDenied, stop: stop, descriptorCallback)
        preconditionFailure("Previously scoped route accepted failed reacquisition")
    } catch AIActionError.staleSource {}
    precondition(opens == 0 && stops == 0)
    try AIFileAttachment.ApprovedPickerRoute.withPickerScope(required: false, start: startDenied, stop: stop, descriptorCallback)
    try AIFileAttachment.ApprovedPickerRoute.withPickerScope(required: true, start: { true }, stop: stop, descriptorCallback)
    precondition(opens == 2 && stops == 1)
    print("PASS retained picker scope: failed reacquisition rejected before descriptor callback; plain URLs and balanced scopes preserved")
}

try await verifyApprovedPickerRoute()

// P1 #227: a command's first disable revokes the retained reader, not accepted data.
@MainActor private func verifyRetainedCommandReaderLifetime() async throws {
    let availability = CurrentValueSubject<Bool, Never>(true)
    var text = "accepted snapshot", reads = 0
    var pause = false
    var pending: CheckedContinuation<Void, Never>?
    let source = AIActionSource(moduleID: .init(rawValue: "fixture.retained-command"), load: {
        reads += 1
        if pause { await withCheckedContinuation { pending = $0 } }
        return .init(sourceID: "record", title: "Synthetic record", text: text)
    }, isCurrent: { $0.fingerprint == AIActionContext.digest(text) })
    let composer = AIConversationComposer(); composer.text = "keep draft"
    func settled() async throws {
        let deadline = Date().addingTimeInterval(3)
        while composer.loadingFiles, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!composer.loadingFiles)
    }
    func attach() { composer.loadResourceReaders([.init(source: source)], availability: availability.eraseToAnyPublisher()) }
    attach(); try await settled()
    let accepted = composer.attachments[0], saved = composer.snapshot
    let retained = saved.resourceReaders[accepted.id]!
    let count = reads
    availability.send(false); availability.send(true)
    precondition(!composer.canReread(accepted), "P1: disable/re-enable revived a retained attachment reader")
    composer.rereadAttachment(accepted.id)
    precondition(!composer.loadingFiles && composer.attachments == [accepted] && reads == count && composer.text == "keep draft")
    do { _ = try await retained.read(replacing: accepted.resourceSnapshot); preconditionFailure("A copied old reader revived") }
    catch AIActionError.unavailable { }
    composer.restore(saved)
    precondition(!composer.canReread(accepted) && composer.attachments == [accepted])
    text = "explicit new selection"
    attach(); try await settled()
    let fresh = composer.attachments[1]
    precondition(composer.canReread(fresh) && !composer.canReread(accepted))
    precondition(fresh.text == text && accepted.text == "accepted snapshot")
    pause = true; text = "must not replace the accepted snapshot"
    composer.rereadAttachment(fresh.id)
    let deadline = Date().addingTimeInterval(3)
    while pending == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    precondition(pending != nil)
    availability.send(false); availability.send(true)
    try await settled()
    precondition(!composer.loadingFiles && !composer.canReread(fresh))
    pending?.resume(); pending = nil
    try await Task.sleep(for: .milliseconds(40))
    precondition(composer.attachments == [accepted, fresh] && composer.text == "keep draft")
    // Retiring A must not cancel a pending read owned by B.
    pause = false
    let other = CurrentValueSubject<Bool, Never>(true)
    composer.loadResourceReaders([.init(source: source)], availability: other.eraseToAnyPublisher())
    try await settled()
    let otherAccepted = composer.attachments[2]
    availability.send(true); attach(); try await settled()
    let unrelatedAccepted = composer.attachments[3]
    precondition(composer.canReread(unrelatedAccepted))
    pause = true; composer.rereadAttachment(otherAccepted.id)
    while pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    availability.send(false)
    precondition(composer.loadingFiles && composer.canReread(otherAccepted) && !composer.canReread(unrelatedAccepted))
    pending?.resume(); pending = nil
    try await settled()
    precondition(composer.canReread(composer.attachments[2]))
    // Initial attachment reads also reject a late result after transient revocation.
    composer.clear(); composer.text = "new draft"
    pause = true; availability.send(true); attach()
    while pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    availability.send(false); availability.send(true)
    pending?.resume(); pending = nil
    try await Task.sleep(for: .milliseconds(40))
    precondition(composer.attachments.isEmpty && composer.text == "new draft" && !composer.loadingFiles)
    print("PASS P1 retained reader: first disable revokes forever across off/on and draft copies; snapshots/draft survive; explicit fresh selection works; initial/refresh in-flight revocation rejects late data; unrelated source is preserved")
}

try await verifyRetainedCommandReaderLifetime()

private final class GlobalAIAvailabilityFixture {
    @Published var enabled = true
    func send(_ enabled: Bool) { self.enabled = enabled }
    func eraseToAnyPublisher() -> AnyPublisher<Bool, Never> { $enabled.eraseToAnyPublisher() }
}

@MainActor private func verifyGlobalAIReaderLifetime() async throws {
    // Match AIConfiguration's @Published willSet delivery, not just a subject.
    let enabled = GlobalAIAvailabilityFixture()
    let composer = AIConversationComposer()
    composer.observeResourceAvailability(enabled.eraseToAnyPublisher())
    composer.text = "preserved draft"
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("keylane-global-ai-" + UUID().uuidString + ".txt")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("accepted picker snapshot".utf8).write(to: file)
    func settled() async throws {
        for _ in 0..<200 where composer.loadingFiles { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!composer.loadingFiles)
    }
    composer.attachFiles([file]); try await settled()
    let old = composer.attachments[0], saved = composer.snapshot
    precondition(composer.canReread(old))
    enabled.send(false); enabled.send(true)
    precondition(!composer.canReread(old) && composer.attachments == [old])
    composer.restore(saved)
    precondition(!composer.canReread(old) && composer.text == "preserved draft")
    do {
        _ = try await saved.resourceReaders[old.id]!.read()
        preconditionFailure("Global off/on revived copied picker reader")
    } catch AIActionError.unavailable {}
    try Data("fresh picker selection".utf8).write(to: file)
    composer.attachFiles([file]); try await settled()
    precondition(composer.attachments[1].text == "fresh picker selection" && composer.canReread(composer.attachments[1]))
    enabled.send(true)
    precondition(composer.canReread(composer.attachments[1]))

    var pause = false
    var pending: CheckedContinuation<Void, Never>?
    let source = AIActionSource(moduleID: .init(rawValue: "fixture.context"), load: {
        if pause { await withCheckedContinuation { pending = $0 } }
        return .init(sourceID: "context", title: "Context", text: "accepted context snapshot")
    }, isCurrent: { _ in true })
    let reader = composer.prepareResourceReader(.init(source: source))
    let context = try await reader.read()
    precondition(composer.appendResourceAttachment(context, reader: reader, for: composer.draftID))
    let accepted = composer.attachments
    pause = true
    composer.rereadAttachment(context.id)
    for _ in 0..<200 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    precondition(pending != nil)
    enabled.send(false); enabled.send(true)
    pending?.resume(); pending = nil
    try await settled()
    precondition(composer.attachments == accepted && !composer.canReread(context))
    let selecting = composer.prepareResourceReader(.init(source: source))
    let operation = Task { @MainActor in try await selecting.read() }
    for _ in 0..<200 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    precondition(pending != nil)
    enabled.send(false); enabled.send(true)
    pending?.resume(); pending = nil
    do { _ = try await operation.value; preconditionFailure("Pending context read survived global revoke") }
    catch AIActionError.unavailable {}
    precondition(!composer.appendResourceAttachment(context, reader: reader, for: composer.draftID))
    precondition(!composer.appendResourceAttachment(context, reader: .init(source: source), for: composer.draftID))
    pause = false
    let fresh = composer.prepareResourceReader(.init(source: source))
    let newContext = try await fresh.read()
    precondition(composer.appendResourceAttachment(newContext, reader: fresh, for: composer.draftID))
    precondition(composer.canReread(newContext) && composer.attachments.dropLast() == accepted[...])
    // A saved in-memory draft must keep the revocation subscription even if its
    // original composer is released before the global switch changes.
    var retired: AIConversationComposer? = AIConversationComposer()
    retired!.observeResourceAvailability(enabled.eraseToAnyPublisher())
    let retiringReader = retired!.prepareResourceReader(.init(source: source))
    let retiringAttachment = try await retiringReader.read()
    precondition(retired!.appendResourceAttachment(retiringAttachment, reader: retiringReader, for: retired!.draftID))
    let retiredDraft = retired!.snapshot
    weak var released = retired
    retired = nil
    precondition(released == nil)
    enabled.send(false); enabled.send(true)
    let destination = AIConversationComposer()
    destination.observeResourceAvailability(enabled.eraseToAnyPublisher())
    destination.restore(retiredDraft)
    precondition(destination.attachments == [retiringAttachment] && !destination.canReread(retiringAttachment))
    print("PASS global AI lifetime: actual attachFiles, context selection binding, copied drafts, same-turn off/on, pending refresh and selection, fresh explicit selection; accepted snapshots preserved")
}
try await verifyGlobalAIReaderLifetime()
