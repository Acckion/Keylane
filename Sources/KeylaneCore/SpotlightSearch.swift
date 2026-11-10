import Foundation
import CoreServices

public struct SpotlightFile: Identifiable, Equatable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let modified: Date
    public init(url: URL, name: String, modified: Date) { self.url = url; self.name = name; self.modified = modified }
}

/// Searches the existing Spotlight index. Own and call this service on the main thread.
public final class SpotlightSearch {
    public var updated: (([SpotlightFile], String) -> Void)?
    private var query: MDQuery?
    private var observers: [NSObjectProtocol] = []
    private var compatibilityProcess: Process?
    private var pending: DispatchWorkItem?
    private var generation = 0
    private var homeOnly = false
    private var root: URL?
    public init() {}
    deinit { cancel() }
    public static func predicate(for text: String) -> NSPredicate? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256 else { return nil }
        let literal = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
        return NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*" + literal + "*")
    }
    public static func expression(for text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256 else { return nil }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
        return "kMDItemFSName == \"*" + escaped + "*\"cd"
    }
    public func search(_ text: String, homeOnly: Bool = false, root: URL? = nil) {
        cancel()
        self.homeOnly = homeOnly
        self.root = root
        guard Self.predicate(for: text) != nil else {
            updated?([], text.count > 256 ? "文件名搜索最多256个字符。" : "输入文件名，搜索Spotlight已索引的文件。")
            return
        }
        let version = generation
        updated?([], "正在查询Spotlight…")
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == version else { return }
            guard let expression = Self.expression(for: text),
                  let query = MDQueryCreate(kCFAllocatorDefault, expression as CFString, nil, nil) else {
                self.updated?([], "Spotlight查询无法创建。"); return
            }
            if let root { MDQuerySetSearchScope(query, [root.path] as CFArray, 0) }
            else { MDQuerySetSearchScope(query, [homeOnly ? kMDQueryScopeHome! : kMDQueryScopeComputerIndexed!] as CFArray, 0) }
            MDQuerySetDispatchQueue(query, .main)
            MDQuerySetMaxCount(query, 1000)
            self.query = query
            let progress = Notification.Name(rawValue: kMDQueryProgressNotification as String)
            for name in [progress, Notification.Name(rawValue: kMDQueryDidFinishNotification as String), Notification.Name(rawValue: kMDQueryDidUpdateNotification as String)] {
                self.observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] note in
                    guard let self, self.generation == version else { return }
                    self.snapshot(query, text: text, finished: note.name != progress)
                })
            }
            if !MDQueryExecute(query, CFOptionFlags(kMDQueryWantsUpdates.rawValue)) { self.cancel(); self.updated?([], "Spotlight查询无法启动。请检查系统索引与文件访问权限。") }

        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    private func snapshot(_ query: MDQuery, text: String, finished: Bool) {
        MDQueryDisableUpdates(query)
        var files: [SpotlightFile] = []
        var seen = Set<String>()
        let count = MDQueryGetResultCount(query)
        let predicate = Self.predicate(for: text)
        // Inspect at most 1000 indexed metadata records; only retain 200 display results.
        for index in 0..<min(count, 1000) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension.lowercased() != "app", !url.lastPathComponent.hasPrefix("."), seen.insert(url.path).inserted,
                  predicate?.evaluate(with: [NSMetadataItemFSNameKey: url.lastPathComponent]) == true else { continue }
            let name = MDItemCopyAttribute(item, kMDItemDisplayName) as? String ?? url.lastPathComponent
            files.append(SpotlightFile(url: url, name: name, modified: MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date ?? .distantPast))
        }
        MDQueryEnableUpdates(query)
        files.sort {
            let a = SearchRanker.score($0.name, query: text) ?? 0
            let b = SearchRanker.score($1.name, query: text) ?? 0
            if a != b { return a > b }
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.id < $1.id
        }
        let truncated = files.count > 200 || count >= 1000
        let results = Array(files.prefix(200))
        if results.isEmpty && finished {
            compatibilitySearch(text)
            return
        }
        let status: String
        if results.isEmpty { status = finished ? "没有匹配项。Spotlight未索引或隐私排除的文件不会出现。" : "正在收集Spotlight结果…" }
        else { status = truncated ? "显示\(results.count)项（候选较多）；请增加关键词缩小范围。" : "\(results.count)项 · Spotlight\(finished ? "" : " · 正在收集")" }
        updated?(results, status)
    }
    private func compatibilitySearch(_ text: String) {
        guard compatibilityProcess == nil, let expression = Self.expression(for: text) else { return }
        let version = generation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        let directory = root?.path ?? (homeOnly ? FileManager.default.homeDirectoryForCurrentUser.path : nil)
        process.arguments = ["-0"] + (directory.map { ["-onlyin", $0] } ?? []) + [expression]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { updated?([], "系统Spotlight兼容查询无法启动。"); return }
        compatibilityProcess = process
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var data = Data()
            var limited = false
            while let chunk = try? output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                if data.count + chunk.count > 1_048_576 { limited = true; if process.isRunning { process.terminate() }; break }
                data.append(chunk)
            }
            process.waitUntilExit()
            let paths = data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
            DispatchQueue.main.async {
                guard let self, self.generation == version else { return }
                self.compatibilityProcess = nil
                if process.terminationStatus != 0 && !limited { self.updated?([], "系统Spotlight查询失败，请检查索引与文件访问权限。"); return }
                let predicate = Self.predicate(for: text)
                let files = paths.prefix(1000).compactMap { path -> SpotlightFile? in
                    let url = URL(fileURLWithPath: path)
                    guard url.pathExtension.lowercased() != "app", !url.lastPathComponent.hasPrefix("."),
                          predicate?.evaluate(with: [NSMetadataItemFSNameKey: url.lastPathComponent]) == true else { return nil }
                    return SpotlightFile(url: url, name: url.lastPathComponent, modified: .distantPast)
                }.sorted { a, b in
                    let lhs = SearchRanker.score(a.name, query: text) ?? 0
                    let rhs = SearchRanker.score(b.name, query: text) ?? 0
                    return lhs == rhs ? a.id < b.id : lhs > rhs
                }
                let results = Array(files.prefix(200))
                let suffix = limited || paths.count > 200 ? " · 请缩小关键词" : ""
                self.updated?(results, results.isEmpty ? "没有匹配项。系统未索引或隐私排除的文件不会出现。" : "\(results.count)项 · Spotlight兼容查询\(suffix)")
            }
        }
    }
    public func cancel() {
        generation += 1
        pending?.cancel(); pending = nil
        if let process = compatibilityProcess, process.isRunning { process.terminate() }; compatibilityProcess = nil
        if let query { MDQueryStop(query) }; query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
    }
}
