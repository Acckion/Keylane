import Combine
import SwiftUI
import KeylaneCore

final class CalculatorHistory: ObservableObject {
    struct Record: Codable, Identifiable, Equatable {
        let id: UUID
        let expression: String
        let answer: String
        let date: Date
    }

    private let defaults: UserDefaults
    private let key = "calculatorHistory"
    @Published private(set) var records: [Record] = []
    @Published private(set) var selection: UUID?
    @Published private(set) var query = ""
    private var loaded = false

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func record(expression: String, answer: String, now: Date = .now) {
        let expression = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, !answer.isEmpty, expression.utf16.count <= 512, answer.utf16.count <= 2048 else { return }
        load(now: now)
        if records.first?.expression == expression, records.first?.answer == answer { return }
        records.insert(Record(id: UUID(), expression: expression, answer: answer, date: now), at: 0)
        records = Array(records.prefix(1000))
        save()
    }

    func load(now: Date = .now) {
        if !loaded {
            loaded = true
            records = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        }
        let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: now) ?? now
        let retained = records.filter { $0.date >= cutoff }
        if records != retained {
            records = retained
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: key) }
    }

    var visible: [Record] {
        records.filter { query.isEmpty || $0.expression.localizedCaseInsensitiveContains(query) || $0.answer.localizedCaseInsensitiveContains(query) }
    }

    private func filter(_ text: String) {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id }
    }

    private func move(_ delta: Int) {
        let items = visible
        guard !items.isEmpty else { return }
        let index = items.firstIndex(where: { $0.id == selection }) ?? 0
        selection = items[NavigationBounds.move(index, by: delta, count: items.count)].id
    }

    private func copy(_ record: Record) {
        selection = record.id
        UtilityActions.copy(record.answer, feedback: "已复制计算结果")
    }

    func page(id: PageID) -> LauncherPage {
        LauncherPage(id: id, placeholder: "搜索计算历史…", badge: ("计算器历史", "clock.arrow.circlepath"),
                     contentPlacement: .underChrome, content: { AnyView(CalculatorHistoryView(history: self)) },
                     queryChanged: filter, move: move, submit: {
            if let record = self.visible.first(where: { $0.id == self.selection }) { self.copy(record) }
        }, primaryTitle: { "复制结果" }, primaryEnabled: { self.selection != nil },
                     updates: objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                     enter: { _ in self.load(); self.filter(""); return nil })
    }

    private struct CalculatorHistoryView: View {
        @ObservedObject var history: CalculatorHistory
        var body: some View {
            SelectableResultList(selection: history.selection, firstResult: history.visible.first?.id) {
                if history.visible.isEmpty {
                    Text(history.query.isEmpty ? "暂无计算历史" : "没有匹配的计算")
                        .foregroundStyle(.secondary).padding(20)
                }
                ForEach(history.visible) { record in
                    ResultListButton(id: record.id, action: { history.copy(record) }) {
                        ResultListRow(selected: history.selection == record.id) {
                            Image(systemName: "equal")
                        } content: {
                            HStack {
                                Text(record.expression).lineLimit(1)
                                Spacer()
                                Text(record.answer).monospacedDigit().lineLimit(1)
                            }
                            .font(VisualStyle.rowText)
                        }
                    }
                }
            }
        }
    }
}
