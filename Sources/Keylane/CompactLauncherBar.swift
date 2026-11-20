import SwiftUI
import KeylaneCore

enum CompactLauncherShortcut: String, CaseIterable {
    case files = "file-search"
    case snippets = "search-snippets"
    case clipboard

    var id: CommandID { CommandID(rawValue: rawValue) }
    var title: String {
        switch self {
        case .files: "搜索文件"
        case .snippets: "搜索文字片段"
        case .clipboard: "剪贴板历史"
        }
    }
    var symbol: String {
        switch self {
        case .files: "folder"
        case .snippets: "text.badge.plus"
        case .clipboard: "clipboard"
        }
    }
}

enum CompactLauncherButtonGeometry {
    static let diameter = VisualStyle.launcherTopInset
    static let pitch = diameter + 8

    static func offset(for index: Int) -> CGFloat {
        VisualStyle.launcherWidth - diameter - CGFloat(CompactLauncherShortcut.allCases.count - 1 - index) * pitch
    }

    static func shortcut(at point: CGPoint) -> CompactLauncherShortcut? {
        let radius = diameter / 2
        return CompactLauncherShortcut.allCases.enumerated().first { index, _ in
            let x = point.x - (offset(for: index) + radius)
            let y = point.y - radius
            return x * x + y * y <= radius * radius
        }?.element
    }
}

/// Keeps the text editor mounted while the search surface joins or separates from its shortcuts.
struct CompactLauncherBar<Search: View>: View, Animatable {
    let model: Model
    var separation: CGFloat
    let interactive: Bool
    let glassOpacity: CGFloat
    @ViewBuilder let search: () -> Search
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var animatableData: CGFloat {
        get { separation }
        set { separation = newValue }
    }

    var body: some View {
        let shortcuts = CompactLauncherShortcut.allCases
        let progress = range(separation, from: 0, to: 1)
        let diameter = CompactLauncherButtonGeometry.diameter
        let pitch = CompactLauncherButtonGeometry.pitch
        let width = VisualStyle.launcherWidth
        let searchWidth = width - CGFloat(shortcuts.count) * pitch * progress

        let buttons = shortcuts.enumerated().map { index, shortcut in
            let delay = CGFloat(index) * 0.12
            let travel = range(progress, from: 0.12 + delay, to: 0.82 + delay / 2)
            let target = CompactLauncherButtonGeometry.offset(for: index)
            let origin = min(width - diameter, searchWidth - diameter * 0.65)
            return ButtonLayout(
                id: shortcut.id, title: shortcut.title, symbol: shortcut.symbol,
                offset: origin + (target - origin) * travel, scale: 0.24 + 0.76 * travel,
                opacity: interactive
                    ? range(progress, from: 0.08 + delay, to: 0.25 + delay)
                    : range(progress, from: 0.39 + delay / 2, to: 0.72 + delay / 2),
                glyphOpacity: range(progress, from: 0.68 + delay / 2, to: 1)
            )
        }

        ZStack(alignment: .topLeading) {
            // Glass samples the backdrop. Keep the text editor and glyphs out
            // of its compositing pass so the placeholder and caret stay crisp.
            GlassEffectContainer(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if glassOpacity > 0 {
                        Capsule()
                            .fill(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear)
                            .frame(width: searchWidth, height: diameter)
                            .glassEffect(reduceTransparency ? .identity : LauncherGlassMaterial.swiftUI, in: Capsule())
                            .opacity(glassOpacity)
                    }
                    if progress > 0 {
                        ForEach(buttons) { button in
                            Circle()
                                .fill(reduceTransparency ? Color(nsColor: .windowBackgroundColor) : .clear)
                                .frame(width: diameter, height: diameter)
                                .glassEffect(reduceTransparency ? .identity : LauncherGlassMaterial.swiftUI, in: Circle())
                                .scaleEffect(button.scale)
                                .opacity(button.opacity)
                                .offset(x: button.offset)
                        }
                    }
                }
                .frame(width: width, height: diameter, alignment: .topLeading)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            search().frame(width: searchWidth)

            if progress > 0 {
                ForEach(buttons) { button in
                    Button {
                        model.runCommand(button.id, origin: .search, usageKey: button.id.rawValue)
                    } label: {
                        Circle()
                            .fill(Color.primary.opacity(0.035))
                            .frame(width: diameter, height: diameter)
                            .overlay {
                                Image(systemName: button.symbol)
                                    .font(.system(size: 20, weight: .medium))
                                    .opacity(button.glyphOpacity)
                                    .blur(radius: 5 * (1 - button.glyphOpacity))
                                    .allowsHitTesting(false)
                            }
                            .contentShape(.interaction, Circle())
                    }
                    .buttonStyle(.plain)
                    .help(button.title)
                    .accessibilityLabel(button.title)
                    .scaleEffect(button.scale)
                    .opacity(button.opacity)
                    .offset(x: button.offset)
                    .disabled(model.launcherModules?.isRegisteredCommandEnabled(button.id) == false)
                    .allowsHitTesting(interactive)
                    .accessibilityHidden(!interactive)
                }
            }
        }
        .frame(width: width, height: diameter, alignment: .topLeading)
    }

    private struct ButtonLayout: Identifiable {
        let id: CommandID
        let title: String
        let symbol: String
        let offset: CGFloat
        let scale: CGFloat
        let opacity: CGFloat
        let glyphOpacity: CGFloat
    }

    private func range(_ value: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        min(1, max(0, (value - start) / (end - start)))
    }
}
