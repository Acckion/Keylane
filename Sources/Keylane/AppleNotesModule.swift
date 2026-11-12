import AppKit
import Combine
import KeylaneCore
import SwiftUI

enum AppleNotesModule {
    private static let searchPage = PageID(rawValue: "AppleNotesSearch")
    private static let createPage = PageID(rawValue: "AppleNotesCreate")
    private static let symbol = "note.text"

    static func make(model: Model) -> LauncherModule {
        let permission = PermissionFeature("appleNotes.enabled", authorization: .automation("com.apple.Notes", appName: "备忘录"), observeImmediately: false)
        let notes = AppleNotesController(permission: permission)
        let create: (LauncherCommandOrigin) -> Void = { [weak model] origin in
            notes.resetDraft()
            model?.openPage(createPage, origin: origin)
        }
        let search = LauncherPage(
            id: searchPage, placeholder: "搜索 Apple 备忘录…", badge: ("Apple 备忘录", symbol),
            contentPlacement: .underChrome, content: { AnyView(AppleNotesList(controller: notes)) },
            queryChanged: notes.search, leave: notes.clearSearch, move: notes.move,
            submit: notes.openSelected, primaryTitle: { "打开备忘录" },
            primaryEnabled: { notes.selectedID != nil && !notes.saving },
            actions: {
                var actions: [LauncherAction] = [.init(id: "create-apple-note", title: "新建 Apple 备忘录", icon: "plus") { create(.menu) }]
                if notes.selectedID != nil {
                    actions.insert(.init(id: "open-apple-note", title: "在独立窗口打开", icon: "macwindow", keys: ["↩"],
                                         enabled: !notes.saving, perform: notes.openSelected), at: 0)
                }
                return actions
            },
            updates: notes.updates,
            enter: { _ in notes.search(""); return "" }
        )
        let editor = LauncherPage(
            id: createPage, placeholder: "", badge: ("新建 Apple 备忘录", symbol),
            contentPlacement: .form,
            content: { [weak model] in
                AnyView(AppleNoteForm(controller: notes) { model?.pageID = .root })
            },
            submit: notes.create, shortcutSubmit: notes.create,
            primaryTitle: { notes.createdID == nil ? "创建备忘录" : "打开备忘录" },
            primaryEnabled: { notes.canCreate && !notes.saving },
            updates: notes.updates
        )
        return .init(id: .init(rawValue: "keylane.apple-notes"), title: "Apple 备忘录", symbol: symbol, commands: [
            .init(declaration: .init(id: .init(rawValue: "search-apple-notes"), title: "搜索 Apple 备忘录",
                                     detail: "按标题或正文搜索，使用原生编辑器打开", symbol: symbol,
                                     keywords: ["Notes", "Search Notes", "笔记", "便签"], destination: .page(searchPage), settingsPage: "keylane.apple-notes"),
                  permission: permission),
            .init(declaration: .init(id: .init(rawValue: "create-apple-note"), title: "新建 Apple 备忘录",
                                     detail: "快速记录到 Apple 备忘录的默认文件夹", symbol: "square.and.pencil",
                                     keywords: ["Create Note", "新建笔记", "记笔记"], destination: .action, settingsPage: "keylane.apple-notes"),
                  permission: permission, execute: create)
        ], pages: [search, editor], services: [.init(start: permission.startObserving, stop: {
            permission.stopObserving()
            notes.stop()
        })], searchUpdates: [permission.updates],
           permissionTitlebar: permission.titlebar("启用 Apple 备忘录"))
    }
}

private final class AppleNotesController: ObservableObject {
    @Published private(set) var results: [AppleNoteResult] = []
    @Published var selectedID: String?
    @Published private(set) var searching = false
    @Published private(set) var saving = false
    @Published private(set) var searchError = ""
    @Published private(set) var draftError = ""
    @Published private(set) var createdID: String?
    @Published var title = ""
    @Published var body = ""
    private var query = ""
    private var revision = 0
    private var pendingSearch: DispatchWorkItem?
    private var searchProcess: ExtensionProcessRequest?
    private var actionProcess: ExtensionProcessRequest?
    private let queue = DispatchQueue(label: "org.keylane.apple-notes", qos: .userInitiated)
    private let permission: PermissionFeature

    init(permission: PermissionFeature) { self.permission = permission }

    var updates: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            ViewObservation.changes($selectedID), ViewObservation.changes($saving),
            ViewObservation.changes($title), ViewObservation.changes($body), ViewObservation.changes($createdID)
        ]).eraseToAnyPublisher()
    }

    var canCreate: Bool {
        createdID != nil || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func search(_ value: String) {
        guard permission.available else { clearSearch(); return }
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if term == query, searching { return }
        query = term
        revision += 1
        let requested = revision
        selectedID = nil
        results = []
        searchError = ""
        searching = true
        pendingSearch?.cancel()
        searchProcess?.cancel()
        let process = ExtensionProcessRequest()
        searchProcess = process
        let request = DispatchWorkItem { [weak self] in
            let outcome = Result { try AppleNotesAutomation.search(term, request: process) }
            DispatchQueue.main.async {
                guard let self, self.revision == requested else { return }
                self.pendingSearch = nil
                self.searchProcess = nil
                self.searching = false
                switch outcome {
                case .success(let notes):
                    self.results = notes
                    self.selectedID = notes.first?.id
                case .failure(let error):
                    self.searchError = error.localizedDescription
                }
            }
        }
        pendingSearch = request
        permission.verifyForUse { [weak self] allowed in
            guard let self, self.revision == requested else { return }
            if allowed {
                self.queue.asyncAfter(deadline: .now() + 0.22, execute: request)
            } else {
                self.pendingSearch = nil
                self.searching = false
                self.searchError = self.permission.guidance
            }
        }
    }

    func retrySearch() { search(query) }

    func clearSearch() {
        searchProcess?.cancel()
        searchProcess = nil
        pendingSearch?.cancel()
        pendingSearch = nil
        revision += 1
        searching = false
        searchError = ""
        selectedID = nil
        results = []
        query = ""
    }

    func stop() {
        clearSearch()
        actionProcess?.cancel()
        actionProcess = nil
        saving = false
        resetDraft()
    }

    func move(_ delta: Int) {
        let index = results.firstIndex { $0.id == selectedID } ?? 0
        let next = NavigationBounds.move(index, by: delta, count: results.count)
        if results.indices.contains(next) { selectedID = results[next].id }
    }

    func openSelected() {
        guard permission.available, let selectedID, !saving else { return }
        saving = true
        searchError = ""
        performAuthorized({ try AppleNotesAutomation.show(selectedID, request: $0) }) { outcome in
            self.saving = false
            switch outcome {
            case .success: (NSApp.delegate as? Delegate)?.hideLauncher()
            case .failure(let error): self.searchError = error.localizedDescription
            }
        }
    }

    func resetDraft() {
        guard !saving else { return }
        title = ""
        body = ""
        draftError = ""
        createdID = nil
    }

    func create() {
        guard permission.available, canCreate, !saving else { return }
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body
        let existing = createdID
        saving = true
        draftError = ""
        let process = ExtensionProcessRequest()
        actionProcess = process
        permission.verifyForUse { allowed in
            guard self.actionProcess === process else { return }
            guard allowed else {
                self.actionProcess = nil
                self.saving = false
                self.draftError = self.permission.guidance
                return
            }
            self.queue.async {
                var noteID = existing
                let outcome = Result {
                    let id = try noteID ?? AppleNotesAutomation.create(title: heading, body: text, request: process)
                    noteID = id
                    try AppleNotesAutomation.show(id, request: process)
                }
                DispatchQueue.main.async {
                    guard self.actionProcess === process else { return }
                    self.actionProcess = nil
                    self.saving = false
                    self.createdID = noteID
                    switch outcome {
                    case .success:
                        self.resetDraft()
                        (NSApp.delegate as? Delegate)?.hideLauncher()
                    case .failure(let error):
                        self.draftError = noteID == nil ? error.localizedDescription : "备忘录已创建。\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func performAuthorized(_ operation: @escaping (ExtensionProcessRequest) throws -> Void,
                                   completion: @escaping (Result<Void, Error>) -> Void) {
        let process = ExtensionProcessRequest()
        actionProcess = process
        permission.verifyForUse { allowed in
            guard self.actionProcess === process else { return }
            guard allowed else {
                self.actionProcess = nil
                completion(.failure(AppleNotesAutomation.Failure(code: -1743)))
                return
            }
            self.queue.async {
                let result = Result { try operation(process) }
                DispatchQueue.main.async {
                    guard self.actionProcess === process else { return }
                    self.actionProcess = nil
                    completion(result)
                }
            }
        }
    }
}

private struct AppleNotesList: View {
    @ObservedObject var controller: AppleNotesController

    var body: some View {
        SelectableResultList(selection: controller.selectedID, query: "", firstResult: controller.results.first?.id) {
            if controller.searching {
                ProgressView("正在搜索 Apple 备忘录…").frame(maxWidth: .infinity).padding(24)
            } else if !controller.searchError.isEmpty {
                VStack(spacing: 12) {
                    Text(controller.searchError).foregroundStyle(.secondary)
                    Button("重试", action: controller.retrySearch)
                }.frame(maxWidth: .infinity).padding(24)
            } else if controller.results.isEmpty {
                ContentUnavailableView("没有匹配的备忘录", systemImage: "note.text")
                    .frame(maxWidth: .infinity)
            }
            ForEach(controller.results) { note in
                ResultListButton(id: note.id, action: { controller.selectedID = note.id }) {
                    ResultListRow(selected: controller.selectedID == note.id) {
                        Image(systemName: "note.text").foregroundStyle(.secondary)
                    } content: {
                        Text(note.title).font(VisualStyle.rowText).lineLimit(1)
                    }
                }
            }
        }
    }
}

private struct AppleNoteForm: View {
    @ObservedObject var controller: AppleNotesController
    let back: () -> Void
    @FocusState private var focus: String?

    var body: some View {
        LauncherCreationForm(back: back) { EmptyView() } fields: {
            LauncherCreationField("标题") {
                LauncherCreationControl(focused: focus == "title") {
                    TextField("备忘录标题", text: $controller.title).textFieldStyle(.plain).focused($focus, equals: "title")
                }.disabled(controller.saving || controller.createdID != nil)
            }
            LauncherCreationField("内容", detail: "保存到 Apple 备忘录的默认文件夹。") {
                LauncherCreationControl(focused: focus == "body") {
                    TextEditor(text: $controller.body).scrollContentBackground(.hidden).frame(minHeight: 110)
                        .focused($focus, equals: "body")
                }.disabled(controller.saving || controller.createdID != nil)
            }
            if !controller.draftError.isEmpty {
                LauncherCreationField("") { Text(controller.draftError).foregroundStyle(.red) }
            }
        }
        .task { focus = "title" }
        .onExitCommand(perform: back)
    }
}
