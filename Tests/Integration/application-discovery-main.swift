import AppKit
import Foundation
import KeylaneCore

let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
let files = FileManager.default
let discovery = ApplicationDiscovery()
var snapshots: [[CatalogApplication]] = []
var failures: [String] = []
discovery.updated = { records, _ in snapshots.append(records) }
discovery.failed = { failures.append($0) }

func advance(_ seconds: TimeInterval) {
    RunLoop.main.run(until: .now.addingTimeInterval(seconds))
}
func wait(_ label: String, until predicate: () -> Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + 6
    while !predicate(), ProcessInfo.processInfo.systemUptime < deadline { advance(0.025) }
    precondition(predicate(), "\(label), updates=\(snapshots.count), issues=\(failures)")
}
func has(_ apps: [URL]) -> Bool {
    guard let latest = snapshots.last else { return false }
    return Set(latest.map(\.id)) == Set(apps.map(\.path))
}
func writeApp(_ directory: URL, _ name: String) throws -> URL {
    let url = directory.appendingPathComponent(name + ".app", isDirectory: true)
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try files.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "org.keylane.discovery." + UUID().uuidString,
        "CFBundlePackageType": "APPL", "CFBundleName": name,
        "CFBundleAlternateNames": ["FormerFixtureName"], "MDItemKeywords": ["FixtureBundleKeyword"]
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    return url.resolvingSymlinksInPath().standardizedFileURL
}

let actual = base.appendingPathComponent("Apps")
let selected = base.appendingPathComponent("Linked scope")
let first = try writeApp(actual, "Fixture")
let finderAlias = actual.appendingPathComponent("Finder alias")
try URL.writeBookmarkData(first.bookmarkData(options: .suitableForBookmarkFile), to: finderAlias)
try files.createSymbolicLink(at: actual.appendingPathComponent("Alias.app"), withDestinationURL: first)
try files.createSymbolicLink(at: selected, withDestinationURL: actual)
discovery.configure(roots: [selected.path], excluded: [])
wait("symlink root discovers canonical bundle and deduplicates references") { has([first]) }
let added = try writeApp(actual, "Added")
wait("physical directory mutation refreshes symlink root") { has([first, added]) }
try files.removeItem(at: added)
wait("deletion refreshes symlink root") { has([first]) }

let replacement = base.appendingPathComponent("Other").appendingPathComponent("Apps")
let sameName = try writeApp(replacement, "Fixture")
try files.removeItem(at: selected)
try files.createSymbolicLink(at: selected, withDestinationURL: replacement)
wait("link replacement refreshes discovery") { has([sameName]) }
let addedAfterLinkReplacement = try writeApp(replacement, "Replacement addition")
wait("replacement target stays watched") { has([sameName, addedAfterLinkReplacement]) }
try files.removeItem(at: addedAfterLinkReplacement)

let roots = [actual.path, selected.path]
discovery.configure(roots: roots, excluded: [])
wait("same names in two configured scopes retain both paths") { has([first, sameName]) }
let records = snapshots.last!
precondition(records.count == 2 && Set(records.map(\.identity.displayName)).count == 1)
let aliasRanking = LauncherSearchRanking(query: "user-chosen-alias", aliases: [sameName.path: "user-chosen-alias"],
                                        favorites: [], usage: [:])
let best = records.compactMap { app in
    aliasRanking.match(id: app.id, title: app.identity.displayName, names: app.identity.aliases)
}.sorted { $0.precedes($1) }.first
precondition(best?.id == sameName.path && best?.score == 1500)
let pathRanking = LauncherSearchRanking(query: sameName.path, aliases: [:], favorites: [], usage: [:])
let byPath = records.compactMap { app in
    pathRanking.match(id: app.id, title: app.identity.displayName, names: app.identity.aliases + [app.id])
}.sorted { $0.precedes($1) }.first
precondition(byPath?.id == sameName.path)
precondition(records.allSatisfy {
    $0.identity.score(query: "FormerFixtureName") != nil && $0.identity.score(query: "FixtureBundleKeyword") != nil
})

discovery.configure(roots: roots, excluded: [first.path])
wait("exclusion persists through all aliases") { has([sameName]) }
discovery.configure(roots: [actual.path], excluded: [])
let moved = base.appendingPathComponent("Moved")
wait("ordinary root selected") { has([first]) }
try files.moveItem(at: actual, to: moved)
wait("root move removes its previous records") { has([]) }
let recovered = try writeApp(actual, "Recovered")
wait("recreated scope becomes active") { has([recovered]) }
let afterRecovery = try writeApp(actual, "After Recovery")
wait("new writes after root recovery") { has([recovered, afterRecovery]) }

var count = snapshots.count
discovery.configure(roots: [actual.path], excluded: [])
discovery.configure(roots: [replacement.path], excluded: [])
discovery.configure(roots: [actual.path], excluded: [])
wait("latest configuration wins") { snapshots.count > count && has([recovered, afterRecovery]) }
advance(1.2)
precondition(snapshots.dropFirst(count).allSatisfy { Set($0.map(\.id)) == [recovered.path, afterRecovery.path] })
count = snapshots.count
discovery.refresh()
discovery.stop()
_ = try writeApp(actual, "After stop")
advance(1.4)
precondition(snapshots.count == count, "stopped scan or watcher published stale results")
discovery.configure(roots: [], excluded: [])
precondition(has([]))
precondition(failures.isEmpty)
discovery.stop()
print("PASS application discovery: real FSEvents, alias/symlink deduplication, root replacement, add/remove, same-name paths, alternate names, keywords, custom alias and stale callback cancellation")
