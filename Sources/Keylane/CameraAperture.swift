import SwiftUI

struct CameraAperture: View {
    let ready: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var openedAt: Date?
    @State private var finished = false
    private let openDuration = 0.45

    var body: some View {
        Group {
            if !finished && !(ready && reduceMotion) {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                    let elapsed = openedAt.map { timeline.date.timeIntervalSince($0) } ?? 0
                    let fraction = min(1, max(0, elapsed / openDuration))
                    Blades(progress: fraction * fraction * (3 - 2 * fraction),
                           phase: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * 3)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在打开相机")
        .accessibilityHidden(ready)
        .task(id: ready) {
            guard ready else { return }
            openedAt = .now
            try? await Task.sleep(for: .seconds(openDuration))
            guard !Task.isCancelled else { return }
            finished = true
        }
    }

    private struct Blades: View {
        let progress: Double
        let phase: Double

        var body: some View {
            Canvas { context, size in
                let count = 8
                let step = 2 * Double.pi / Double(count)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let diagonal = hypot(size.width, size.height)
                let radius = 4 + progress * (diagonal / (2 * cos(step / 2)) + 2)
                let length = diagonal * 3
                let angles = (0..<count).map { Double($0) * step + step / 2 }
                let inner = angles.map { angle in
                    CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                }
                // Each seam extends a side of the octagonal opening.
                let outer = zip(inner, angles).map { point, angle in
                    let tangent = angle + .pi / 2 - step / 2
                    return CGPoint(x: point.x + length * cos(tangent), y: point.y + length * sin(tangent))
                }
                for index in 0..<count {
                    let next = (index + 1) % count
                    var blade = Path()
                    blade.move(to: inner[index])
                    blade.addLine(to: outer[index])
                    blade.addLine(to: outer[next])
                    blade.addLine(to: inner[next])
                    blade.closeSubpath()
                    let shade = 0.14 + 0.012 * sin(phase + angles[index])
                    context.fill(blade, with: .color(Color(white: shade)))
                    context.stroke(blade, with: .color(.black.opacity(0.85)), lineWidth: 1.5)
                }
            }
        }
    }
}
