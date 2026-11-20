import AppKit
import SwiftUI
import KeylaneCore

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

/// Shared C material for the compact bar and floating panels.
enum LauncherGlassMaterial {
    static var tintColor: NSColor { NSColor.gray.withAlphaComponent(0.12) }
    static var swiftUI: Glass { .regular.tint(Color(nsColor: tintColor)) }
}

/// Shared backing for floating Keylane panels. Keep glass at the window's root
/// so AppKit composites it as the window material.
final class LauncherGlassView: NSGlassEffectView {
    private var themeObserver: NSObjectProtocol?
    private func updateTheme() {
        let theme = ThemeStore.shared.theme(for: effectiveAppearance)
        tintColor = theme.usesSystemMaterial ? LauncherGlassMaterial.tintColor
            : (try? KeylaneCore.ThemeRGBA(theme.background.color))?.nsColor.withAlphaComponent(0.16)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTheme() }
    deinit { if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        style = .regular
        updateTheme()
        themeObserver = NotificationCenter.default.addObserver(forName: .keylaneThemeChanged, object: ThemeStore.shared, queue: .main) { [weak self] _ in self?.updateTheme() }
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

/// Overlay content may be clipped, but the material's optical rim must not be
/// clipped by an enclosing layer. Compact and expanded Launcher share this host.
final class LauncherGlassHostView: NSView {
    let glass = LauncherGlassView(frame: .zero)

    init(content: NSView) {
        super.init(frame: .zero)
        // The glass owns its rounded shape; an additional rounded parent mask
        // cuts off the system's edge highlight at the same boundary.
        wantsLayer = true
        layer?.masksToBounds = false
        let contentClip = NSView()
        contentClip.wantsLayer = true
        contentClip.layer?.cornerRadius = VisualStyle.launcherCornerRadius
        contentClip.layer?.cornerCurve = .continuous
        contentClip.layer?.masksToBounds = true
        addSubview(glass)
        addSubview(contentClip)
        contentClip.addSubview(content)
        for (child, parent) in [(glass as NSView, self), (contentClip, self), (content, contentClip)] {
            child.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                child.topAnchor.constraint(equalTo: parent.topAnchor),
                child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
