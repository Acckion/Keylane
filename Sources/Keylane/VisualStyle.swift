import AppKit
import SwiftUI

/// Shared typography and symbol metrics for navigation and action rows.
enum VisualStyle {
    // The 36pt circular controls and capsules share a center with the 28pt window corner:
    // 28pt outer radius - 18pt control radius = 10pt inset.
    static let launcherCornerRadius: CGFloat = 28
    static let launcherControlDiameter: CGFloat = 36
    static let launcherWidth: CGFloat = 760
    static let launcherEdgeInset: CGFloat = 10
    static let launcherTopInset: CGFloat = 61
    static let launcherBottomInset: CGFloat = 52
    static let rowText = Font.system(size: 14, weight: .regular)
    static let actionSymbol = Font.system(size: 15, weight: .regular)
    static let sectionText = Font.system(size: 12, weight: .medium)
    static let actionIconWidth: CGFloat = 18
    static let actionSpacing: CGFloat = 9
    static let selectionRadius: CGFloat = 10
}

/// Shared backing for floating Keylane panels. Keep glass at the window's root
/// so AppKit composites it as the window material.
final class LauncherGlassView: NSGlassEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        style = .regular
        cornerRadius = VisualStyle.launcherCornerRadius
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        if #available(macOS 27.0, *), responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
            setValue(false, forKey: "effectIsInteractive")
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
