import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import KeylaneCore
import QuickLookThumbnailing

@main
struct ScreenshotLibraryCheck {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Screenshot check failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor private static func run() async throws {
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--shelf-only") { try await verifyShelfIntegration(); try await verifyUnavailableShelfScope(); return }
        let identifier = "org.keylane.test.screenshots." + UUID().uuidString
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let defaults = UserDefaults(suiteName: identifier)!
        defer { defaults.removePersistentDomain(forName: identifier) }
        defaults.set(try JSONEncoder().encode([ScreenshotScope(path: folder.standardizedFileURL.path, bookmark: nil)]), forKey: "screenshotScopes")
        let image = folder.appendingPathComponent("Screenshot Settings Fixture.png")
        try writeImage(image)

        let library = ScreenshotLibrary(defaults: defaults)
        library.refresh()
        try require(!library.enabled && !library.scanning && library.results.isEmpty,
                    "Screenshot management must stay inactive until enabled")
        try require(library.hasAuthorizedScope, "Fixture folder must be readable")
        library.enabled = true
        library.start()
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
        try library.copyPath(item, to: pasteboard)
        try require(pasteboard.string(forType: .string) == item.url.path, "Screenshot path missing")
        let copiedOCR = try await library.copyImageText(.ocr, from: item, to: pasteboard)
        try require(copiedOCR && pasteboard.string(forType: .string)?.contains("KEYLANE") == true,
                    "Image text action did not copy recognized text")
        let copiedQRFromText = try await library.copyImageText(.qr, from: item, to: pasteboard)
        try require(!copiedQRFromText && pasteboard.string(forType: .string)?.contains("KEYLANE") == true,
                    "A missing QR code must preserve the clipboard")

        library.zoomOut()
        try require(library.columns == 4 && library.selected?.id == item.id, "Zooming out must preserve selection")
        for _ in 0..<4 { library.zoomOut() }
        try require(library.columns == 6, "Grid must stop at six columns")
        library.zoomIn()
        try require(library.columns == 5, "Zooming in must reduce the column count")
        try require(ScreenshotLibrary(defaults: defaults).columns == 5, "Column count must persist")
        library.resetZoom()
        library.zoomIn()
        try require(library.columns == 3, "Actual size and the lower zoom bound must use three columns")

        try library.togglePin(item)
        try require(library.sections.first?.items.map(\.id) == [item.id] && library.selected?.id == item.id,
                    "Pinned media must move to the first section without losing selection")
        try require(ScreenshotLibrary(defaults: defaults).pinnedIDs == [item.id], "Pin must persist")
        try library.togglePin(item)
        try require(library.pinnedIDs.isEmpty && library.sections.first?.items.isEmpty == true
                    && library.selected?.id == item.id, "Unpinning must return media to its original section")
        try library.togglePin(item)

        let destination = try library.moveToTrash(item)
        if let destination, destination.lastPathComponent.hasPrefix("Screenshot Settings Fixture") {
            // Remove only the generated fixture, using the exact URL returned by FileManager.
            defer { try? FileManager.default.removeItem(at: destination) }
            try require(FileManager.default.fileExists(atPath: destination.path), "Trash did not receive the fixture")
        }
        try require(!FileManager.default.fileExists(atPath: image.path), "Original still in scope after trash")
        try require(library.results.isEmpty && library.pinnedIDs.isEmpty, "Trash must clear the grid and the pin")

        let qr = folder.appendingPathComponent("Screenshot QR Fixture.png")
        try writeQR(qr)
        let movie = folder.appendingPathComponent("Screen Recording Fixture.mov")
        try Data([0]).write(to: movie)
        library.filter = .all
        library.refresh()
        try await wait { !library.scanning }
        library.search("name:QR Fixture")
        guard let qrItem = library.selected else { throw CheckError.failure("QR fixture not indexed") }
        let copiedQR = try await library.copyImageText(.qr, from: qrItem, to: pasteboard)
        try require(copiedQR && pasteboard.string(forType: .string) == "KEYLANE-QR-FIXTURE",
                    "QR action must copy the decoded payload")

        library.filter = .movies
        library.search("")
        guard let movieItem = library.selected else { throw CheckError.failure("Recording fixture not indexed") }
        try library.copy(movieItem, to: pasteboard)
        try require(pasteboard.string(forType: .fileURL) == movieItem.url.absoluteString
                    && pasteboard.data(forType: .png) == nil, "Recording must copy as a file URL")
        try library.togglePin(movieItem)
        try require(library.sections.first?.items.map(\.id) == [movieItem.id], "Recording pin missing")
        library.filter = .images
        try require(library.sections.first?.items.isEmpty == true, "Pins must respect the media filter")

        library.enabled = false
        try require(library.results.isEmpty && library.selected == nil && !library.scanning && !library.searchingText,
                    "Disabling screenshots must release the catalog and cancel queries")
        try require(library.pinnedIDs == [movieItem.id], "Disabling must preserve pinned recordings")
        library.refresh()
        try require(!library.scanning, "Disabled screenshots must not begin a scan")
        library.enabled = true
        library.filter = .movies
        library.refresh()
        try await wait { !library.scanning && library.selected?.id == movieItem.id }
        try require(library.sections.first?.items.map(\.id) == [movieItem.id], "Re-enabled screenshots must restore pins")

        try await verifyLiveChanges(library, folder: folder, image: qr, movie: movie)
        try await verifyOCRLifecycle(in: folder, defaults: defaults)
        try await verifyRetention()
        try await verifyShelfIntegration()
        try await verifyUnavailableShelfScope()
        print("Screenshot scope, live changes, mixed media, latest image, Quick Look thumbnail, OCR and QR, file copy, pinning, grid zoom, and trash passed")
    }

    @MainActor private static func verifyLiveChanges(_ library: ScreenshotLibrary, folder: URL,
                                                    image: URL, movie: URL) async throws {
        library.filter = .images
        library.search("name:Fixture")
        library.start()
        try await wait { library.selected?.name == image.lastPathComponent }

        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let added = nested.appendingPathComponent("Screenshot New Fixture.png")
        try writeImage(added)
        try await wait { library.results.contains { $0.name == added.lastPathComponent } }
        try require(library.selected?.name == image.lastPathComponent && library.results.allSatisfy { $0.kind == .image },
                    "New screenshot changed the selection or media filter")
        let renamed = folder.appendingPathComponent("Screenshot Renamed Fixture.png")
        try FileManager.default.moveItem(at: image, to: renamed)
        try await wait { library.selected?.name == renamed.lastPathComponent }
        let removedItem = library.selected!
        try FileManager.default.removeItem(at: renamed)
        try await wait { library.selected?.name == added.lastPathComponent }
        do {
            try library.validate(removedItem)
            throw CheckError.failure("A deleted item still passed validation")
        } catch is CocoaError {}

        let ordinary = nested.appendingPathComponent("Ordinary.png")
        try writeImage(ordinary)
        let latestDate = Date().addingTimeInterval(30)
        try FileManager.default.setAttributes([.creationDate: latestDate], ofItemAtPath: ordinary.path)
        try FileManager.default.setAttributes([.creationDate: latestDate.addingTimeInterval(60)], ofItemAtPath: movie.path)
        library.includeAll = true
        library.filter = .all
        library.search("")
        try await wait { library.results.first?.kind == .movie && library.results.count == 3 }
        let latest = await withCheckedContinuation { continuation in
            library.latest { continuation.resume(returning: $0) }
        }
        try require(latest?.name == ordinary.lastPathComponent, "Latest command must skip newer movies and respect all media")

        let secondScope = folder.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: secondScope, withIntermediateDirectories: false)
        let movedScope = secondScope.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: secondScope)
            try? FileManager.default.removeItem(at: movedScope)
        }
        let outside = secondScope.appendingPathComponent("Screenshot Outside.png")
        try writeImage(outside)
        let missing = secondScope.appendingPathComponent("Missing", isDirectory: true)
        try require(library.addFolders([secondScope, missing]) == [missing], "Missing directory must be rejected")
        try await wait { library.results.count == 4 }
        try FileManager.default.moveItem(at: secondScope, to: movedScope)
        try await wait { library.unavailableScopePaths.contains(secondScope.standardizedFileURL.path) && library.results.count == 3 }
        try require(library.hasAuthorizedScope, "Other scopes must remain available after a scope is moved")
        try require(library.addFolders([movedScope]).isEmpty, "Moved scope can be authorized at its new location")
        try await wait { library.results.count == 4 }
        library.removeFolder(at: movedScope.standardizedFileURL.path)
        library.removeFolder(at: secondScope.standardizedFileURL.path)
        try await wait { library.results.count == 3 && library.unavailableScopePaths.isEmpty }

        library.stop()
        let hidden = nested.appendingPathComponent("Screenshot While Hidden.png")
        try writeImage(hidden)
        try await Task.sleep(for: .seconds(1))
        try require(!library.results.contains { $0.name == hidden.lastPathComponent }, "Inactive page must stop watching")
        for _ in 0..<3 {
            library.start()
            try await wait { !library.scanning && library.results.contains { $0.name == hidden.lastPathComponent } }
            library.stop()
        }
    }

    @MainActor private static func verifyOCRLifecycle(in base: URL, defaults: UserDefaults) async throws {
        let folder = base.appendingPathComponent("OCR fixtures")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defaults.set(try JSONEncoder().encode([ScreenshotScope(path: folder.standardizedFileURL.path, bookmark: nil)]), forKey: "screenshotScopes")
        let image = folder.appendingPathComponent("Screenshot OCR Lifecycle.png")
        let bad = folder.appendingPathComponent("Screenshot Invalid.png")
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let size = 512 * 1024
        func replace(_ text: String) throws {
            try writeImage(image, text: text, fixedSize: size)
            try FileManager.default.setAttributes([.modificationDate: timestamp, .creationDate: timestamp], ofItemAtPath: image.path)
        }
        try replace("KEYLANE ORIGINAL")
        try Data("Invalid image".utf8).write(to: bad)
        let library = ScreenshotLibrary(defaults: defaults)
        try require(library.accurate && !library.allowCloudOCR, "Recognition and cloud defaults changed")
        library.enabled = true
        library.recognizesText = true
        library.start()
        defer { library.stop() }
        try await wait("initial OCR fixtures") { !library.scanning && library.results.count == 2 }
        guard let original = library.results.first(where: { $0.name == image.lastPathComponent }),
              let invalid = library.results.first(where: { $0.name == bad.lastPathComponent }) else {
            throw CheckError.failure("OCR fixtures are missing")
        }
        func search(_ query: String) async throws {
            library.search(query)
            try await wait(query) { !library.searchingText }
        }
        try await search("text:ORIGINAL")
        try require(library.results.map(\.id) == [original.id] && library.skippedOCR == 1,
                    "English OCR or unreadable image feedback failed")
        try await search("text:ORIGINAL")
        try require(library.results.map(\.id) == [original.id], "Repeated OCR query lost the original match")

        try replace("REPLACEMENT 截图测试")
        library.refresh()
        library.search("name:Lifecycle")
        try await wait("replacement identity") { !library.scanning && library.selected?.identity != original.identity }
        guard let updated = library.selected else { throw CheckError.failure("Replacement not indexed") }
        try require(updated.id == original.id && updated.modified == original.modified && updated.size == original.size,
                    "Replacement must preserve the former cache key")
        try await search("text:ORIGINAL")
        try require(library.results.isEmpty, "Replacement incorrectly reused old OCR text at the same path, date and size")
        try await search("text:REPLACEMENT")
        try require(library.results.map(\.id) == [updated.id], "Changed image was not recognized")
        try await search("文字:截图测试")
        try require(library.results.map(\.id) == [updated.id], "Chinese OCR failed")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        func seedPasteboard() {
            pasteboard.clearContents()
            pasteboard.setString("Untouched", forType: .string)
        }
        seedPasteboard()
        var rejected = false
        do { _ = try await library.copyImageText(.ocr, from: invalid, to: pasteboard) }
        catch { rejected = true }
        try require(rejected && pasteboard.string(forType: .string) == "Untouched", "Invalid image changed the pasteboard")

        let waiting = Task { @MainActor in try await library.copyImageText(.ocr, from: updated, to: pasteboard) }
        await Task.yield()
        library.stop()
        var cancelled = false
        do { _ = try await waiting.value }
        catch is CancellationError { cancelled = true }
        try require(cancelled && pasteboard.string(forType: .string) == "Untouched",
                    "Closing the screenshot page did not cancel OCR copy")

        let large = folder.appendingPathComponent("Large")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: false)
        for index in 0..<384 {
            let name = String(format: "Screenshot Load %03d.png", index)
            try FileManager.default.linkItem(at: image, to: large.appendingPathComponent(name))
        }
        for _ in 0..<3 {
            library.search("name:Lifecycle")
            library.start()
            try await wait("reopen before large OCR") { !library.scanning && !library.searchingText }
            library.search("name:Load text:REPLACEMENT")
            try require(library.searchingText, "Large text query was not started")
            library.search("name:Lifecycle")
            try require(!library.searchingText && library.results.map(\.id) == [updated.id],
                        "A newer metadata query did not supersede OCR")
            library.search("name:Load text:REPLACEMENT")
            library.stop()
            try await Task.sleep(for: .milliseconds(200))
            try require(!library.searchingText && library.results.isEmpty && library.skippedOCR == 0,
                        "Stopped text query published results or feedback")
        }

        library.search("name:Lifecycle")
        library.start()
        try await wait("reopen after cancellation") { !library.scanning && !library.searchingText }
        try await search("name:Lifecycle text:REPLACEMENT")
        try require(library.results.map(\.id) == [updated.id], "OCR failed after reopening")
        library.accurate = false
        try await wait("fast recognition mode") { !library.searchingText }
        try require(library.results.map(\.id) == [updated.id], "Switching OCR mode lost the current query")
        library.accurate = true
        try await wait("accurate recognition mode") { !library.searchingText }
        library.search("name:Load text:REPLACEMENT")
        library.recognizesText = false
        try await Task.sleep(for: .milliseconds(200))
        try require(!library.searchingText && library.results.isEmpty, "Turning off OCR did not cancel the active text query")

        var removedScopeRejected = false
        library.removeFolder(at: folder.standardizedFileURL.path)
        do { _ = try await library.copyImageText(.ocr, from: updated, to: pasteboard) }
        catch { removedScopeRejected = true }
        try require(removedScopeRejected && pasteboard.string(forType: .string) == "Untouched",
                    "OCR copy accepted an item from a removed search scope")
        print("PASS OCR lifecycle: repeated and bilingual queries, equal-size replacement, unreadable image, pasteboard preservation, page exit, stale queries, 384-image cancellation and scope removal")
    }

    @MainActor private static func writeImage(_ url: URL, text: String = "KEYLANE SCREENSHOT", fixedSize: Int? = nil) throws {
        let size = NSSize(width: 720, height: 420)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            (text as NSString).draw(at: CGPoint(x: 45, y: 180), withAttributes: [
                .font: NSFont.systemFont(ofSize: 42, weight: .bold), .foregroundColor: NSColor.black
            ])
            return true
        }
        guard var data = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) })?.representation(using: .png, properties: [:])
        else { throw CheckError.failure("Could not make test image") }
        if let fixedSize {
            try require(data.count <= fixedSize, "Generated PNG exceeds the fixture size")
            data.append(Data(count: fixedSize - data.count))
        }
        try data.write(to: url, options: .atomic)
    }

    private static func writeQR(_ url: URL) throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("KEYLANE-QR-FIXTURE".utf8)
        guard let output = filter.outputImage else { throw CheckError.failure("Could not generate QR code") }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let canvas = CGRect(x: 0, y: 0, width: 440, height: 440)
        let code = scaled.transformed(by: .init(translationX: (canvas.width - scaled.extent.width) / 2,
                                                y: (canvas.height - scaled.extent.height) / 2))
        let image = code.composited(over: CIImage(color: .white)).cropped(to: canvas)
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    @MainActor private static func verifyRetention() async throws {
        let id = "org.keylane.test.retention." + UUID().uuidString
        let defaults = UserDefaults(suiteName: id)!
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(id)
        let scope = root.appendingPathComponent("screenshots", isDirectory: true)
        let trash = root.appendingPathComponent("test-trash", isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        defer {
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(try JSONEncoder().encode([ScreenshotScope(path: scope.path, bookmark: nil)]), forKey: "screenshotScopes")
        let old = Calendar.current.date(byAdding: .day, value: -10, to: Date())!
        func fixture(_ name: String, in directory: URL = scope, time: Date = old) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.creationDate: time, .modificationDate: time], ofItemAtPath: url.path)
            return url
        }

        let expired = try fixture("Screenshot expired.png")
        let movie = try fixture("Screen Recording expired.mov")
        let pinned = try fixture("Screenshot pinned.png")
        let recent = try fixture("Screenshot recent.png", time: Date())
        let other = try fixture("Family photo.png")
        let outside = try fixture("Screenshot outside.png", in: root)
        let failing = try fixture("Screenshot trash failure.png")
        try FileManager.default.createSymbolicLink(at: scope.appendingPathComponent("Screenshot symlink.png"), withDestinationURL: outside)
        let moveFixture: (URL) throws -> Void = { url in
            if url.lastPathComponent == failing.lastPathComponent { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }

        let initial = ScreenshotLibrary(defaults: defaults, trashExpiredItem: moveFixture)
        try require(initial.retention == .unlimited, "Existing installs must default to unlimited")
        initial.enabled = true
        initial.start()
        try await wait("retention fixture scan") { !initial.scanning && !initial.results.isEmpty }
        try require(FileManager.default.fileExists(atPath: expired.path), "Unlimited removed a file")
        guard let pinnedItem = initial.results.first(where: { $0.name == pinned.lastPathComponent }) else { throw CheckError.failure("Missing pin fixture") }
        try initial.togglePin(pinnedItem)
        guard let oldIdentity = pinnedItem.identity else { throw CheckError.failure("Missing pin identity") }
        let replacement = try fixture("replacement.png", in: root)
        try FileManager.default.moveItem(at: pinned, to: root.appendingPathComponent("original.png"))
        try FileManager.default.moveItem(at: replacement, to: pinned)
        initial.refresh()
        try await wait("pinned path replacement indexed") {
            !initial.scanning && initial.results.contains {
                $0.id == pinnedItem.id && $0.identity != nil && $0.identity != oldIdentity
            }
        }
        try require(initial.sections.first?.items.contains { $0.id == pinnedItem.id } == true,
                    "Replacement at a pinned path should appear in the pinned section")
        initial.enabled = false
        let renamed = scope.appendingPathComponent("Screenshot pinned renamed.png")
        try FileManager.default.moveItem(at: pinned, to: renamed)

        let library = ScreenshotLibrary(defaults: defaults, trashExpiredItem: moveFixture)
        library.includeAll = true
        library.enabled = true
        library.retention = .week
        library.retention = .unlimited
        try await Task.sleep(for: .milliseconds(200))
        try require(FileManager.default.fileExists(atPath: expired.path), "Switching to unlimited must cancel pending cleanup")
        library.retention = .week
        try await wait("background retention with page closed") { library.retentionFailures == 1 }
        try require(FileManager.default.fileExists(atPath: trash.appendingPathComponent(expired.lastPathComponent).path)
                    && FileManager.default.fileExists(atPath: trash.appendingPathComponent(movie.lastPathComponent).path),
                    "Expired screenshot and movie must go to Trash")
        for protected in [renamed, recent, other, outside, failing] {
            try require(FileManager.default.fileExists(atPath: protected.path), "Unexpected removal: \(protected.lastPathComponent)")
        }
        try require(library.pinnedIDs.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                    == [renamed.resolvingSymlinksInPath().path], "Renamed pin must survive restart and cleanup")
        library.start()
        try await wait("renamed pin visible after cleanup") {
            !library.scanning && library.sections.first?.items.map(\.name) == [renamed.lastPathComponent]
        }
        try require(ScreenshotLibrary(defaults: defaults).retention == .week, "Retention must persist")
        library.enabled = false
        let disabled = try fixture("Screenshot while disabled.png")
        library.retention = .day
        try await Task.sleep(for: .milliseconds(200))
        try require(FileManager.default.fileExists(atPath: disabled.path), "Disabled extension started cleanup")
        print("PASS screenshot retention: unlimited, cancellation, background trash, pin rename, ordinary media, scope, and permission failure")
    }

    @MainActor private static func verifyShelfIntegration() async throws {
        let identifier = "org.keylane.test.screenshot-shelf." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: identifier)!
        defer { defaults.removePersistentDomain(forName: identifier) }
        defaults.set(try JSONEncoder().encode([ScreenshotScope(path: root.path, bookmark: nil)]), forKey: "screenshotScopes")
        try writeImage(root.appendingPathComponent("Screenshot old.png"))
        let library = ScreenshotLibrary(defaults: defaults)
        var received: [URL] = []
        library.addToShelf = { received += $0; return true }
        library.autoShelf = true; library.enabled = true; library.start()
        try await wait("screenshot baseline") { !library.scanning && library.results.count == 1 }
        try require(received.isEmpty, "Existing captures must not auto-open shelves")
        library.stop() // Closing the page retains the SAME library watcher for opted-in delivery.
        try writeImage(root.appendingPathComponent("Screenshot new.png"))
        try await wait("background capture delivered") { received.count == 1 }
        try require(received[0].lastPathComponent == "Screenshot new.png", "Only the new capture should be delivered")
        try writeImage(root.appendingPathComponent("ordinary.png"))
        library.refresh()
        try await Task.sleep(for: .seconds(3))
        try require(received.count == 1, "Ordinary images and duplicate events must not create shelves")
        library.enabled = false
        try writeImage(root.appendingPathComponent("Screenshot disabled.png"))
        try await Task.sleep(for: .seconds(3))
        try require(received.count == 1, "Disabling screenshots must stop background delivery")
        print("PASS screenshot shelf integration: baseline, shared background watcher, new capture, dedupe, disable")
    }

    @MainActor private static func verifyUnavailableShelfScope() async throws {
        let suite = "org.keylane.test.shelf-scope." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        let offline = root.appendingPathComponent("offline")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([first, second].map { ScreenshotScope(path: $0.path, bookmark: nil) }), forKey: "screenshotScopes")
        try writeImage(first.appendingPathComponent("Screenshot first-old.png"))
        try writeImage(second.appendingPathComponent("Screenshot second-old.png"))
        let library = ScreenshotLibrary(defaults: defaults)
        defer { library.enabled = false }
        var received: [URL] = []
        library.addToShelf = { received += $0; return true }
        library.autoShelf = true; library.enabled = true; library.start()
        try await wait("two-scope baseline") { !library.scanning && library.results.count == 2 }
        // Rename only a synthetic directory to make one configured scope unavailable.
        try FileManager.default.moveItem(at: second, to: offline)
        library.refresh()
        try await wait("scope unavailable") { !library.scanning && library.unavailableScopePaths == [second.path] }
        try FileManager.default.moveItem(at: offline, to: second)
        library.refresh()
        try await wait("scope restored") { !library.scanning && library.unavailableScopePaths.isEmpty && library.results.count == 2 }
        try await Task.sleep(for: .seconds(3))
        try require(received.isEmpty, "Restoring an unavailable scope must not re-deliver its old files")
        try writeImage(second.appendingPathComponent("Screenshot truly-new.png"))
        try await wait("new capture after restoration") { received.count == 1 }
        try require(received[0].lastPathComponent == "Screenshot truly-new.png", "Only the newly created capture may be delivered")
        print("PASS screenshot unavailable scope preserves baseline and still delivers new captures")
    }

    @MainActor private static func wait(_ label: String = "", line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try require(condition(), "Timed out at line \(line): " + label)
    }

    private enum CheckError: Error { case failure(String) }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckError.failure(message) }
    }
}
