import AppKit
import KeylaneCore
import SwiftUI

extension ThemeRGBA {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    var swiftUI: Color { Color(nsColor: nsColor) }
}
private struct KeylaneThemeKey: EnvironmentKey { static let defaultValue: ThemeDefinition? = nil }
extension EnvironmentValues {
    var keylaneTheme: ThemeDefinition? { get { self[KeylaneThemeKey.self] } set { self[KeylaneThemeKey.self] = newValue } }
}

/// Semantic styles resolve in the view environment, including isolated Studio previews.
struct ThemeColorStyle: ShapeStyle {
    let role: ThemeColorRole
    func resolve(in environment: EnvironmentValues) -> Color {
        guard let theme = environment.keylaneTheme, !theme.usesSystemMaterial else {
            switch role {
            case .text: return .primary
            case .selection, .loader: return .accentColor
            case .red: return .red; case .orange: return .orange; case .yellow: return .yellow
            case .green: return .green; case .blue: return .blue; case .purple: return .purple; case .magenta: return .pink
            }
        }
        return theme.color(role).swiftUI
    }
    static let text = Self(role: .text)
    static let selection = Self(role: .selection)
    static let loader = Self(role: .loader)
}

struct ThemeSelectionStyle: ShapeStyle {
    let normalOpacity: Double
    let increasedOpacity: Double
    func resolve(in environment: EnvironmentValues) -> Color {
        if let theme = environment.keylaneTheme, !theme.usesSystemMaterial {
            return theme.color(.selection).swiftUI.opacity(environment.colorSchemeContrast == .increased ? 0.5 : 0.18)
        }
        return Color.primary.opacity(environment.colorSchemeContrast == .increased ? increasedOpacity : normalOpacity)
    }
}

struct ThemeBackgroundView: View {
    let theme: ThemeDefinition
    var body: some View {
        let first = (try? ThemeRGBA(theme.background.color))?.swiftUI ?? .clear
        let last = (try? ThemeRGBA(theme.background.endColor))?.swiftUI ?? first
        let radians = (theme.background.angle.isFinite ? theme.background.angle : 0) * .pi / 180
        let x = cos(radians) * 0.5; let y = sin(radians) * 0.5
        if theme.background.kind == .gradient {
            LinearGradient(colors: [first, last], startPoint: .init(x: 0.5 - x, y: 0.5 - y), endPoint: .init(x: 0.5 + x, y: 0.5 + y))
        } else { first }
    }
}

private struct KeylaneThemeModifier: ViewModifier {
    @ObservedObject var store: ThemeStore
    let backgroundOpacity: CGFloat
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let theme = store.library.theme(for: scheme == .dark ? .dark : .light)
        content.environment(\.keylaneTheme, theme)
            .foregroundStyle(theme.usesSystemMaterial ? Color.primary : theme.color(.text).swiftUI)
            .tint(theme.usesSystemMaterial ? Color.accentColor : theme.color(.selection).swiftUI)
            .background {
                if !theme.usesSystemMaterial {
                    ThemeBackgroundView(theme: theme).opacity(backgroundOpacity)
                }
            }
    }
}
extension View {
    func keylaneTheme(store: ThemeStore = .shared, backgroundOpacity: CGFloat = 1) -> some View {
        modifier(KeylaneThemeModifier(store: store, backgroundOpacity: backgroundOpacity))
    }
}
