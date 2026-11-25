import AppKit
import Combine
import KeylaneCore
import SwiftUI

/// One visit to one signed command. Native controls only send typed input to
/// the revision they represent, never JavaScript or an arbitrary host action.
@MainActor
final class MacOSLauncherExtensionPage: ObservableObject {
    private typealias Snapshot = MacOSReviewedViewSession.Detail
    private typealias Event = MacOSReviewedViewSession.Event

    @Published private var frame: Frame?
    @Published private var failed = false
    private struct Frame {
        let detail: Snapshot
        let revision: Int
        let id: UUID
        let mailbox: MacOSReviewedViewSession.Mailbox
    }

    private let installation: RaycastStoreInstallation
    private let command: RaycastExtensionManifest.Command
    private let backend: RaycastStoreInstallCoordinator
    private weak var delegate: Delegate?
    private var visit: UUID?
    private var pendingSearch: (id: String, query: String)?
    private var searchTask: Task<Void, Never>?
    private var parent: PageID = .root

    init(installation: RaycastStoreInstallation, command: RaycastExtensionManifest.Command,
         backend: RaycastStoreInstallCoordinator, delegate: Delegate) {
        self.installation = installation
        self.command = command
        self.backend = backend
        self.delegate = delegate
    }

    private var id: PageID {
        .init(rawValue: "extension-view:" + installation.id.uuidString + ":" + command.id)
    }

    func open(origin: LauncherCommandOrigin) {
        guard let model = delegate?.model, model.pageID != id else { return }
        parent = model.pageID
        model.openPage(id, origin: origin)
    }

    var page: LauncherPage {
        var result = LauncherPage(id: id, placeholder: "")
        result.badge = (command.title, "puzzlepiece.extension")
        result.contentPlacement = .readingDetail
        result.content = { AnyView(Content(state: self)) }
        result.headerInput = .none
        result.back = { self.back() }
        result.parent = .root
        result.leave = {
            self.searchTask?.cancel()
            self.searchTask = nil
            self.pendingSearch = nil
            self.visit = nil
            self.frame = nil
        }
        result.badgeTitle = { self.frame?.detail.navigationTitle ?? self.command.title }
        result.updates = objectWillChange.map { _ in () }.eraseToAnyPublisher()
        result.actionShortcutsEnabled = true
        result.actions = { self.actions }
        result.primaryTitle = { self.frame?.detail.confirmation?.acceptTitle ?? self.primary?.title ?? "操作" }
        result.primaryEnabled = { self.frame?.detail.confirmation != nil || self.primary != nil }
        result.submit = {
            if let frame = self.frame, frame.detail.confirmation != nil { self.send(.confirm, frame: frame) }
            else { self.primary?.invoke() }
        }
        result.returnBindings.primary = .plain
        result.returnBindings.alternates[.command] = .init { self.leafActions.dropFirst().first?.id ?? "" }
        result.startSession = { self.start($0) }
        return result
    }

    private var leafActions: [LauncherAction] { actions.filter { $0.submenu == nil } }
    private var primary: LauncherAction? { leafActions.first }

    private func start(_ owner: LauncherPageSession) {
        failed = false
        frame = nil
        let id = UUID()
        visit = id
        let mailbox = MacOSReviewedViewSession.Mailbox()
        let presentation = MacOSReviewedViewSession.Presentation(mailbox: mailbox, isActive: { [weak self] in
            guard let self, let delegate = self.delegate else { return false }
            return self.visit == id && delegate.model.pageID == self.id && delegate.window?.isVisible == true
        }) { [weak self] detail, revision in
            guard let self else { return }
            self.frame = .init(detail: detail, revision: revision, id: id, mailbox: mailbox)
            if let pending = self.pendingSearch, self.searchTask == nil { self.flushSearch(pending) }
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await MacOSReviewedViewSession.$presentation.withValue(presentation) {
                    try await self.backend.launch(self.installation, commandID: self.command.id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.visit == id else { return }
                self.frame = nil
                self.failed = true
            }
        }
        // A signed effect can synchronously hide the Launcher while holding
        // its lease. Retire UI state immediately, then cancel outside that commit.
        owner.onEnd { Task { @MainActor in task.cancel() } }
    }

    private func back() {
        if let frame {
            if frame.detail.confirmation != nil { send(.dismiss, frame: frame); return }
            if (frame.detail.depth ?? 0) > 0 { send(.back, frame: frame); return }
        }
        guard let model = delegate?.model else { return }
        model.pageID = parent == id || model.launcherModules?.page(parent) == nil ? .root : parent
    }

    private func send(_ event: Event, frame: Frame) {
        guard visit == frame.id else { return }
        frame.mailbox.submit(.action(event), revision: frame.revision)
    }

    private var actions: [LauncherAction] {
        guard let frame, frame.detail.confirmation == nil else { return [] }
        return frame.detail.actions.map { action($0, frame: frame) }
    }

    private func search(id: String, query: String, visit idAtRender: UUID) {
        guard visit == idAtRender, query.utf8.count <= 256 else { return }
        pendingSearch = (id, query)
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
            guard let self, self.visit == idAtRender else { return }
            self.searchTask = nil
            if let pending = self.pendingSearch { self.flushSearch(pending) }
        }
    }

    private func flushSearch(_ pending: (id: String, query: String)) {
        guard let frame, frame.detail.confirmation == nil else { pendingSearch = nil; return }
        func contains(_ action: Snapshot.Action) -> Bool {
            (action.id == pending.id && action.searchable == true) || action.children?.contains(where: contains) == true
        }
        guard frame.detail.actions.contains(where: contains) else { pendingSearch = nil; return }
        if frame.mailbox.submit(.action(.search(pending.id, query: pending.query)), revision: frame.revision) {
            pendingSearch = nil
        }
    }

    private func action(_ descriptor: Snapshot.Action, frame: Frame) -> LauncherAction {
        let submenu = descriptor.children.map { children in
            LauncherAction.Submenu(title: descriptor.title, items: children.map { action($0, frame: frame) },
                search: descriptor.searchable == true ? { self.search(id: descriptor.id, query: $0, visit: frame.id) } : nil)
        }
        return LauncherAction(id: "extension-action:" + descriptor.id + (submenu == nil ? ":r\(frame.revision)" : ""), title: descriptor.title,
            icon: submenu == nil ? "arrow.turn.down.left" : "list.bullet",
            shortcut: descriptor.shortcut.flatMap(Self.keyboardShortcut), submenu: submenu, group: descriptor.group ?? 0,
            destructive: descriptor.style == .destructive, perform: { self.send(.action(descriptor.id), frame: frame) })
    }

    private static func keyboardShortcut(_ value: Snapshot.Action.Shortcut) -> KeyboardShortcut? {
        let special: [String: KeyEquivalent] = [
            "return": .return, "enter": .return, "escape": .escape, "delete": .delete,
            "deleteForward": .deleteForward, "tab": .tab, "space": .space,
            "arrowUp": .upArrow, "arrowDown": .downArrow, "arrowLeft": .leftArrow, "arrowRight": .rightArrow,
            "pageUp": .pageUp, "pageDown": .pageDown, "home": .home, "end": .end
        ]
        guard let key = special[value.key] ?? (value.key.count == 1 ? value.key.first.map { KeyEquivalent($0) } : nil) else { return nil }
        let modifiers: [String: EventModifiers] = ["cmd": .command, "ctrl": .control, "opt": .option, "shift": .shift]
        return .init(key, modifiers: value.modifiers.reduce(into: []) { if let modifier = modifiers[$1] { $0.insert(modifier) } })
    }

    private struct Content: View {
        @ObservedObject var state: MacOSLauncherExtensionPage

        var body: some View {
            Group {
                if let frame = state.frame {
                    VStack(alignment: .leading, spacing: 14) {
                        if let confirm = frame.detail.confirmation {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(confirm.title).font(.headline)
                                if let message = confirm.message { Text(message).foregroundStyle(.secondary) }
                                HStack {
                                    Button(confirm.cancelTitle ?? "取消") { state.send(.dismiss, frame: frame) }
                                    Button(confirm.acceptTitle, role: confirm.destructive == true ? .destructive : nil) { state.send(.confirm, frame: frame) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                            .accessibilityAddTraits(.isModal)
                        } else {
                            if frame.detail.isLoading == true { ProgressView().controlSize(.small) }
                            if !frame.detail.markdown.isEmpty {
                                AIConversationMarkdownBody(text: frame.detail.markdown, allowsLinks: false)
                            }
                            if let toast = frame.detail.toast {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 8) {
                                        if toast.style == .animated { ProgressView().controlSize(.small) }
                                        if toast.style == .success { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                                        if toast.style == .failure { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
                                        Text(toast.title).font(.headline)
                                    }
                                    if let message = toast.message { Text(message).foregroundStyle(.secondary) }
                                    HStack {
                                        if let primary = toast.primary {
                                            Button(primary.title) { state.send(.toastAction(primary.id), frame: frame) }
                                        }
                                        if let secondary = toast.secondary {
                                            Button(secondary.title) { state.send(.toastAction(secondary.id), frame: frame) }
                                        }
                                    }
                                }
                                .padding(12)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                } else if state.failed {
                    Text("扩展页面未能完成。").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
