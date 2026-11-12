import Combine
import SwiftUI

/// A window-edge activity indicator driven by a page's loading state.
struct LauncherLoadingIndicator: View {
    let loading: AnyPublisher<Bool, Never>

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt: Date?

    var body: some View {
        ZStack {
            if let startedAt {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let streakWidth = min(width * 0.3, 190)
                    if reduceMotion {
                        streak(width: streakWidth)
                            .offset(x: (width - streakWidth) / 2)
                    } else {
                        TimelineView(.animation) { context in
                            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                            let phase = elapsed.truncatingRemainder(dividingBy: 0.85) / 0.85
                            streak(width: streakWidth)
                                .offset(x: -streakWidth + (width + streakWidth) * phase)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("正在加载")
            }
        }
        .frame(height: 9)
        .clipped()
        .allowsHitTesting(false)
        .onReceive(loading) { active in
            if active {
                if startedAt == nil { startedAt = .now }
            } else {
                startedAt = nil
            }
        }
    }

    private func streak(width: CGFloat) -> some View {
        let light = LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .blue.opacity(0.75), location: 0.46),
            .init(color: .cyan, location: 0.72),
            .init(color: .white, location: 0.88),
            .init(color: .clear, location: 1)
        ], startPoint: .leading, endPoint: .trailing)

        return Rectangle()
            .fill(light)
            .frame(width: width, height: 2)
            .background {
                Rectangle()
                    .fill(light)
                    .frame(height: 5)
                    .blur(radius: 3)
                    .offset(y: 1)
            }
    }
}
