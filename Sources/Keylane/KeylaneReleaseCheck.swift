import AppKit
import Combine
import KeylaneCore

final class KeylaneReleaseCheck: ObservableObject {
    static let releasesURL = URL(string: "https://github.com/Acckion/Keylane/releases")!

    struct Update: Equatable {
        let release: GitHubUpdateRelease
        let build: Int
        var page: URL { releasesURL.appendingPathComponent("tag").appendingPathComponent(release.tag) }
        func asset(_ name: String) -> URL {
            releasesURL.appendingPathComponent("download").appendingPathComponent(release.tag).appendingPathComponent(name)
        }
    }

    @Published var automatic = UserDefaults.standard.bool(forKey: "keylane.updates.automatic") {
        didSet {
            UserDefaults.standard.set(automatic, forKey: "keylane.updates.automatic")
            settingsChanged()
        }
    }
    @Published var includePrereleases = UserDefaults.standard.bool(forKey: "keylane.updates.prereleases") {
        didSet {
            UserDefaults.standard.set(includePrereleases, forKey: "keylane.updates.prereleases")
            settingsChanged()
        }
    }
    @Published private(set) var status = "可以从 GitHub 检查更新。"
    @Published private(set) var busy = false
    @Published private(set) var available: Update?
    @Published private(set) var ready = false
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var prepared: PreparedKeylaneUpdate?

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 12 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkAutomatically()
        }
        if automatic { checkAutomatically() }
    }

    func stop() {
        timer?.invalidate()
        task?.cancel()
    }

    func check() {
        guard !busy, !ready else { return }
        available = nil
        status = "正在检查更新…"
        busy = true
        let allowPrereleases = includePrereleases
        task = Task { @MainActor in
            do {
                let result = try await Self.latest(includePrereleases: allowPrereleases)
                try Task.checkCancellation()
                guard let result else {
                    status = allowPrereleases ? "暂无可用的 GitHub 更新。" : "暂无可用的正式版。"
                    busy = false
                    return
                }
                guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                      let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) else {
                    status = "无法识别当前构建。"
                    busy = false
                    return
                }
                guard result.release.isNewer(build: result.build, than: version, build: build) else {
                    status = "当前已是所选渠道的最新版本。"
                    busy = false
                    return
                }
                available = result
                status = "发现 \(result.release.tag)（构建 \(result.build)）。"
                busy = false
                if automatic && PreparedKeylaneUpdate.currentTeam != nil { download() }
            } catch {
                guard !Task.isCancelled else { return }
                busy = false
                status = "检查更新失败。\(error.localizedDescription)"
            }
        }
    }

    func download() {
        guard let update = available, !busy, !ready else { return }
        busy = true
        status = "正在从 GitHub 下载并验证更新…"
        task = Task { @MainActor in
            do {
                let staged = try await PreparedKeylaneUpdate.prepare(update)
                try Task.checkCancellation()
                prepared = staged
                ready = true
                status = automatic ? "更新已就绪，下次退出 Keylane 时安装。" : "更新已就绪，可以重启并安装。"
            } catch {
                guard !Task.isCancelled else { return }
                status = "无法在应用内安装。\(error.localizedDescription) 可手动下载 DMG。"
            }
            busy = false
        }
    }

    func installAndRestart() {
        guard let prepared else { return }
        do {
            try prepared.install(relaunch: true)
            self.prepared = nil
            ready = false
            NSApp.terminate(nil)
        } catch {
            status = "安装失败。\(error.localizedDescription)"
        }
    }

    func installOnQuit() {
        stop()
        guard automatic, let prepared else { return }
        do { try prepared.install(relaunch: false) }
        catch { NSLog("Keylane update could not be installed: %@", error.localizedDescription) }
    }

    private func settingsChanged() {
        task?.cancel()
        prepared = nil
        available = nil
        busy = false
        ready = false
        status = "可以从 GitHub 检查更新。"
        if automatic { checkAutomatically() }
    }

    private func checkAutomatically() {
        guard automatic else { return }
        check()
    }

    private struct Manifest: Decodable {
        let version: String
        let build: Int
    }

    private static func latest(includePrereleases: Bool) async throws -> Update? {
        var releases: [GitHubUpdateRelease] = []
        var page = 1
        while true {
            let url = URL(string: "https://api.github.com/repos/Acckion/Keylane/releases?per_page=100&page=\(page)")!
            let batch: [GitHubUpdateRelease] = try await get(url)
            releases += batch
            if batch.count < 100 { break }
            page += 1
        }
        guard let release = GitHubUpdateRelease.latest(in: releases, includePrereleases: includePrereleases) else {
            return nil
        }
        let root = URL(string: "https://raw.githubusercontent.com/Acckion/Keylane")!
        let manifest: Manifest = try await get(root.appendingPathComponent(release.tag).appendingPathComponent("version.json"))
        guard manifest.version == release.version, manifest.build > 0 else { throw URLError(.cannotDecodeContentData) }
        return Update(release: release, build: manifest.build)
    }

    private static func get<Value: Decodable>(_ url: URL) async throws -> Value {
        let request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 20)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
