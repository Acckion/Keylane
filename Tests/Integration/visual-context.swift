import AppKit
import Combine
import Foundation
import ImageIO
import KeylaneCore
import SwiftUI
@testable import Keylane

@MainActor private final class VisualReadState { var started = 0 }

@MainActor private func verifyVisual() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("keylane-visual-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let bitmap = CGContext(data: nil, width: 3000, height: 1800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 3000, height: 1800))
    bitmap.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1000, height: 1800))
    bitmap.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); bitmap.fill(CGRect(x: 2000, y: 0, width: 1000, height: 1800))
    let original = bitmap.makeImage()!
    let png = NSMutableData(), encoder = CGImageDestinationCreateWithData(png, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(encoder, original, [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.0, kCGImagePropertyGPSLongitude: 34.0], kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "PRIVATE_METADATA_SENTINEL", kCGImagePropertyExifDateTimeOriginal: "1999:01:01 01:02:03"]] as CFDictionary)
    precondition(CGImageDestinationFinalize(encoder))
    let file = root.appendingPathComponent("synthetic-chart.jpg")
    try (png as Data).write(to: file)
    let attachment = try await AIVisualImageLoader.read(file)
    let link = root.appendingPathComponent("alias.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    do { _ = try await AIVisualImageLoader.read(link); preconditionFailure("Symlink image accepted") } catch AIResponseError.invalidImage { }
    let image = attachment.image!
    precondition(image.width == 2048 && image.height <= 2048 && image.data.count <= AIImageInput.maximumBytes)
    let clean = CGImageSourceCreateWithData(image.data as CFData, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(clean, 0, nil) as! [CFString: Any]
    let originalProperties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil) as! [CFString: Any]
    precondition(originalProperties[kCGImagePropertyGPSDictionary] != nil)
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    precondition(properties[kCGImagePropertyGPSDictionary] == nil && exif[kCGImagePropertyExifUserComment] == nil && exif[kCGImagePropertyExifDateTimeOriginal] == nil)
    let crop = try AIVisualRegion.pixelRect(CGRect(x: 0.7, y: 0, width: 0.3, height: 1), width: original.width, height: original.height)
    let cropped = original.cropping(to: crop)!
    let pixelCheck = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
    pixelCheck.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let rgb = pixelCheck.data!.assumingMemoryBound(to: UInt8.self)
    precondition(rgb[0] < 30 && rgb[2] > 220, "Selected blue area must not contain the red area outside the crop")
    let tiny = try AIVisualImageLoader.encode(original.cropping(to: CGRect(x: 0, y: 0, width: 16, height: 12))!)
    precondition(tiny.width == 16 && tiny.height == 12)
    let cropData = try AIVisualImageLoader.encode(cropped)
    precondition(cropData.width == Int(crop.width) && cropData.height == Int(crop.height))
    print("PASS image pipeline: bounded oriented thumbnail, metadata-free raster, exact crop, no source URL on wire")

    try await verifyVisualWire(image: image)
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [VisualProtocol.self]
    var vision = AIConnection(endpoint: "https://synthetic.invalid/v1", model: "synthetic-vision", mode: .complete)
    vision.supportsImages = true

    let composer = AIConversationComposer()
    composer.text = "Keep my question"
    composer.attachments = [.init(title: "Existing", text: "Keep my text")]
    let oldDraft = composer.draftID
    precondition(composer.appendAttachment(attachment, for: oldDraft))
    precondition(composer.text == "Keep my question" && composer.attachments.count == 2)
    var turn = AIConversationTurn(question: composer.text, attachments: composer.attachments)
    turn.answer = "synthetic answer"; turn.complete = true
    let restored = try JSONDecoder().decode(AIConversationTurn.self, from: JSONEncoder().encode(turn))
    precondition(restored == turn && restored.attachments?.last?.image == image)
    let repository = AIConversationRepository(url: root.appendingPathComponent("history.sqlite"))
    let record = AIChatRecord(id: UUID(), content: .init(model: .init(vision), turns: [turn]))
    try repository.save(record)
    let reopened = try repository.load(record.id)
    precondition(reopened?.content.turns == [turn])
    let legacy = Data("{\"id\":\"00000000-0000-0000-0000-000000000001\",\"title\":\"Old\",\"text\":\"Legacy\",\"symbol\":\"doc\"}".utf8)
    let oldAttachment = try JSONDecoder().decode(AIConversationAttachment.self, from: legacy)
    precondition(oldAttachment.image == nil)
    let contextBeforeDisable = composer.contextGeneration
    let preparation = VisualReadState()
    composer.loadAttachments { await MainActor.run { preparation.started += 1 }; return [attachment] }
    composer.cancelAttachmentLoad()
    precondition(composer.text == "Keep my question" && composer.attachments.count == 2 && composer.contextGeneration != contextBeforeDisable)
    try await Task.sleep(for: .milliseconds(80))
    precondition(composer.attachments.count == 2 && !composer.loadingFiles && preparation.started == 0)
    composer.loadAttachments { try? await Task.sleep(for: .milliseconds(50)); return [attachment] }
    composer.clear()
    try await Task.sleep(for: .milliseconds(80))
    precondition(composer.attachments.isEmpty && !composer.appendAttachment(attachment, for: oldDraft))
    print("PASS persistence/drafts: image+text JSON/SQLite restore, old attachments readable, existing draft retained, reset cancels late attachment")

    let suite = "keylane.visual-session." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    preferences.set(try JSONEncoder().encode(AIConfiguration.State(enabled: true, connections: [vision], selectedID: vision.id)), forKey: "aiConnections.v1")
    let configuration = AIConfiguration(preferences: preferences)
    let session = AIConversationSession(configuration: configuration, runtime: AIRuntime(configuration: sessionConfiguration), readKey: { _ in "synthetic-key" })
    session.composer.attachments = [attachment]; session.composer.text = "Synthetic visual session"
    VisualProtocol.state.begin(image.data)
    precondition(session.submit(session.composer.text))
    let activeID = session.turns[0].id
    session.beginChat()
    let deadline = ContinuousClock.now + .seconds(5)
    while session.running && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    precondition(!session.running && session.turns[0].id == activeID && session.turns[0].attachments?.first?.image == image && VisualProtocol.state.count == 1)
    let historyMessages = session.messages(for: "Follow up")
    precondition(historyMessages.contains { $0.images.first == image })
    print("PASS shared session: Quick AI → Chat preserves active visual turn without resending; follow-up retains image")

    let view = NSHostingView(rootView: VStack(spacing: 16) {
        AIConversationAttachmentLabel(attachment: attachment)
        AIVisualRegionPreview(image: cropped, region: .constant(CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.7)))
    }.padding(20).frame(width: 610, height: 420))
    view.frame = CGRect(x: 0, y: 0, width: 610, height: 420)
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    precondition(view.fittingSize.width > 0)
    if let evidence = ProcessInfo.processInfo.environment["KEYLANE_AI_UI_EVIDENCE"], let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: evidence).appendingPathComponent("visual-preview.png")) }
    }
    window.close()
    print("PASS native attachment preview component instantiated from production code; no desktop capture, AX read, permission prompt or installed app main")
}

@_cdecl("KeylaneModuleAIFixtureMain")
@MainActor public func visualFixtureMain() -> Int32 {
    Task { @MainActor in
        do { try await verifyVisual(); exit(0) }
        catch { fputs("Visual fixture failed: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.run(); return 1
}
