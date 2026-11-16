let probeHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!, isDirectory: true)
precondition(URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == probeHome.resolvingSymlinksInPath(), "Fixture home must be isolated")
precondition(Bundle.main.bundleIdentifier?.hasPrefix("org.keylane.test.application-favorites.") == true)
let probeDefaults = UserDefaults.standard
precondition(probeDefaults.object(forKey: "favorites") == nil, "Fresh test preferences required")
let _ = NSApplication.shared

func makeFixtureApp(_ name: String) throws -> URL {
    let app = probeHome.appendingPathComponent("Apps/" + name + ".app")
    let contents = app.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "org.keylane.test.bundle." + UUID().uuidString,
                "CFBundlePackageType": "APPL", "CFBundleName": name]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    return app
}

func drainChanges() { RunLoop.main.run(until: .now.addingTimeInterval(0.03)) }

let first = try makeFixtureApp("橘子")
let middle = try makeFixtureApp("苹果")
let last = try makeFixtureApp("苹果派")
probeDefaults.set([last.path, middle.path, first.path], forKey: "favorites")
let probe = Delegate()
NSApp.delegate = probe
probe.shortcuts.suspend()
let model = probe.model
model.apps = [first, middle, last]
drainChanges()

func rows(_ model: Model) -> [Entry] {
    model.commands.filter { $0.commandID.rawValue.hasPrefix("app:") }
}
func favoriteIDs(_ model: Model) -> [String] {
    rows(model).filter { model.favorites.contains($0.id) }.map(\.id)
}
func action(_ id: String, for url: URL) -> LauncherAction? {
    model.favoriteOrderActions(for: url.path).first { $0.id == id }
}
func expect(_ condition: Bool, _ label: String) {
    if !condition { print("FAIL " + label); exit(1) }
    print("PASS " + label)
}

expect(favoriteIDs(model) == [first.path, middle.path, last.path].sorted(), "legacy membership yields deterministic order")
probeDefaults.set([first.path, middle.path, last.path], forKey: "favoriteOrder")
let reloaded = Model()
reloaded.apps = [first, middle, last]
drainChanges()
expect(favoriteIDs(reloaded) == [first.path, middle.path, last.path], "saved favorite order loaded")
model.excluded.insert(middle.path)
let before = favoriteIDs(model)
action("move-favorite-later", for: first)?.perform()
let after = favoriteIDs(model)
print("Visible order when moving across hidden favorite: \(before.map { URL(fileURLWithPath: $0).lastPathComponent }) → \(after.map { URL(fileURLWithPath: $0).lastPathComponent })")
expect(after == Array(before.reversed()), "one move swaps visible neighbors")
expect(model.compactFavoriteEntries.map(\.id) == after, "compact and expanded favorites share the same order")
expect(probeDefaults.stringArray(forKey: "favoriteOrder") == [last.path, middle.path, first.path], "hidden favorite keeps its saved slot")
let restarted = Model()
restarted.apps = [first, middle, last]
drainChanges()
expect(favoriteIDs(restarted) == [last.path, middle.path, first.path], "moving persists across model recreation")

model.excluded.formUnion([first.path, last.path])
model.windowMode = "compact"
model.compactFavorites = true
expect(favoriteIDs(model).isEmpty, "all favorites are hidden")
expect(model.launcherHeight == 61 && model.compactFavoriteEntries.isEmpty, "no empty compact favorites row")
model.excluded = []
model.disabledCommands.insert("app:" + middle.path)
expect(model.compactFavoriteEntries.map(\.id) == [last.path, first.path], "disabled command is hidden from compact favorites")
model.disabledCommands.remove("app:" + middle.path)
model.applicationsEnabled = false
drainChanges()
expect(model.compactFavoriteEntries.isEmpty && model.launcherHeight == 61, "disabled Applications module leaves no empty bar")
model.applicationsEnabled = true
drainChanges()
expect(model.compactFavoriteEntries.map(\.id) == [last.path, middle.path, first.path] && model.launcherHeight == 109,
       "re-enabling restores saved positions")
try FileManager.default.removeItem(at: last)
model.apps = [first, middle]
drainChanges()
expect(model.compactFavoriteEntries.map(\.id) == [middle.path, first.path] && model.favorites.contains(last.path),
       "removed bundle disappears from compact favorites but keeps its saved position")
let _ = try makeFixtureApp("苹果派")
model.apps = [first, middle, last]
drainChanges()
expect(model.compactFavoriteEntries.map(\.id) == [last.path, middle.path, first.path], "returning bundle regains its position")
model.toggleFavorite(last.path)
expect(model.compactFavoriteEntries.map(\.id) == [middle.path, first.path] &&
       probeDefaults.stringArray(forKey: "favoriteOrder") == [middle.path, first.path], "removing a favorite persists")
model.toggleFavorite(last.path)
expect(model.compactFavoriteEntries.map(\.id) == [middle.path, first.path, last.path], "adding it again appends it")

model.excluded = []
model.query = "苹果"
let matches = rows(model)
expect(matches.map(\.id) == [middle.path, last.path], "Chinese exact match ranks before prefix")
let appRow = matches.first!
model.favoriteOrderActions(for: last.path).first { $0.id == "move-favorite-earlier" }!.perform()
expect(rows(model).map(\.id) == [middle.path, last.path], "favorite order does not override Chinese search relevance")
let actions = model.applicationResultActions.actions(for: appRow, model: model)
let shortcuts = model.applicationResultActions.shortcutActions(for: appRow, model: model)
expect(shortcuts.count == 5 && Set(shortcuts.map(\.keys)).count == 5 &&
       shortcuts.allSatisfy { shortcut in actions.contains { $0.id == shortcut.id && $0.keys == shortcut.keys } },
       "five direct shortcuts match action panel labels and have unique chords")
shortcuts.first { $0.id == "edit-app-command" }!.perform()
let editor = model.applicationResultActions.commandEditor
expect(model.pageID == ApplicationCommandEdit.pageID && editor.entry?.id == middle.path, "direct edit opens existing application editor")
editor.alias = "未保存"
model.pageID = .root
shortcuts.first { $0.id == "edit-app-command" }!.perform()
expect(editor.alias.isEmpty && model.aliases[middle.path] == nil, "leaving form discards alias draft")
editor.alias = "  合成关键词  "
editor.save(model: model)
expect(model.pageID == .root && model.aliases[middle.path] == "合成关键词", "alias save trims whitespace")
model.query = "合成关键词"
expect(rows(model).map(\.id) == [middle.path], "saved Chinese alias searches the correct app")

let saved = model.bindings
do {
    try model.updateShortcut(appRow.commandID.rawValue, value: saved["launcher"]!)
    expect(false, "duplicate shortcut must fail")
} catch {
    expect(model.bindings == saved && probeDefaults.data(forKey: "shortcuts") == nil, "duplicate shortcut leaves existing bindings untouched")
}
let testShortcut = Shortcut(key: 11, modifiers: 4096 | 2048 | 512 | 256)
try model.updateShortcut(appRow.commandID.rawValue, value: testShortcut)
expect(Model().bindings[appRow.commandID.rawValue] == testShortcut, "valid shortcut is persisted in fixture settings")
try model.updateShortcut(appRow.commandID.rawValue, value: nil)
expect(Model().bindings[appRow.commandID.rawValue] == nil, "cleared shortcut is persisted")

shortcuts.first { $0.id == "edit-app-command" }!.perform()
model.excluded.insert(middle.path)
editor.alias = "已隐藏时的写入"
editor.save(model: model)
expect(model.aliases[middle.path] == "合成关键词" && !editor.validate() && !editor.error.isEmpty,
       "hidden app editor refuses stale alias and hotkey saves")
model.pageID = .root
shortcuts.first { $0.id == "edit-app-command" }!.perform()
expect(model.pageID == .root, "stale direct shortcut cannot reopen a hidden app editor")
model.excluded = []
shortcuts.first { $0.id == "edit-app-command" }!.perform()
try FileManager.default.removeItem(at: middle)
expect(!editor.validate(), "stale editor refuses an app removed from disk before discovery refresh")
