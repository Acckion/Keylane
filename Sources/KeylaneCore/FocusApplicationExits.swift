import Foundation

/// Pending normal termination belongs to the requesting session, not whichever
/// session happens to be active when the application eventually exits.
public struct FocusApplicationExits: Codable, Equatable, Sendable {
    public struct Process: Codable, Hashable, Sendable {
        public var pid: Int32
        public var launched: Date
        public init(pid: Int32, launched: Date) { self.pid = pid; self.launched = launched }
    }
    public struct Receipt: Codable, Equatable, Sendable {
        public var process: Process
        public var application: FocusApplication
        public var url: URL
        public var session: UUID
        public var restore: Bool?
        public var exited = false
    }
    public private(set) var receipts: [Receipt] = []
    public private(set) var attempted: Set<Process> = []
    public init() {}
    public mutating func request(_ process: Process, application: FocusApplication, url: URL, session: UUID) -> Bool {
        guard attempted.insert(process).inserted else { return false }
        receipts.append(.init(process: process, application: application, url: url, session: session))
        return true
    }
    public mutating func rejected(_ process: Process) { receipts.removeAll { $0.process == process } }
    public mutating func observedExit(_ process: Process) {
        for index in receipts.indices where receipts[index].process == process { receipts[index].exited = true }
        attempted.remove(process)
    }
    public mutating func finish(_ session: UUID, restore: Bool) {
        for index in receipts.indices where receipts[index].session == session { receipts[index].restore = restore }
        receipts.removeAll { $0.restore == false && $0.exited }
    }
    public mutating func transfer(_ old: UUID, to new: UUID) {
        for index in receipts.indices where receipts[index].session == old { receipts[index].session = new }
    }
    public func restorable(blocked: (String) -> Bool) -> [Receipt] {
        receipts.filter { $0.exited && $0.restore == true && !blocked($0.application.id) }
    }
    public mutating func restored(_ process: Process) { receipts.removeAll { $0.process == process } }
    public mutating func reconcile(_ process: Process, running: Bool, launched: Date?) {
        // Missing launch metadata for a still-running process is not proof of exit.
        if !running || (launched != nil && launched != process.launched) { observedExit(process) }
    }
}
