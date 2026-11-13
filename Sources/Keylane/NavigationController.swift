import AppKit
import ApplicationServices
import Combine
import KeylaneCore

final class NavigationController: ObservableObject {
    @Published private(set) var results: [NavigationItem] = []
    @Published private(set) var targetName: String?
    @Published private(set) var status: Status = .loading
    @Published private(set) var incomplete = false
    @Published private(set) var performing = false
    @Published var selection = 0
    private var items: [NavigationItem] = []
    private var scanRequest: NavigationScanRequest?
    private var actionRequest: NavigationScanRequest?
    private var mode: NavigationMode?
    private let trusted: () -> Bool
    private let scan: (NavigationMode, NSRunningApplication?, NavigationScanRequest, @escaping (NavigationScan) -> Void) -> Void
    private let runAction: (NavigationItem, NavigationMode, NavigationScanRequest, @escaping (String?) -> Void) -> Void

    init(trusted: @escaping () -> Bool = AXIsProcessTrusted,
         scan: @escaping (NavigationMode, NSRunningApplication?, NavigationScanRequest, @escaping (NavigationScan) -> Void) -> Void = {
             SystemNavigation.shared.scan($0, target: $1, request: $2, completion: $3)
         },
         runAction: @escaping (NavigationItem, NavigationMode, NavigationScanRequest, @escaping (String?) -> Void) -> Void = {
             SystemNavigation.shared.perform($0, mode: $1, request: $2, completion: $3)
         }) {
        self.trusted = trusted
        self.scan = scan
        self.runAction = runAction
    }

    enum Status { case loading, permission, noApplication, ready }

    var query = "" { didSet { if oldValue != query { filter() } } }
    var selected: NavigationItem? { results.indices.contains(selection) ? results[selection] : nil }

    func load(_ mode: NavigationMode, target: NSRunningApplication?) {
        cancelAction()
        stop()
        self.mode = mode
        targetName = mode == .menus ? target?.localizedName : nil
        guard trusted() else { status = .permission; return }
        if mode == .menus && (target == nil || target?.isTerminated == true) {
            status = .noApplication
            return
        }
        status = .loading
        let request = NavigationScanRequest()
        scanRequest = request
        scan(mode, target, request) { [weak self] scan in
            guard let self, self.scanRequest === request, !request.isCancelled else { return }
            self.scanRequest = nil
            if mode == .menus, target?.isTerminated == true {
                self.targetName = nil
                self.status = .noApplication
                return
            }
            self.items = scan.items
            self.incomplete = scan.incomplete
            self.filter()
            self.status = .ready
        }
    }

    func permissionRequired() {
        cancelAction()
        stop()
        status = .permission
    }

    func stop() {
        scanRequest?.cancel()
        scanRequest = nil
        // Activating the selected app can hide the launcher before the AX call finishes.
        mode = nil
        items = []
        if !results.isEmpty { results = [] }
        selection = 0
        incomplete = false
        targetName = nil
    }

    func stopModule() {
        cancelAction()
        stop()
        query = ""
    }

    private func cancelAction() {
        actionRequest?.cancel()
        actionRequest = nil
        if performing { performing = false }
    }

    func move(_ delta: Int) {
        let next = NavigationBounds.move(selection, by: delta, count: results.count)
        if next != selection { selection = next }
    }

    func select(_ item: NavigationItem) -> Bool {
        guard let index = results.firstIndex(where: { $0.identity == item.identity }) else { return false }
        selection = index
        return true
    }

    func perform(_ item: NavigationItem, mode: NavigationMode, completion: @escaping (String?) -> Void) {
        guard !performing, self.mode == mode, selected?.identity == item.identity else { return }
        performing = true
        let request = NavigationScanRequest()
        actionRequest = request
        runAction(item, mode, request) { [weak self] message in
            guard let self, self.actionRequest === request else { return }
            self.actionRequest = nil
            self.performing = false
            completion(message)
        }
    }

    private func filter() {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            results = items
        } else {
            let preparedQuery = SearchRanker.Query(needle)
            results = items.compactMap { item -> (NavigationItem, Int)? in
                let title = SearchRanker.score(SearchRanker.prepareName(item.title), query: preparedQuery)
                let path = SearchRanker.score(SearchRanker.prepareName(item.detail), query: preparedQuery).map { $0 - 250 }
                let combined = SearchRanker.score(SearchRanker.prepareName(item.detail + " " + item.title),
                                                query: preparedQuery).map { $0 - 300 }
                let shortcut = item.keys.joined() == needle ? 1100 : nil
                guard let score = [title, path, combined, shortcut].compactMap({ $0 }).max() else { return nil }
                return (item, score)
            }.sorted { $0.1 > $1.1 }.map(\.0)
        }
        selection = 0
    }
}
