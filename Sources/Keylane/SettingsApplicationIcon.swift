import AppKit
import SwiftUI

/// A row only retains its icon while visible. The shared cache can reuse icons
/// when scrolling back or when the shortcut recorder opens.
struct SettingsApplicationIcon: View {
    let path: String
    @State private var loaded: (path: String, image: NSImage)?

    var body: some View {
        let cache = SettingsApplicationIcons.shared
        let image = loaded.flatMap { $0.path == path ? $0.image : nil } ?? cache.cachedImage(for: path)
        Group {
            if let image {
                Image(nsImage: image).resizable()
            } else {
                Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .task(id: path) {
            // Cached rows can display immediately without publishing another row update.
            guard image == nil, let image = await cache.image(for: path), !Task.isCancelled else { return }
            loaded = (path, image)
        }
        .onDisappear { loaded = nil }
    }
}

/// NSWorkspace's file icon lookup is thread-safe. Serial lookup keeps scrolling
/// through many cold rows from flooding the system icon service.
private final class SettingsApplicationIcons: @unchecked Sendable {
    static let shared = SettingsApplicationIcons()
    private let icons = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "org.keylane.settings.app-icons", qos: .userInitiated)

    private init() {
        icons.countLimit = 256
        icons.totalCostLimit = 256 * Self.thumbnailCost
    }

    private static let thumbnailPixels = 48
    private static let thumbnailCost = thumbnailPixels * thumbnailPixels * 4

    func cachedImage(for path: String) -> NSImage? {
        icons.object(forKey: path as NSString)
    }

    func image(for path: String) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let image = cachedImage(for: path) { return image }
        let request = IconLookup()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    guard !request.cancelled else { continuation.resume(returning: nil); return }
                    let key = path as NSString
                    let image = autoreleasepool {
                        if let cached = icons.object(forKey: key) { return cached }
                        let icon = NSWorkspace.shared.icon(forFile: path)
                        guard let thumbnail = Self.thumbnail(of: icon) else { return icon }
                        icons.setObject(thumbnail, forKey: key, cost: Self.thumbnailCost)
                        return thumbnail
                    }
                    continuation.resume(returning: request.cancelled ? nil : image)
                }
            }
        } onCancel: { request.cancel() }
    }

    private static func thumbnail(of icon: NSImage) -> NSImage? {
        let pixels = thumbnailPixels
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let size = NSSize(width: 24, height: 24)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = bitmap.cgImage else { return nil }
        return NSImage(cgImage: image, size: size)
    }
}

private final class IconLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func cancel() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
