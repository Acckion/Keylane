import Foundation
import os

/// The initial view wire contract is independent of the React renderer. Only
/// native host events are sent to the guest, and only bounded view data returns.
package enum MacOSReviewedViewSession {
    package static let capability = "view.render"
    static let supported = MacOSNoViewCapabilities.navigation.union([capability, MacOSNoViewCapabilities.toast])

    static func canRun(_ capabilities: Set<String>) -> Bool {
        capabilities.contains(capability) && capabilities.isSubset(of: supported)
    }

    package struct Presentation: Sendable {
        package let mailbox: Mailbox
        private let isActive: @MainActor @Sendable () -> Bool
        private let publish: @MainActor @Sendable (Detail, Int) -> Void

        package init(mailbox: Mailbox, isActive: @escaping @MainActor @Sendable () -> Bool = { true },
                     publish: @escaping @MainActor @Sendable (Detail, Int) -> Void) {
            self.mailbox = mailbox
            self.isActive = isActive
            self.publish = publish
        }

        @MainActor func publishIfVisible(_ detail: Detail, _ revision: Int) -> Bool {
            guard isActive() else { return false }
            publish(detail, revision)
            return true
        }
    }

    @TaskLocal package static var presentation: Presentation?

    package struct Detail: Decodable, Equatable, Sendable {
        package struct Action: Decodable, Equatable, Sendable {
            package enum Style: String, Decodable, Sendable { case regular, destructive }
            package let id: String
            package let title: String
            package let style: Style
            package let children: [Action]?
            package let searchable: Bool?
            package let group: Int?
            package let shortcut: Shortcut?

            package struct Shortcut: Decodable, Equatable, Sendable {
                package let key: String
                package let modifiers: [String]

                var isValid: Bool {
                    !modifiers.isEmpty && modifiers.count <= 4
                        && Set(modifiers).count == modifiers.count
                        && Set(modifiers).isSubset(of: ["cmd", "ctrl", "opt", "shift"])
                        && (Self.special.contains(key) || (key.utf8.count == 1 && key.utf8.allSatisfy { (32...126).contains($0) }))
                }
                private static let special: Set<String> = [
                    "return", "enter", "escape", "delete", "deleteForward", "tab",
                    "arrowUp", "arrowDown", "arrowLeft", "arrowRight", "pageUp", "pageDown", "home", "end", "space"
                ]
            }

            func allowsSearch(_ actionID: String) -> Bool {
                guard let children else { return false }
                return (id == actionID && searchable == true) || children.contains { $0.allowsSearch(actionID) }
            }

            func allows(_ actionID: String) -> Bool {
                if let children { return children.contains { $0.allows(actionID) } }
                return id == actionID
            }

            func collectIDs(_ ids: inout Set<String>, depth: Int = 0) -> Bool {
                guard depth <= 3, ids.count < 32, !id.isEmpty, id.utf8.count <= 96,
                      !title.isEmpty, title.utf8.count <= 256, ids.insert(id).inserted,
                      (0...31).contains(group ?? 0), shortcut?.isValid ?? true,
                      searchable != true || children != nil else { return false }
                guard let children else { return true }
                return (searchable == true || !children.isEmpty) && children.allSatisfy { $0.collectIDs(&ids, depth: depth + 1) }
            }
        }
        package struct Confirmation: Decodable, Equatable, Sendable {
            package let title: String
            package let message: String?
            package let acceptTitle: String
            package let cancelTitle: String?
            package let destructive: Bool?
        }

        package struct Toast: Decodable, Equatable, Sendable {
            package enum Style: String, Decodable, Sendable { case success, failure, animated }
            package let style: Style?
            package let title: String
            package let message: String?
            package let primary: Action?
            package let secondary: Action?
        }

        package let confirmation: Confirmation?
        package let toast: Toast?
        package let depth: Int?
        package let navigationTitle: String?
        package let isLoading: Bool?
        package let markdown: String
        package let actions: [Action]
        let effects: [MacOSNoViewCapabilities.Effect]?
    }

    package struct Event: Encodable, Sendable {
        enum Kind: String, Encodable, Sendable { case action, back, confirm, dismiss, toastAction, search }
        private let kind: Kind
        private let actionID: String?
        private var query: String? = nil

        package static func action(_ id: String) -> Self { .init(kind: .action, actionID: id) }
        package static let confirm = Self(kind: .confirm, actionID: nil)
        package static let dismiss = Self(kind: .dismiss, actionID: nil)
        package static func toastAction(_ id: String) -> Self { .init(kind: .toastAction, actionID: id) }
        package static func search(_ id: String, query: String) -> Self { .init(kind: .search, actionID: id, query: query) }
        package static let back = Self(kind: .back, actionID: nil)

        func allowed(in snapshot: Detail) -> Bool {
            if snapshot.confirmation != nil { return kind == .confirm || kind == .dismiss }
            switch kind {
            case .back: return true
            case .search:
                guard let actionID, let query, query.utf8.count <= 256 else { return false }
                return snapshot.actions.contains { $0.allowsSearch(actionID) }
            case .confirm, .dismiss: return false
            case .action:
                guard let actionID else { return false }
                return snapshot.actions.contains { $0.allows(actionID) }
            case .toastAction: return [snapshot.toast?.primary, snapshot.toast?.secondary].compactMap { $0 }.contains { $0.id == actionID }
            }
        }
    }

    private struct Request: Encodable {
        let session: UUID
        let sequence: Int
        let source: String?
        let capabilities: [String]?
        let event: Event?
    }

    private struct Reply: Decodable {
        let session: UUID
        let sequence: Int
        let snapshot: String
    }

    enum Failure: Error { case invalidReply, invalidEvent, retired }

    package final class Mailbox: Sendable {
        package enum Selection: Sendable { case action(Event), finish }
        private struct State: Sendable {
            var revision: Int?
            var selection: Selection?
        }
        package init() {}

        private let state = OSAllocatedUnfairLock(initialState: State())

        fileprivate func open(revision: Int) {
            state.withLock { $0 = State(revision: revision) }
        }

        @discardableResult package func submit(_ selection: Selection, revision: Int) -> Bool {
            state.withLock {
                guard $0.revision == revision, $0.selection == nil else { return false }
                $0.selection = selection
                return true
            }
        }

        fileprivate func take() -> Selection? {
            state.withLock {
                guard let selection = $0.selection else { return nil }
                $0 = State()
                return selection
            }
        }

        fileprivate func close() { state.withLock { $0 = State() } }
    }

    static func run(helper: URL, source: String, process: MacOSOwnedHelperProcess, timeout: Duration,
                    ownership: Int32? = nil, capabilities: Set<String> = [], mailbox: Mailbox, isCurrent: @escaping () -> Bool,
                    publish: @escaping (Detail, Int) throws -> Void) throws {
        let session = UUID()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let decoder = JSONDecoder()
        func message(sequence: Int, source: String? = nil, event: Event? = nil) throws -> Data {
            var bytes = try encoder.encode(Request(session: session, sequence: sequence, source: source,
                capabilities: source == nil ? nil : capabilities.sorted(), event: event))
            bytes.append(10)
            return bytes
        }

        guard isCurrent() else { throw Failure.retired }
        defer { mailbox.close() }
        var sequence = 0
        var currentDetail: Detail?
        _ = try process.run(helper: helper, input: message(sequence: sequence, source: source),
                            timeout: timeout, outputLimit: 96 * 1024, ownership: ownership,
                            arguments: ["--reviewed-view-session"], nextFrame: { data in
            guard isCurrent() else { throw Failure.retired }
            let reply = try decoder.decode(Reply.self, from: data)
            guard reply.session == session, reply.sequence == sequence,
                  reply.snapshot.utf8.count <= 32 * 1024 else { throw Failure.invalidReply }
            let detail = try decoder.decode(Detail.self, from: Data(reply.snapshot.utf8))
            let toastActions = [detail.toast?.primary, detail.toast?.secondary].compactMap { $0 }
            let actions = detail.actions + toastActions
            var actionIDs = Set<String>()
            guard (0...15).contains(detail.depth ?? 0), (detail.navigationTitle?.utf8.count ?? 0) <= 256, detail.markdown.utf8.count <= 24 * 1024, detail.actions.count <= 32,
                  toastActions.allSatisfy({ $0.children == nil }),
                  detail.confirmation.map({ !$0.title.isEmpty && $0.title.utf8.count <= 256 &&
                      !$0.acceptTitle.isEmpty && $0.acceptTitle.utf8.count <= 128 &&
                      ($0.cancelTitle?.utf8.count ?? 0) <= 128 &&
                      ($0.message?.utf8.count ?? 0) <= 2048 }) ?? true,
                  detail.toast.map({ !$0.title.isEmpty && $0.title.utf8.count <= 256 &&
                      ($0.message?.utf8.count ?? 0) <= 2048 }) ?? true,
                  actions.allSatisfy({ $0.collectIDs(&actionIDs) }) else { throw Failure.invalidReply }
            currentDetail = detail
            mailbox.open(revision: sequence)
            // Publish callbacks enqueue work for the UI rather than awaiting user
            // input on the process supervisor.
            try publish(detail, sequence)
            return .wait
        }, pollFrame: {
            guard isCurrent() else { throw Failure.retired }
            guard let selection = mailbox.take() else { return .wait }
            switch selection {
            case .finish: return .finish
            case .action(let event):
                guard let currentDetail, sequence < 127, event.allowed(in: currentDetail) else {
                    throw Failure.invalidEvent
                }
                sequence += 1
                return .send(try message(sequence: sequence, event: event))
            }
        })
    }
}
