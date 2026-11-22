import Foundation

@main struct AuthorityTests {
    static func main() {
        let broker = M0Broker(), seal = String(repeating: "a", count: 64)
        broker.install("a", seal: seal, initial: ["item": "synthetic-a"])
        broker.install("b", seal: seal, initial: ["item": "synthetic-b"])
        precondition(broker.admit("a", generation: 2, seal: seal) == nil)
        precondition(broker.admit("a", generation: 1, seal: String(repeating: "b", count: 64)) == nil)
        let a = broker.admit("a", generation: 1, seal: seal)!
        let b = broker.admit("b", generation: 1, seal: seal)!
        func request(_ id: Int, _ op: String = "storage.get", _ key: String = "item", value: String? = nil, extra: [String: Any] = [:]) -> Data {
            var object: [String: Any] = ["v": 1, "id": id, "op": op, "key": key]
            if let value { object["value"] = value }; object.merge(extra) { _, new in new }
            return try! JSONSerialization.data(withJSONObject: object)
        }
        func value(_ reply: Data) -> String? { (try! JSONSerialization.jsonObject(with: reply) as! [String: Any])["value"] as? String }
        func denied(_ reply: Data) -> Bool { reply == broker.denied }
        precondition(value(broker.handle(request(1), binding: a)) == "synthetic-a")
        precondition(value(broker.handle(request(1), binding: b)) == "synthetic-b")
        precondition(denied(broker.handle(request(1), binding: a)))
        precondition(denied(broker.handle(request(2, extra: ["owner": "b"]), binding: a)))
        precondition(denied(broker.handle(request(2, "storage.get", "../b/item"), binding: a)))
        precondition(denied(broker.handle(request(2, extra: ["id": true]), binding: a)))
        precondition(denied(broker.handle(Data(repeating: 32, count: 4097), binding: a)))
        precondition(value(broker.handle(request(2, "storage.set", value: "changed-a"), binding: a)) == "changed-a")
        precondition(broker.audit("b", key: "item") == "synthetic-b")
        let prepared = broker.prepare(request(3), binding: a)!
        broker.setEnabled("a", false); broker.setEnabled("a", true)
        precondition(denied(broker.publish(broker.execute(prepared))))
        precondition(denied(broker.handle(request(4), binding: a)))
        let fresh = broker.admit("a", generation: 1, seal: seal)!
        let reply = broker.execute(broker.prepare(request(1), binding: fresh)!)
        broker.revokeRead("a")
        precondition(denied(broker.publish(reply)))
        precondition(denied(broker.handle(request(2), binding: fresh)))
        let replay = broker.prepare(request(2), binding: b)!
        let once = broker.execute(replay)
        precondition(denied(broker.publish(broker.execute(replay))))
        precondition(value(broker.publish(once)) == "synthetic-b")
        precondition(denied(broker.publish(once)))
        let old = broker.prepare(request(3), binding: b)!
        _ = broker.prepare(request(4), binding: b)!
        precondition(denied(broker.publish(broker.execute(old))))
        broker.replace("b")
        precondition(denied(broker.handle(request(5), binding: b)))
        let replacement = broker.admit("b", generation: 2, seal: seal)!
        broker.close(replacement)
        precondition(denied(broker.handle(request(1), binding: replacement)))
        let removed = broker.admit("b", generation: 2, seal: seal)!
        broker.uninstall("b")
        precondition(denied(broker.handle(request(1), binding: removed)))
        broker.install("writes", seal: seal, initial: ["item": "original"])
        let writes = broker.admit("writes", generation: 1, seal: seal)!
        let pendingWrite = broker.prepare(request(1, "storage.set", value: "forbidden"), binding: writes)!
        broker.revokeWrite("writes")
        precondition(denied(broker.publish(broker.execute(pendingWrite))))
        precondition(broker.audit("writes", key: "item") == "original")
        let readOnly = broker.admit("writes", generation: 1, seal: seal)!
        precondition(denied(broker.handle(request(1, "storage.set", value: "forbidden"), binding: readOnly)))
        precondition(value(broker.handle(request(1), binding: readOnly)) == "original")
        broker.install("committed", seal: seal, initial: [:])
        let committed = broker.admit("committed", generation: 1, seal: seal)!
        let completed = broker.execute(broker.prepare(request(1, "storage.set", value: "committed"), binding: committed)!)
        broker.close(committed)
        precondition(denied(broker.publish(completed)))
        // Revocation withholds late replies; it does not undo a write committed
        // before revocation. Callers cannot infer failure means no side effect.
        precondition(broker.audit("committed", key: "item") == "committed")
        broker.install("budget", seal: seal, initial: [:])
        let budget = broker.admit("budget", generation: 1, seal: seal)!
        for _ in 0..<32 { precondition(denied(broker.handle(Data("{".utf8), binding: budget))) }
        precondition(broker.prepare(request(1), binding: budget) == nil)
        broker.install("external", seal: seal, initial: ["item":"external"], generation: 7)
        var live = false
        precondition(broker.admit("external", generation: 7, seal: seal, live: { live }) == nil)
        live = true
        let external = broker.admit("external", generation: 7, seal: seal, live: { live })!
        let pending = broker.prepare(request(1, "storage.set", value: "forbidden"), binding: external)!
        live = false
        precondition(denied(broker.publish(broker.execute(pending))))
        precondition(broker.audit("external", key: "item") == "external")
        live = true // observing false retires the binding permanently
        precondition(denied(broker.handle(request(2), binding: external)))
        let latest = broker.admit("external", generation: 7, seal: seal, live: { live })!
        let late = broker.execute(broker.prepare(request(1), binding: latest)!)
        live = false
        precondition(denied(broker.publish(late)))
        print("PASS broker admission, namespace, request/work/reply replay, off-on, prepare/execute/publish revocation, replace, close and uninstall")
    }
}
