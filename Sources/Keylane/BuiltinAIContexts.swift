import Foundation
import Combine
import KeylaneCore

/// Business modules supply these inert declarations at composition time.
enum BuiltinAIContexts {
    static func clipboard(_ model: Model) -> AIContextRegistration {
        .init(id: "clipboard-history", title: "剪贴板历史", symbol: "clipboard",
              available: { [weak model] in model?.clipboard.historyCommandEnabled == true },
              availabilityUpdates: model.clipboard.$historyCommandEnabled.eraseToAnyPublisher()) { [weak model] query in
            guard let controller = model?.clipboard else { throw AIActionError.unavailable }
            let items = await withCheckedContinuation { reply in
                controller.aiTextContexts(query: query) { reply.resume(returning: $0) }
            }
            return items.map { item in
                AIContextCandidate(id: item.id, title: item.preview, detail: item.source,
                                   source: ClipboardAIActions.source(id: item.id, controller: controller))
            }
        }
    }

    static func calendar(_ model: Model) -> AIContextRegistration {
        .init(id: "calendar", title: "日历日程", symbol: "calendar",
              available: { [weak model] in model?.calendar.enabled == true && model?.calendar.access == .allowed },
              availabilityUpdates: model.calendar.permission.$enabled.combineLatest(model.calendar.$access).map { $0 && $1 == .allowed }.eraseToAnyPublisher()) { [weak model] query in
            guard let controller = model?.calendar else { throw AIActionError.unavailable }
            var seen = Set<String>()
            return (controller.events + controller.upcoming).filter {
                seen.insert($0.id).inserted && (query.isEmpty || ($0.title + " " + $0.notes).localizedCaseInsensitiveContains(query))
            }.prefix(100).map { event in
                @MainActor func currentContext() throws -> AIActionContext {
                    guard let calendar = model?.calendar, calendar.enabled, calendar.access == .allowed,
                          let latest = (calendar.events + calendar.upcoming).first(where: { $0.id == event.id }) else {
                        throw AIActionError.unavailable
                    }
                    let text = "标题：\(latest.title)\n开始：\(latest.start.formatted())\n结束：\(latest.end.formatted())\n地点：\(latest.location)\n备注：\(latest.notes)"
                    return .init(sourceID: latest.id, title: latest.title, text: text)
                }
                return AIContextCandidate(id: event.id, title: event.title, detail: event.start.formatted(),
                    source: .init(moduleID: .init(rawValue: "keylane.calendar"), load: { try currentContext() }, isCurrent: { context in
                        try currentContext().fingerprint == context.fingerprint
                    }))
            }
        }
    }

    static func screenshots(_ model: Model) -> AIContextRegistration {
        .init(id: "screenshot-library", title: "截图文字", symbol: "viewfinder",
              available: { [weak model] in model?.screenshots.enabled == true },
              availabilityUpdates: model.screenshots.$enabled.eraseToAnyPublisher()) { [weak model] query in
            guard let library = model?.screenshots else { throw AIActionError.unavailable }
            return library.aiContextItems.filter { $0.kind == .image && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }.prefix(100).map { item in
                AIContextCandidate(id: item.id, title: item.name, detail: item.date.formatted(),
                                   source: ScreenshotAIActions.source(item, library: library))
            }
        }
    }
}
