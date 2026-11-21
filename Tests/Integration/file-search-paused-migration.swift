import AppKit
import Foundation
import UniformTypeIdentifiers
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
// Simulate a large preexisting paused index. Excluded rows are newer and would
// occupy all 200 local results (and, in the larger case, all 2000 SQL candidates).
let secondAllowed = scope.appendingPathComponent("needle-second.txt")
try Data("temporary fixture".utf8).write(to: secondAllowed)
var current = legacy
current.ignorePatterns = ["custom-excluded", "__pycache__"]
preferences.set(try JSONEncoder().encode(current), forKey: "fileSearchOptions")
for excludedCount in [240, 2400] {
    let directory = fixture.appendingPathComponent("candidate-index-\(excludedCount)")
    do {
        let db = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite"))
        try db.transaction {
            for i in 0..<excludedCount {
                let folder = i.isMultiple(of: 2) ? "package/__pycache__/nested" : "custom-excluded/nested"
                let name = "needle-obsolete-\(i).pyc"
                try db.put(.init(path: scope.path + "/" + folder + "/" + name, name: name, volume: "/",
                                 modified: Double(10_000 + i), directory: false, symlink: false), root: scope.path, epoch: "saved")
            }
            for (i, url) in [allowed, secondAllowed].enumerated() {
                try db.put(.init(path: url.path, name: url.lastPathComponent, volume: "/", modified: Double(100 - i),
                                 directory: false, symlink: false), root: scope.path, epoch: "saved")
            }
        }
    }
    let paused = FileSearchController(directory: directory, preferences: preferences, watchChanges: false)
    rows = []
    paused.updated = { rows = $0; _ = $1 }
    paused.search("needle")
    wait("Excluded candidates must not crowd out visible paused results: \(excludedCount)") { !paused.isSearching }
    precondition(rows.map(\.id) == [allowed.path, secondAllowed.path])
    precondition(paused.indexPaused && !paused.indexing)
    paused.stopRuntime()
    let retained = try FileSearchIndex(url: directory.appendingPathComponent("index.sqlite")).stats().entries
    precondition(retained == excludedCount + 2)
}
print("PASS paused candidate caps: 240 and 2400 newer excluded rows do not crowd out ordered visible results; index stays paused and saved rows retained")
// Directory-only negation must use the stored type at SQL filtering, the
// publication recheck, and metadata enrichment, including unavailable paths.
let typedScope = fixture.appendingPathComponent("typed-scope")
let onlineDirectory = typedScope.appendingPathComponent("kept-online")
let offlineDirectory = typedScope.appendingPathComponent("kept-offline")
let rejectedFile = typedScope.appendingPathComponent("kept-file")
try FileManager.default.createDirectory(at: onlineDirectory, withIntermediateDirectories: true)
try Data("*\n!kept*/\n".utf8).write(to: typedScope.appendingPathComponent(".gitignore"))
let typedIndex = fixture.appendingPathComponent("typed-index")
do {
    let db = try FileSearchIndex(url: typedIndex.appendingPathComponent("index.sqlite"))
    for (i, entry) in [(onlineDirectory, true), (offlineDirectory, true), (rejectedFile, false)].enumerated() {
        try db.put(.init(path: entry.0.path, name: entry.0.lastPathComponent, volume: "/", modified: Double(10 - i),
                         directory: entry.1, symlink: false), root: typedScope.path, epoch: "saved")
    }
}
var typedOptions = FileSearchOptions(roots: [typedScope.path]); typedOptions.ignorePatterns = []
preferences.set(try JSONEncoder().encode(typedOptions), forKey: "fileSearchOptions")
preferences.set([typedScope.path], forKey: "fileSearchSelectedScopes")
let typedController = FileSearchController(directory: typedIndex, preferences: preferences, watchChanges: false)
rows = []
typedController.updated = { rows = $0; _ = $1 }
typedController.search("kept")
wait("Saved directory type must survive directory-only allow rules") { !typedController.isSearching }
precondition(rows.map(\.id) == [onlineDirectory.path, offlineDirectory.path])
precondition(rows.allSatisfy { $0.isDirectory && $0.contentType?.conforms(to: .folder) == true })
precondition(typedController.indexPaused && !typedController.indexing)
typedController.stopRuntime()
let typedCount = try FileSearchIndex(url: typedIndex.appendingPathComponent("index.sqlite")).stats().entries
precondition(typedCount == 3)
precondition(FileManager.default.fileExists(atPath: onlineDirectory.path))
precondition(!FileManager.default.fileExists(atPath: offlineDirectory.path))
print("PASS saved directory types: directory-only allow rule keeps online and offline directories, rejects files, preserves pause, order and saved rows")
for url in [cached, allowed, custom] { precondition(FileManager.default.fileExists(atPath: url.path)) }
print("PASS paused migration: real preexisting index, restored cache descendants filtered on restart, custom pattern retained, rule removal survives restart, no resume/rebuild or disk-file deletion")
