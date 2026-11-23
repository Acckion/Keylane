import Foundation
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
