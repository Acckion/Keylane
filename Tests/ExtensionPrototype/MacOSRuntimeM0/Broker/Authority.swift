import Foundation
import CoreFoundation

// First-party M0 authority, confined to the parent's serial native request loop.
// Not connected to product installation/user storage; not a concurrent service.
final class M0Broker {
    struct Record {
        var generation: UInt64 = 1
        var epoch = UUID()
        var enabled = true
        var read = true
        var write = true
        let seal: String
    }
    final class Binding {
        fileprivate let token = UUID()
        fileprivate init() {}
    }
    private struct Lease {
        let installation: String
        let generation: UInt64
        let epoch: UUID
        var sequence: UInt64 = 0
        var remaining = 32
    }
    struct Prepared {
        fileprivate let token: UUID
        fileprivate let sequence: UInt64
        fileprivate let op: String
        fileprivate let key: String
        fileprivate let value: String?
    }
    struct Reply {
        fileprivate let token: UUID
        fileprivate let sequence: UInt64
        fileprivate let value: String?
        fileprivate let error: String?
    }
    private var records: [String: Record] = [:]
    private var leases: [UUID: Lease] = [:]
    private var storage: [String: [String: String]] = [:]
    private var executed: Set<UUID> = []
    private var currentWork: [UUID: UUID] = [:]
    private var replyWork: [UUID: UUID] = [:]

    func install(_ id: String, seal: String, initial: [String: String]) {
        precondition(records[id] == nil && seal.utf8.count == 64)
        records[id] = Record(seal: seal)
        storage[id] = initial
    }
    func admit(_ id: String, generation: UInt64, seal: String) -> Binding? {
        guard let record = records[id], record.enabled, record.generation == generation, record.seal == seal else { return nil }
        let binding = Binding()
        leases[binding.token] = Lease(installation: id, generation: generation, epoch: record.epoch)
        return binding
    }
    private func current(_ token: UUID) -> Lease? {
        guard let lease = leases[token], let record = records[lease.installation], record.enabled,
              record.generation == lease.generation, record.epoch == lease.epoch else { return nil }
        return lease
    }
    func setEnabled(_ id: String, _ enabled: Bool) {
        guard var record = records[id], record.enabled != enabled else { return }
        record.enabled = enabled; record.epoch = UUID(); records[id] = record
    }
    func revokeRead(_ id: String) {
        guard var record = records[id] else { return }
        record.read = false; record.epoch = UUID(); records[id] = record
    }
    func revokeWrite(_ id: String) {
        guard var record = records[id] else { return }
        record.write = false; record.epoch = UUID(); records[id] = record
    }
    func replace(_ id: String) {
        guard var record = records[id] else { return }
        record.generation += 1; record.epoch = UUID(); records[id] = record
    }
    func close(_ binding: Binding) {
        leases.removeValue(forKey: binding.token)
        if let work = currentWork.removeValue(forKey: binding.token) { executed.remove(work) }
        replyWork.removeValue(forKey: binding.token)
    }
    func uninstall(_ id: String) {
        records.removeValue(forKey: id)
        // Preserve synthetic data here: uninstall policy is outside this experiment.
    }
    private func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 64 && key != "." && key != ".." &&
        key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }
    }
    func prepare(_ data: Data, binding: Binding) -> Prepared? {
        guard var lease = current(binding.token), lease.remaining > 0 else { return nil }
        lease.remaining -= 1
        leases[binding.token] = lease // denied traffic also consumes the bounded connection budget
        guard data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["v", "id", "op", "key", "value"]),
              let version = object["v"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let number = object["id"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 9_007_199_254_740_991,
              number.doubleValue.rounded(.towardZero) == number.doubleValue, number.uint64Value > lease.sequence,
              let op = object["op"] as? String, ["storage.get", "storage.set"].contains(op),
              let key = object["key"] as? String, validKey(key),
              let record = records[lease.installation], (op == "storage.get" ? record.read : record.write) else { return nil }
        let value = object["value"] as? String
        guard (op == "storage.get" && object["value"] == nil) || (op == "storage.set" && value != nil && value!.utf8.count <= 512) else { return nil }
        lease.sequence = number.uint64Value; leases[binding.token] = lease
        // A later request supersedes any unexecuted/prepared reply. Work IDs never
        // come from a guest; they prevent replay of a prepared native operation.
        if let work = currentWork[binding.token] { executed.remove(work) }
        let work = UUID(); currentWork[binding.token] = work; replyWork.removeValue(forKey: binding.token)
        return Prepared(token: binding.token, sequence: lease.sequence, op: op, key: key, value: value)
    }
    func execute(_ work: Prepared) -> Reply {
        guard let lease = current(work.token), lease.sequence == work.sequence,
              let id = currentWork[work.token], !executed.contains(id),
              let record = records[lease.installation], work.op == "storage.get" ? record.read : record.write else {
            return Reply(token: work.token, sequence: work.sequence, value: nil, error: "denied")
        }
        executed.insert(id); replyWork[work.token] = id
        if work.op == "storage.set" { storage[lease.installation, default: [:]][work.key] = work.value }
        return Reply(token: work.token, sequence: work.sequence, value: storage[lease.installation]?[work.key], error: nil)
    }
    func publish(_ reply: Reply) -> Data {
        guard let lease = current(reply.token), lease.sequence == reply.sequence,
              currentWork[reply.token] == replyWork[reply.token], replyWork[reply.token] != nil,
              reply.error == nil else { return denied }
        replyWork.removeValue(forKey: reply.token)
        return try! JSONSerialization.data(withJSONObject: ["ok": true, "value": reply.value.map { $0 as Any } ?? NSNull()])
    }
    var denied: Data { Data("{\"ok\":false,\"error\":\"denied\"}".utf8) }
    func handle(_ data: Data, binding: Binding) -> Data {
        guard let prepared = prepare(data, binding: binding) else { return denied }
        return publish(execute(prepared))
    }
    // Trusted fixture audit only, never exported to the script.
    func audit(_ id: String, key: String) -> String? { storage[id]?[key] }
}
