import SwiftUI

/// A Launcher conversation supplies its title, messages and composer.
/// Window geometry, material and activation remain owned by the Launcher.
struct ConversationLayout<Content: View, Composer: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    let isEmpty: Bool
    var contextPreview: String? = nil
    var emptyTitle = "随时提问"
    var emptyDescription = "直接在启动器中向 AI 提问。"
    var composerInset: CGFloat = VisualStyle.launcherBottomInset
    let back: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let composer: () -> Composer
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ZStack {
            if isEmpty {
                VStack(spacing: 10) {
                    Text(emptyTitle).font(.system(size: 26, weight: .semibold))
                    Text(emptyDescription).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, VisualStyle.launcherTopInset)
                .padding(.bottom, composerInset)
            } else {
                content()
            }

            VStack(spacing: 0) {
                ChromeBlur().frame(height: VisualStyle.launcherTopInset)
                    .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                Spacer(minLength: 0)
                ChromeBlur().frame(height: composerInset + 22)
                    .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            }.allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    LauncherBackButton(action: back)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        if let contextPreview, !contextPreview.isEmpty {
                            Text(contextPreview).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    trailing()
                }
                .padding(.horizontal, VisualStyle.launcherEdgeInset)
                .frame(height: VisualStyle.launcherTopInset)
                Spacer(minLength: 0)
                composer()
                    .padding(.horizontal, VisualStyle.launcherEdgeInset)
                    .padding(.bottom, VisualStyle.launcherEdgeInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationComposer<Leading: View, Input: View, Trailing: View>: View {
    var inputHeight: CGFloat = VisualStyle.launcherControlDiameter
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let input: () -> Input
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            leading().frame(width: VisualStyle.launcherControlDiameter, height: VisualStyle.launcherControlDiameter)
            input()
                .padding(.horizontal, 14)
                .frame(height: inputHeight)
                .modifier(LauncherMenuSurface(open: false))
            trailing().frame(width: VisualStyle.launcherControlDiameter, height: VisualStyle.launcherControlDiameter)
        }
    }
}


private struct ConversationInputEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct ConversationInputFocusTokenKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var conversationInputEnabled: Bool {
        get { self[ConversationInputEnabledKey.self] }
        set { self[ConversationInputEnabledKey.self] = newValue }
    }

    var conversationInputFocusToken: Int {
        get { self[ConversationInputFocusTokenKey.self] }
        set { self[ConversationInputFocusTokenKey.self] = newValue }
    }
}
