import Foundation
import KeylaneCore

func verify() throws {
    let suite = "org.keylane.quicklinks.integration." + UUID().uuidString
    guard let preferences = UserDefaults(suiteName: suite) else { fatalError("Missing test preferences") }
    defer { preferences.removePersistentDomain(forName: suite) }

    let original = Data(#"{"links":[{"id":"quicklink:four","title":"四个参数","template":"https://example.com/{a}/{b}/{c}/{d}"}]}"#.utf8)
    preferences.set(original, forKey: QuicklinkLibrary.storageKey)
    var opened: [URL] = []
    var mayOpen = true
    let controller = QuicklinksController(preferences: preferences, openURL: {
        guard mayOpen else { return false }
        opened.append($0)
        return true
    })
    controller.load()
    guard let legacy = controller.links.first else { fatalError("Missing legacy fixture") }

    var presented = false
    precondition(!controller.launch(legacy) { presented = true })
    precondition(presented && controller.parameters.map(\.id) == ["a", "b", "c", "d"])
    controller.values["a"] = "cancelled"
    controller.clearInput()
    precondition(!controller.submit() && opened.isEmpty)
    precondition(!controller.launch(legacy) {})
    precondition(controller.values.isEmpty && !controller.submit() && controller.inputError != nil)
    controller.values = ["a": "1", "b": "2", "c": "3", "d": "中文/x"]
    mayOpen = false
    precondition(!controller.submit() && controller.inputError != nil && opened.isEmpty)
    mayOpen = true
    precondition(controller.submit())
    precondition(opened.map(\.absoluteString) == ["https://example.com/1/2/3/%E4%B8%AD%E6%96%87%2Fx"])
    precondition(!controller.submit())

    controller.edit(legacy)
    controller.draft?.title = "未保存"
    precondition(controller.leaveEditor(currentPage: .root) == nil)
    precondition(preferences.data(forKey: QuicklinkLibrary.storageKey) == original)
    controller.edit(legacy)
    controller.draft?.title = "重命名"
    controller.draftTags = "工作, 资料"
    precondition(controller.saveDraft() == legacy.id)
    precondition(controller.leaveEditor(currentPage: .root) == nil)
    controller.updateOrganization(id: legacy.id) {
        $0.pinned = true
        $0.hiddenFromRoot = true
    }

    let data = Data(#"[{"name":"示例","link":"https://example.org/","tags":["公司, 文档"]}]"#.utf8)
    let inserted = try controller.importData(data)
    guard let imported = inserted.links.first else { fatalError("Import produced no link") }
    controller.edit(imported)
    controller.draft?.title = "示例更新"
    precondition(controller.saveDraft() == imported.id)
    precondition(controller.links.last?.tags == ["公司, 文档"])

    let exchange = try controller.library.exportJSON()
    let repeated = try controller.importData(exchange)
    precondition(repeated.links.isEmpty && repeated.duplicates == 2)
    let beforeFailure = preferences.data(forKey: QuicklinkLibrary.storageKey)
    do {
        _ = try controller.importData(Data(#"[{"name":"新链接","link":"https://example.com/"},{"name":"无效","link":"file:///tmp"}]"#.utf8))
        fatalError("Invalid import was accepted")
    } catch {
        precondition(preferences.data(forKey: QuicklinkLibrary.storageKey) == beforeFailure)
    }
    controller.stop()
    controller.load()
    controller.tag = Quicklink.tagKey("资料")
    precondition(controller.rows(aliases: [:]).map(\.id) == [legacy.id])
    precondition(controller.links.first?.hiddenFromRoot == true && controller.links.first?.pinned == true)

    let corrupt = Data([0])
    preferences.set(corrupt, forKey: QuicklinkLibrary.storageKey)
    controller.load()
    precondition(controller.storageError != nil)
    do {
        _ = try controller.importData(data)
        fatalError("Corrupt storage was overwritten")
    } catch {
        precondition(preferences.data(forKey: QuicklinkLibrary.storageKey) == corrupt)
    }
    try verifyEditorNavigation()
    print("QUICKLINKS_INTEGRATION_OK editor_hide=true editor_cancel=true legacy=4 cancel=true retry=true import=true duplicate=true reload=true corrupt_protected=true")
}

func verifyEditorNavigation() throws {
    let suite = "org.keylane.quicklinks.editor." + UUID().uuidString
    guard let preferences = UserDefaults(suiteName: suite) else { fatalError("Missing test preferences") }
    defer { preferences.removePersistentDomain(forName: suite) }

    let original = Quicklink(title: "Original", template: "https://example.org/")
    try QuicklinkLibrary(links: [original]).save(to: preferences)
    let initialData = preferences.data(forKey: QuicklinkLibrary.storageKey)
    let controller = QuicklinksController(preferences: preferences)
    controller.load()
    let editor = QuicklinksController.editorPage
    let list = PageID(rawValue: "Quicklinks")
    var route = PageID.root
    var presentation = LauncherPagePresentation()

    func present(_ visible: Bool) -> LauncherPagePresentation.Change {
        let change = presentation.update(page: route, visible: visible)
        if change.deactivation == editor, let destination = controller.leaveEditor(currentPage: route) {
            route = destination
        }
        return change
    }

    precondition(present(true).activation == .enter)
    controller.edit()
    route = editor
    precondition(present(true).activation == .enter)
    controller.draft?.title = "Cancelled creation"
    precondition(present(false).deactivation == editor)
    precondition(route == .root && controller.draft == nil && controller.saveDraft() == nil)
    precondition(preferences.data(forKey: QuicklinkLibrary.storageKey) == initialData)
    precondition(present(true).activation == .enter && presentation.page == .root)

    controller.edit()
    route = editor
    precondition(present(true).activation == .enter)
    controller.draft?.title = "Created after reopening"
    controller.draft?.template = "https://example.com/"
    precondition(controller.saveDraft() != nil)
    route = controller.editorReturnPage
    precondition(present(true).deactivation == editor && controller.draft == nil)
    precondition(controller.links.count == 2)

    route = list
    precondition(present(true).activation == .enter)
    controller.edit(original, returningTo: list)
    route = editor
    precondition(present(true).activation == .enter)
    controller.draft?.title = "Cancelled edit"
    precondition(present(false).deactivation == editor && route == list)
    precondition(controller.draft == nil && controller.links.first == original)
    precondition(present(true).activation == .enter && presentation.page == list)

    controller.edit(original, returningTo: list)
    route = editor
    precondition(present(true).activation == .enter)
    controller.draft?.title = "Cancelled by navigating back"
    route = list
    precondition(present(true).deactivation == editor)
    precondition(route == list && controller.draft == nil && controller.links.first == original)

    controller.edit(original, returningTo: list)
    route = editor
    precondition(present(true).activation == .enter)
    controller.draft?.title = "Edited after reopening"
    precondition(controller.saveDraft() == original.id)
    route = controller.editorReturnPage
    precondition(present(true).deactivation == editor && route == list)
    let reloaded = try QuicklinkLibrary.load(from: preferences)
    precondition(reloaded.links.first?.title == "Edited after reopening")
}

try verify()
