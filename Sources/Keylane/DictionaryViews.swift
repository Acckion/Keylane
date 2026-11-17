import SwiftUI

struct DictionaryResultList: View {
    @ObservedObject var controller: DictionaryController

    var body: some View {
        if !controller.words.isEmpty {
            SelectableResultList(selection: controller.selectedID, firstResult: controller.words.first?.id,
                                 revealInitialSelection: true) {
                ResultListSection(title: "结果", isFirst: true) {
                    ForEach(controller.words) { word in
                        ResultListButton(id: word.id, action: { controller.select(word.id) }) {
                            HStack(spacing: 8) {
                                HighlightedResultText(text: word.word, query: controller.term)
                                    .font(VisualStyle.rowText.weight(.semibold)).lineLimit(1).layoutPriority(1)
                                Text(word.preview).font(VisualStyle.rowText).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                            .background(.primary.opacity(controller.selectedID == word.id ? 0.10 : 0),
                                        in: RoundedRectangle(cornerRadius: VisualStyle.selectionRadius))
                            .contentShape(Rectangle())
                            .accessibilityAddTraits(controller.selectedID == word.id ? .isSelected : [])
                        }
                    }
                }
            }
        } else {
            VStack {
                if controller.loading {
                    Text("正在查询…").foregroundStyle(.secondary)
                } else if controller.termTooLong {
                    ContentUnavailableView("查询内容太长", systemImage: "book.closed", description: Text("请输入较短的词语或短语。"))
                } else if controller.term.isEmpty {
                    ContentUnavailableView("输入要查找的词语", systemImage: "book.closed")
                } else {
                    ContentUnavailableView("没有找到释义", systemImage: "book.closed", description: Text("试试其他拼写，或检查系统词典中已启用的词库。"))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class DictionaryDetailOptions: ObservableObject {
    @Published var source = "all"
}

struct DictionarySourceFilter: View {
    let word: DictionaryWord?
    @ObservedObject var options: DictionaryDetailOptions
    @Binding var isOpen: Bool
    let navigation: String

    var body: some View {
        var seen: Set<String> = []
        let sources = (word?.entries ?? []).compactMap { entry in
            seen.insert(entry.sourceID).inserted
                ? ResultFilterOption(id: entry.sourceID, title: entry.source, symbol: "textformat")
                : nil
        }
        return ResultTypeFilter(selection: $options.source,
                                options: [.init(id: "all", title: "全部词库", symbol: "list.bullet")] + sources,
                                open: $isOpen, navigation: navigation, width: 174,
                                searchPlaceholder: "搜索词库…", emptyTitle: "没有匹配词库")
    }
}

struct DictionaryEntryDetail: View {
    let word: DictionaryWord?
    @ObservedObject var options: DictionaryDetailOptions
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let word {
                    let sources = word.entries.filter { options.source == "all" || options.source == $0.sourceID }
                    let groups = Dictionary(grouping: sources, by: \.sourceID)
                    var seen: Set<String> = []
                    let ordered = sources.filter { seen.insert($0.sourceID).inserted }
                    ForEach(ordered) { source in
                        sourceBlock(source, entries: groups[source.sourceID, default: []], word: word.word)
                    }
                }
            }.padding(.horizontal, 32).padding(.vertical, 7)
        }
        .launcherScrollInsets()
        .launcherScrollEdgeFade()
        .id(options.source)
        .onChange(of: options.source) { _, value in collapsed.remove(value) }
    }

    private func sourceBlock(_ source: DictionaryEntry, entries: [DictionaryEntry], word: String) -> some View {
        let open = !collapsed.contains(source.sourceID)
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                if open { collapsed.insert(source.sourceID) }
                else { collapsed.remove(source.sourceID) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Rectangle().frame(height: 1).opacity(0.45)
                    Text(source.source).font(.system(size: 16, weight: .medium)).lineLimit(1)
                    Rectangle().frame(height: 1).opacity(0.45)
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(open ? "已展开" : "已折叠")
            if open {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        if !entry.paragraphs.contains(where: { $0.contains { $0.style == .heading } }) {
                            Text(word).font(.system(size: 24, weight: .semibold, design: .serif))
                        }
                        ForEach(entry.paragraphs.indices, id: \.self) { index in
                            paragraph(entry.paragraphs[index], first: index == 0)
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func paragraph(_ words: [DictionaryEntry.Run], first: Bool) -> Text {
        let baseFont = Font.system(size: first ? 18 : 15, design: .serif)
        var formatted = AttributedString()
        for word in words {
            var run = AttributedString(word.text)
            switch word.style {
            case .heading: run.font = .system(size: first ? 24 : 15, weight: .semibold, design: .serif)
            case .secondary:
                run.font = baseFont
                run.foregroundColor = .secondary
            case .example:
                run.font = baseFont.italic()
                run.foregroundColor = .secondary
            case .regular: run.font = baseFont
            }
            formatted.append(run)
        }
        return Text(formatted)
    }
}
