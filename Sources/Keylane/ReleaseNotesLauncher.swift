import AppKit
import Combine
import KeylaneCore
import SwiftUI

final class ReleaseNotesLauncher: ObservableObject {
    static let listID = PageID(rawValue: "release-notes")
    private static let detailID = PageID(rawValue: "release-note-detail")
    private weak var model: Model?
    private let updates: KeylaneReleaseCheck
    @Published private var query = ""
    @Published private var selectedTag: String?
    @Published private var detail: GitHubUpdateRelease?

    init(model: Model) {
        self.model = model
        updates = model.updates
    }

    private var matches: [GitHubUpdateRelease] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (updates.releaseHistory ?? []).filter {
            search.isEmpty || $0.tag.localizedStandardContains(search)
                || ($0.title?.localizedStandardContains(search) ?? false)
        }
    }

    private var selected: GitHubUpdateRelease? {
        matches.first { $0.tag == selectedTag } ?? matches.first
    }

    var pages: [LauncherPage] {
        let changes = Publishers.MergeMany(
            ViewObservation.changes($selectedTag), ViewObservation.changes($query),
            ViewObservation.changes(updates.$releaseHistory)
        ).eraseToAnyPublisher()
        return [
            LauncherPage(id: Self.listID, placeholder: "按版本号或标题搜索…", badge: ("更新日志", "doc.text"),
                         contentPlacement: .underChrome, content: { AnyView(self.list) },
                         queryChanged: {
                             if self.query != $0 { self.query = $0; self.selectedTag = nil }
                         },
                         move: move, submit: { if let release = self.selected { self.show(release) } },
                         actionSelectionID: { self.selected?.tag }, primaryTitle: { "查看详情" }, primaryEnabled: { self.selected != nil },
                         actions: {
                             guard let release = self.selected else { return [] }
                             return [.init(id: "show-release-details", title: "查看详情", icon: "doc.text",
                                           perform: { self.show(release) })] + self.actions(for: release)
                         }, updates: changes),
            LauncherPage(id: Self.detailID, placeholder: "", badge: ("更新日志", "doc.text"),
                         contentPlacement: .readingDetail, content: { AnyView(self.detailView) },
                         leave: { self.detail = nil }, keepsStateWhenHidden: true, parent: Self.listID,
                         submit: { if let release = self.detail { self.open(release) } },
                         returnBindings: .init(primary: .plain), actionSelectionID: { self.detail?.tag }, primaryTitle: { "在浏览器中打开" }, primaryEnabled: { self.detail != nil },
                         actions: { self.actions(for: self.detail) }, badgeTitle: { self.detail?.tag ?? "更新日志" })
        ]
    }

    private func move(_ delta: Int) {
        let rows = matches
        guard let index = rows.firstIndex(where: { $0.tag == selected?.tag }),
              rows.indices.contains(index + delta) else { return }
        selectedTag = rows[index + delta].tag
    }

    private func show(_ release: GitHubUpdateRelease) {
        selectedTag = release.tag
        detail = release
        model?.pageID = Self.detailID
    }

    private func open(_ release: GitHubUpdateRelease) {
        NSWorkspace.shared.open(KeylaneReleaseCheck.releasesURL.appendingPathComponent("tag").appendingPathComponent(release.tag))
    }

    private func actions(for release: GitHubUpdateRelease?) -> [LauncherAction] {
        guard let release else { return [] }
        return [.init(id: "open-release-page", title: "在浏览器中打开", icon: "globe", perform: { self.open(release) })]
    }

    private var list: some View {
        ReleaseNotesList(controller: self, updates: updates)
    }

    private var detailView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail {
                Text(detail.title ?? detail.tag).font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let date = detail.publishedAt { Text(date, style: .date).foregroundStyle(.secondary) }
                ReleaseNotesBody(notes: detail.notes)
            }
        }
    }

    private struct ReleaseNotesList: View {
        @ObservedObject var controller: ReleaseNotesLauncher
        @ObservedObject var updates: KeylaneReleaseCheck
        @State private var retry = 0

        var body: some View {
            let rows = controller.matches
            Group {
                if !rows.isEmpty {
                    SelectableResultList(selection: controller.selected?.tag, query: controller.query,
                                         firstResult: rows.first?.tag, revealInitialSelection: true) {
                        ForEach(rows, id: \.tag) { release in
                            ResultListButton(id: release.tag, action: { controller.show(release) }) {
                                ResultListRow(selected: controller.selected?.tag == release.tag) {
                                    Image(systemName: "doc.text")
                                } content: {
                                    HStack {
                                        Text(release.tag).monospacedDigit().foregroundStyle(.secondary)
                                        HighlightedResultText(text: release.title ?? release.tag, query: controller.query)
                                            .lineLimit(1)
                                        Spacer()
                                        if let date = release.publishedAt {
                                            Text(date, style: .date).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if updates.releaseHistoryError && updates.releaseHistory == nil {
                    VStack(spacing: 10) {
                        Text("无法读取更新日志。").foregroundStyle(.secondary)
                        Button("重试") { retry += 1 }
                    }
                } else if updates.releaseHistory == nil {
                    ProgressView("正在读取更新日志…")
                } else {
                    Text(controller.query.isEmpty ? "暂无发布记录。" : "没有匹配的版本。")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: retry) {
                if updates.releaseHistory == nil { await updates.loadReleaseHistory() }
            }
        }
    }
}

struct ReleaseNotesBody: View {
    let notes: String?

    var body: some View {
        let body = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lines = body.isEmpty ? ["此版本未附更新说明。"] : body.components(separatedBy: .newlines)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Spacer().frame(height: 4)
                } else if line.hasPrefix("#"), let space = line.firstIndex(of: " "),
                          line[..<space].allSatisfy({ $0 == "#" }) {
                    formatted(String(line[line.index(after: space)...])).font(.headline)
                        .accessibilityAddTraits(.isHeader)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").foregroundStyle(.secondary)
                        formatted(String(line.dropFirst(2)))
                    }
                } else {
                    formatted(line)
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http"].contains(url.scheme?.lowercased()) ? .systemAction : .discarded
        })
    }

    private func formatted(_ line: String) -> Text {
        Text((try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(line))
    }
}
