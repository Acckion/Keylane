import SwiftUI
import Foundation
import KeylaneCore

/// A compact summary expands into transport-reported steps and their details.
struct AIResponseProgressView: View {
    let progress: AIResponseProgress
    @State private var expanded = false
    @State private var openSteps: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(progress: AIResponseProgress, initiallyExpanded: Bool = false, openSteps: Set<String> = []) {
        self.progress = progress
        _expanded = State(initialValue: initiallyExpanded)
        _openSteps = State(initialValue: openSteps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if progress.activities.isEmpty {
                summaryLabel.accessibilityElement(children: .combine)
            } else {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded.toggle() }
                } label: { summaryLabel }
                .buttonStyle(.plain)
                .accessibilityLabel(progress.title)
                .accessibilityValue(expanded ? "已展开" : "已收起")
            }
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(progress.activities) { step in
                        stepRow(step)
                    }
                }
                .padding(.leading, 7)
                .background(alignment: .leading) {
                    Rectangle().fill(.primary.opacity(0.07)).frame(width: 1).padding(.leading, 14)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: progress.active) { _, active in
            if !active { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { expanded = false } }
        }
    }

    private var summaryLabel: some View {
        HStack(spacing: 7) {
            ZStack {
                if progress.activities.contains(where: { $0.kind == .tool }) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.blue)
                        .offset(x: 3, y: -1)
                }
                Image(systemName: progress.hasThinking ? "lightbulb.fill" : "sparkle")
                    .foregroundStyle(progress.hasThinking ? .yellow : .secondary)
                    .offset(x: progress.activities.contains(where: { $0.kind == .tool }) ? -3 : 0)
            }.font(.system(size: 12)).frame(width: 20, height: 20)
                .symbolEffect(.pulse, options: .repeating, isActive: progress.active && !reduceMotion)
            Text(progress.title).font(.system(size: 13))
            if !progress.activities.isEmpty {
                Text("\(progress.activities.count)").font(.system(size: 10, weight: .medium, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.primary.opacity(0.08), in: Capsule())
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }.foregroundStyle(.secondary).contentShape(Rectangle())
    }

    private func stepRow(_ step: AIResponseProgress.Activity) -> some View {
        let hasDetails = !step.text.isEmpty || !step.arguments.isEmpty
        let open = openSteps.contains(step.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.14)) {
                    if open { openSteps.remove(step.id) } else { openSteps.insert(step.id) }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: symbol(step)).font(.system(size: 11))
                        .foregroundStyle(step.kind == .thinking ? Color.yellow : Color.blue)
                        .frame(width: 16, height: 18)
                    Text(step.title).font(.system(size: 12)).lineLimit(2)
                    if hasDetails {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .medium))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    if step.state == .running {
                        Image(systemName: "circle.dotted").font(.system(size: 10))
                            .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
                            .frame(width: 12, height: 12)
                    } else if let status = stateTitle(step.state) {
                        Text(status).font(.system(size: 10)).foregroundStyle(step.state == .failed || step.state == .notExecuted ? Color.red : Color.secondary)
                    }
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!hasDetails)
            .accessibilityValue(stateTitle(step.state) ?? (step.state == .running ? "进行中" : "已完成"))
            if open && hasDetails {
                VStack(alignment: .leading, spacing: 7) {
                    if !step.text.isEmpty { Text(step.text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let data = step.arguments.data(using: .utf8),
                       let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        ForEach(fields.keys.sorted(), id: \.self) { key in
                            HStack(alignment: .top, spacing: 16) {
                                Text(key).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                                Text(fieldValue(fields[key])).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }.font(.system(size: 11)).padding(.vertical, 4)
                            if key != fields.keys.sorted().last { Divider().opacity(0.4) }
                        }
                    } else if !step.arguments.isEmpty {
                        Text(step.arguments).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.08)).frame(width: 1) }
                .padding(.leading, 25)
            }
        }
    }

    private func stateTitle(_ state: AIResponseProgress.Activity.State) -> String? {
        switch state {
        case .requested: "等待执行"
        case .notExecuted: "未执行"
        case .unconfirmed: "状态未确认"
        case .failed: "失败"
        case .cancelled: "已停止"
        default: nil
        }
    }
    private func symbol(_ step: AIResponseProgress.Activity) -> String {
        if step.kind == .thinking { return "lightbulb.fill" }
        if step.title.localizedCaseInsensitiveContains("search") || step.title.contains("搜索") { return "magnifyingglass" }
        if step.title.localizedCaseInsensitiveContains("read") || step.title.contains("读取") { return "doc.text" }
        return "wrench.and.screwdriver"
    }
    private func fieldValue(_ value: Any?) -> String {
        guard let value else { return "—" }
        if let value = value as? String { return value }
        if value is NSNull { return "—" }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { return text }
        return "—"
    }
}
