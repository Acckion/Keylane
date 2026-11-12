import AppKit
import Combine
import QuickLookThumbnailing

@main
struct ScreenshotLibraryCheck {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Screenshot check failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() async throws {
        _ = NSApplication.shared
        let identifier = "org.keylane.test.screenshots." + UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: identifier)!
        defer { defaults.removePersistentDomain(forName: identifier) }
        defaults.set(try JSONEncoder().encode([ScreenshotScope(path: folder.path, bookmark: nil)]), forKey: "screenshotScopes")
        let image = folder.appendingPathComponent("Screenshot Settings Fixture.png")
        try writeImage(image)

        let library = ScreenshotLibrary(defaults: defaults)
        library.refresh()
        try require(!library.enabled && !library.scanning && library.results.isEmpty,
                    "Screenshot management must stay inactive until enabled")
        try require(library.hasAuthorizedScope, "Fixture folder must be readable")
        library.enabled = true
        library.refresh()
        try await wait { !library.scanning }
        guard let item = library.selected else {
            throw CheckError.failure("Fixture not indexed (\(library.inaccessibleFolders) unreadable folders)")
        }
        try require(item.url.resolvingSymlinksInPath() == image.resolvingSymlinksInPath(), "Unexpected fixture path")

        var selectionUpdates = 0
        let observation = library.$selection.dropFirst().sink { _ in selectionUpdates += 1 }
        library.move(-1, vertical: false)
        library.move(1, vertical: true)
        try require(selectionUpdates == 0, "Grid boundary must not republish the same selection")
        library.filter = .movies
        try require(library.results.isEmpty && library.selected == nil, "Filtering must clear the old selection")
        library.filter = .images
        try require(library.selected?.id == item.id, "Filtering back must restore a valid selection")
        observation.cancel()

        let request = QLThumbnailGenerator.Request(fileAt: image, size: CGSize(width: 240, height: 240),
                                                   scale: 1, representationTypes: .thumbnail)
        let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        try require(thumbnail.cgImage.width > 0, "Quick Look thumbnail unavailable")

        library.recognizesText = true
        library.search("text:KEYLANE")
        try await wait { !library.searchingText }
        try require(library.results.count == 1, "Vision OCR search did not find the fixture")
        library.search("text:WRONG TOKEN")
        try await wait { !library.searchingText }
        try require(library.results.isEmpty, "OCR returned an unrelated match")
        library.search("name:Settings")
        try require(library.results.count == 1, "Filename query failed")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try library.copy(item, to: pasteboard)
        try require(pasteboard.data(forType: .png) != nil, "Screenshot did not copy as PNG")
        try require(pasteboard.string(forType: .fileURL) == item.url.absoluteString, "Screenshot file URL missing")

        let destination = try library.moveToTrash(item)
        if let destination, destination.lastPathComponent.hasPrefix("Screenshot Settings Fixture") {
            // Remove only the generated fixture, using the exact URL returned by FileManager.
            defer { try? FileManager.default.removeItem(at: destination) }
            try require(FileManager.default.fileExists(atPath: destination.path), "Trash did not receive the fixture")
        }
        try require(!FileManager.default.fileExists(atPath: image.path), "Original still in scope after trash")
        try require(library.results.isEmpty, "Trashed item still in the grid")
        print("Screenshot scope, filename query, Quick Look thumbnail, local Vision OCR, copy, and trash passed")
    }

    @MainActor private static func writeImage(_ url: URL) throws {
        let size = NSSize(width: 720, height: 420)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("KEYLANE SCREENSHOT" as NSString).draw(at: CGPoint(x: 45, y: 180), withAttributes: [
                .font: NSFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: NSColor.black
            ])
            return true
        }
        guard let data = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:])
        else { throw CheckError.failure("Could not make test image") }
        try data.write(to: url)
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try require(condition(), "Timed out")
    }

    private enum CheckError: Error { case failure(String) }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckError.failure(message) }
    }
}
