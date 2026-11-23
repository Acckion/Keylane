import AppKit
import KeylaneCore
let roles: [ResourceCaches.Role] = [.artwork, .workspace, .clipboard, .screenshots, .shelf, .theme, .screenshotText, .linkPreview, .linkIcons]
ResourceCaches.setBackground(false)
let caches = roles.map { ResourceCache<NSNumber, NSImage>($0) }
let cost = 256 * 256 * 4
func image() -> NSImage {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    memset(bitmap.bitmapData!, 0x7f, cost)
    return NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 128, height: 128))
}
for cache in caches {
    for i in 0..<64 { autoreleasepool { cache.setObject(image(), forKey: NSNumber(value: i), cost: cost) } }
}
let foreground = caches.reduce(0) { $0 + $1.retainedCost }
precondition(foreground == 35 * 1024 * 1024)
let visible = caches[3].object(forKey: 63)!
ResourceCaches.setBackground(true)
let background = caches.reduce(0) { $0 + $1.retainedCost }
precondition(background <= 256 * 1024)
DispatchQueue.concurrentPerform(iterations: 100) { i in
    for cache in caches { cache.setObject(visible, forKey: NSNumber(value: i), cost: cost) }
}
precondition(caches.reduce(0) { $0 + $1.retainedCost } <= 256 * 1024)
precondition(visible.size == NSSize(width: 128, height: 128))
ResourceCaches.setBackground(false)
caches[3].setObject(visible, forKey: 200, cost: cost)
precondition(caches[3].object(forKey: 200) === visible)
print("PASS 9 registered retention caches: foreground=\(foreground) bytes background=\(background) bytes; late workers cannot refill disabled stores; visible borrowed image and foreground reuse remain valid")

let anotherWindow = ResourceCache<NSNumber, NSImage>(.screenshots)
for i in 0..<64 {
    caches[3].setObject(visible, forKey: NSNumber(value: i), cost: cost)
    anotherWindow.setObject(visible, forKey: NSNumber(value: i), cost: cost)
}
precondition(caches[3].retainedCost + anotherWindow.retainedCost <= 8 * 1024 * 1024)
print("PASS multiple instances share a role budget rather than multiplying its memory limit")
