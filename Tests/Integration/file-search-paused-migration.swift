import AppKit
import Foundation
import KeylaneCore

// Only this temporary tree and UUID preference domain are used.
let app = NSApplication.shared
let fixture = URL(fileURLWithPath: FileSearchLocation.canonicalPath(FileManager.default.temporaryDirectory.path)!).appendingPathComponent("keylane-paused-migration-" + UUID().uuidString)
let scope = fixture.appendingPathComponent("scope")
let cache = scope.appendingPathComponent("package/__pycache__")
let cached = cache.appendingPathComponent("nested/needle-cache.pyc")
let allowed = scope.appendingPathComponent("needle-document.txt")
let custom = scope.appendingPathComponent("custom-excluded/needle-private.txt")
let index = fixture.appendingPathComponent("index")
let suite = "org.keylane.paused-migration." + UUID().uuidString
let preferences = UserDefaults(suiteName: suite)!
defer {
    preferences.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: fixture)
}
for url in [cached, allowed, custom] {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("temporary fixture".utf8).write(to: url)
}
var legacy = FileSearchOptions(roots: [scope.path])
legacy.ignorePatterns = []
preferences.set(try JSONEncoder().encode(legacy), forKey: "fileSearchOptions")
preferences.set([cache.path], forKey: "fileSearchRestoredPaths")
preferences.set([scope.path], forKey: "fileSearchSelectedScopes")
// Emulate the old configuration before the new default rule existed.
preferences.set(true, forKey: "fileSearchPythonCacheIgnoreMigrated")

func wait(_ label: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(15)
    while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition(), label + " rows=" + rows.map(\.id).description)
}
var rows: [SpotlightFile] = []
let before = FileSearchController(directory: index, preferences: preferences, watchChanges: false)
before.updated = { rows = $0; _ = $1 }
before.search("needle")
wait("Fixture must first index the manually restored cache") {
    return !before.indexing && !before.isSearching && Set(rows.map(\.id)) == Set([cached.path, allowed.path, custom.path])
}
before.stopRuntime()
let savedCount = try FileSearchIndex(url: index.appendingPathComponent("index.sqlite")).stats().entries
precondition(savedCount >= 3)
legacy.ignorePatterns = ["custom-excluded"]
preferences.set(try JSONEncoder().encode(legacy), forKey: "fileSearchOptions")
preferences.set(true, forKey: "fileIndexPaused")
preferences.removeObject(forKey: "fileSearchPythonCacheIgnoreMigrated")

// Migration happens before the paused controller is restarted against the saved DB.
let migrated = FileSearchController(directory: index, preferences: preferences, watchChanges: false, startImmediately: false)
precondition(migrated.options.ignorePatterns == ["custom-excluded", "__pycache__"])
let restarted = FileSearchController(directory: index, preferences: preferences, watchChanges: false)
rows = []
restarted.updated = { rows = $0; _ = $1 }
restarted.search("needle")
wait("Paused migration must filter saved descendants without rescanning") { !restarted.isSearching }
precondition(restarted.indexPaused && !restarted.indexing)
precondition(rows.map(\.id) == [allowed.path], "Paused saved-index query leaked a cache or custom-excluded descendant: \(rows.map(\.id))")
let pausedCount = try FileSearchIndex(url: index.appendingPathComponent("index.sqlite")).stats().entries
precondition(pausedCount == savedCount)

restarted.options.ignorePatterns.removeAll { $0 == "__pycache__" }
wait("Removing the cache rule must allow existing saved rows while still paused") {
    !restarted.isSearching && Set(rows.map(\.id)) == Set([allowed.path, cached.path])
}
precondition(restarted.indexPaused && !restarted.indexing)
restarted.stopRuntime()
let removed = FileSearchController(directory: index, preferences: preferences, watchChanges: false)
rows = []
removed.updated = { rows = $0; _ = $1 }
removed.search("needle")
wait("Explicit rule removal must survive restart") { !removed.isSearching }
precondition(removed.options.ignorePatterns == ["custom-excluded"])
precondition(Set(rows.map(\.id)) == Set([allowed.path, cached.path]))
precondition(removed.indexPaused && !removed.indexing)
removed.stopRuntime()
for url in [cached, allowed, custom] { precondition(FileManager.default.fileExists(atPath: url.path)) }
print("PASS paused migration: real preexisting index, restored cache descendants filtered on restart, custom pattern retained, rule removal survives restart, no resume/rebuild or disk-file deletion")
