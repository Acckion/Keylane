import Foundation

/// Presentation-only protocol for the first no-view Store capability.
/// It never forwards guest actions, navigation, or callback data.
package struct RaycastStoreToastState {
    package enum Failure: Error { case denied }
    package enum Style: String, Decodable, Sendable { case success = "SUCCESS", failure = "FAILURE", animated = "ANIMATED" }
    package struct Presentation: Equatable, Sendable {
        package let title: String
        package let message: String?
        package let style: Style
    }
    private struct Event: Decodable {
        enum Operation: String, Decodable { case show, update }
        let operation: Operation
        let id: Int
        let title: String
        let message: String?
        let style: Style
    }
    private var owner: UUID?
    private var lastIDs: [UUID: Int] = [:]

    package init() {}

    package mutating func apply(_ input: String, from ticket: UUID) throws -> Presentation {
        let allowed: Set<String> = ["operation", "id", "title", "message", "style"]
        guard input.utf8.count <= 16_384, !input.contains("\r"), !input.contains("\n"),
              let fields = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
              Set(fields.keys).isSubset(of: allowed)
        else { throw Failure.denied }
        let event = try JSONDecoder().decode(Event.self, from: Data(input.utf8))
        guard event.id > 0, event.title.utf8.count + (event.message?.utf8.count ?? 0) <= 2048 else { throw Failure.denied }
        switch event.operation {
        case .show:
            let previousID = lastIDs[ticket]
            guard event.id > (previousID ?? 0), previousID != nil || lastIDs.count < 64 else { throw Failure.denied }
            owner = ticket
            lastIDs[ticket] = event.id
        case .update:
            guard owner == ticket, event.id == lastIDs[ticket] else { throw Failure.denied }
        }
        return .init(title: event.title, message: event.message, style: event.style)
    }

    mutating func withdraw(_ input: String, from ticket: UUID) throws {
        struct Withdrawal: Decodable {
            let id: Int
        }
        guard input.utf8.count <= 128,
              let fields = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
              Set(fields.keys) == ["operation", "id"], fields["operation"] as? String == "hide",
              owner == ticket
        else { throw Failure.denied }
        let event = try JSONDecoder().decode(Withdrawal.self, from: Data(input.utf8))
        guard event.id == lastIDs[ticket] else { throw Failure.denied }
        owner = nil
    }

    package mutating func finish(_ ticket: UUID) -> Bool {
        lastIDs[ticket] = nil
        guard owner == ticket else { return false }
        owner = nil
        return true
    }
}
