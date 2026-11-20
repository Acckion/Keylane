import AppKit

/// Original, deterministic grayscale sample sculptures; no third-party image assets.
enum ThemePreviewArtwork {
    private static let cache = NSCache<NSNumber, NSImage>()
    static func image(_ variant: Int) -> NSImage {
        if let image = cache.object(forKey: NSNumber(value: variant)) { return image }
        let image = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSGradient(starting: NSColor(white: 0.19, alpha: 1), ending: NSColor(white: 0.055, alpha: 1))?.draw(in: rect, angle: 120)
            for layer in (0..<58).reversed() {
                let depth = Double(layer) / 57
                let path = NSBezierPath()
                let radius = 115 + 47 * sin(depth * .pi)
                let phase = depth * (1.8 + Double(variant) * 0.45)
                let frequency = Double([5, 7, 4, 6, 5][variant % 5])
                for step in 0...128 {
                    let angle = Double(step) / 128 * 2 * Double.pi
                    let ripple = 1 + 0.19 * sin(frequency * angle + phase) + 0.07 * cos(3 * angle - phase * 2)
                    let x = 256 + cos(angle) * radius * ripple + 14 * sin(phase)
                    let y = 160 + depth * 205 + sin(angle) * radius * ripple * 0.55
                    if step == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
                }
                path.close()
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.38); shadow.shadowBlurRadius = 11; shadow.shadowOffset = NSSize(width: 5, height: -7); shadow.set()
                NSGradient(starting: NSColor(white: 0.28 + depth * 0.07, alpha: 1), ending: NSColor(white: 0.035 + depth * 0.025, alpha: 1))?.draw(in: path, angle: 35 + Double(variant) * 18)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.white.withAlphaComponent(0.055).setStroke(); path.lineWidth = 0.75; path.stroke()
            }
            return true
        }
        cache.setObject(image, forKey: NSNumber(value: variant)); return image
    }
    static let badge: NSImage = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
        NSColor(white: 0.08, alpha: 1).setFill(); NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
        let colors: [NSColor] = [.systemBlue, .systemPurple, .systemPink, .systemGreen, .systemTeal, .systemYellow]
        for index in 0..<6 {
            let angle = Double(index) / 6 * .pi * 2
            colors[index].setFill(); NSBezierPath(ovalIn: NSRect(x: 25 + cos(angle) * 17, y: 25 + sin(angle) * 17, width: 14, height: 14)).fill()
        }
        return true
    }
}
