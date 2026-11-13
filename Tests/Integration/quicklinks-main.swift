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
    controller.clearDraft()
    precondition(preferences.data(forKey: QuicklinkLibrary.storageKey) == original)
    controller.edit(legacy)
    controller.draft?.title = "重命名"
    controller.draftTags = "工作, 资料"
    precondition(controller.saveDraft() == legacy.id)
    controller.clearDraft()
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
    print("QUICKLINKS_INTEGRATION_OK legacy=4 cancel=true retry=true import=true duplicate=true reload=true corrupt_protected=true")
}

try verify()
