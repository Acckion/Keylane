import Foundation
import Darwin

/// A durable intent bridges the module transaction and the journal checkpoint. After a crash,
/// an already applied entity is acknowledged without turning the imported value into a new edit.
public enum SyncEngine {
    private struct Recovery: Codable { let category: SyncCategory; let id: String; let payload: Data; let replacedBy: SyncStamp; let savedAt: Date }
    private struct Intent: Codable { let entry: SyncEntry; let previous: String? }
    public static func run(local: URL, transport: SyncDriveTransport, participants: [SyncParticipant], name: String, deviceID: UUID? = nil,
                           allowed: () -> Bool = { true }, didApply: (SyncCategory) -> Void = { _ in }) throws -> ([SyncManifest], [SyncCategory: Int], Set<SyncCategory>) {
        let fm = FileManager.default
        try fm.createDirectory(at: local, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = local.appendingPathComponent("sync.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SyncError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw SyncError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        let checkpoint = local.appendingPathComponent("journal.json")
        var journal = fm.fileExists(atPath: checkpoint.path) ? try JSONDecoder().decode(SyncJournal.self, from: Data(contentsOf: checkpoint)) : SyncJournal(device: deviceID ?? UUID())
        func save() throws {
            let data = try SyncHash.encode(journal)
            if fm.fileExists(atPath: checkpoint.path), try Data(contentsOf: checkpoint) == data { return }
            try data.write(to: checkpoint, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: checkpoint.path)
        }
        let intents = local.appendingPathComponent("Intents", isDirectory: true)
        try fm.createDirectory(at: intents, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var changed = Set<SyncCategory>(), completedIntents: [URL] = []
        let unfinished = try fm.contentsOfDirectory(at: intents, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard unfinished.count <= 100_000 else { throw SyncError.limit }
        for pending in unfinished.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let module = participants.first(where: { pending.lastPathComponent.hasPrefix($0.category.rawValue + "-") }) else { continue }
            guard allowed(), (try pending.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 65536 else { throw SyncError.cancelled }
            let intent = try JSONDecoder().decode(Intent.self, from: Data(contentsOf: pending))
            guard intent.entry.category == module.category else { throw SyncError.invalidData }
            let observedFingerprint = try module.fingerprint(id: intent.entry.id)
            let current = try module.current(id: intent.entry.id).map(SyncHash.digest)
            if current == intent.previous || current == intent.entry.digest {
                let data = try intent.entry.digest.map(transport.load)
                do {
                    let applied = try module.applyIfUnchanged(id: intent.entry.id, data: data, fingerprint: observedFingerprint)
                    journal.applied(intent.entry, fingerprint: applied)
                } catch SyncError.cancelled {
                    journal.applied(intent.entry) // Discover the concurrent local edit below.
                }
            } else {
                // A user edit made while an intent waited must remain a new local edit.
                journal.applied(intent.entry)
            }
            completedIntents.append(pending)
            changed.insert(module.category); didApply(module.category)
        }
        // One checkpoint per batch. Intent files survive until it succeeds, avoiding a full
        // O(history size) journal rewrite for every imported item.
        try save()
        for pending in completedIntents { try fm.removeItem(at: pending) }
        completedIntents = []
        let remote = try transport.manifests()
        try journal.observeClock(remote)
        let remoteKeys = Set(remote.flatMap(\.entries).map(\.key))
        var snapshots: [SyncCategory: SyncLocalSnapshot] = [:], counts: [SyncCategory: Int] = [:]
        for module in participants {
            guard allowed() else { throw SyncError.cancelled }
            let snapshot = try module.snapshot(); snapshots[module.category] = snapshot; counts[module.category] = snapshot.payloads.count
            // A newly joined device's defaults do not replace an existing cloud entity.
            // Local-only additions are merged; conflicts are backed up before cloud restoration.
            let observed = snapshot.payloads.filter { id, _ in
                journal.contains(category: module.category, id: id) || !remoteKeys.contains(module.category.rawValue + ":" + id)
            }
            var digests: [String: String] = [:]
            for (id, payload) in observed where journal.needsPayload(category: module.category, id: id, fingerprint: payload.fingerprint) {
                guard allowed() else { throw SyncError.cancelled }
                digests[id] = try transport.store(payload.read())
            }
            try journal.observe(category: module.category, fingerprints: observed.mapValues(\.fingerprint), digests: digests,
                                explicitDeletions: snapshot.deletions, inferDeletions: snapshot.inferDeletions)
        }
        let updates = try journal.merge(remote, categories: Set(participants.map(\.category)))
        try save()
        for entry in updates {
            guard allowed(), let module = participants.first(where: { $0.category == entry.category }) else { throw SyncError.cancelled }
            let data = try entry.digest.map(transport.load)
            let original = snapshots[entry.category]?.payloads[entry.id]
            let old = try original?.read()
            guard try module.fingerprint(id: entry.id) == original?.fingerprint else { throw SyncError.cancelled }
            if let old, SyncHash.digest(old) != entry.digest {
                let recovery = local.appendingPathComponent("Recovery", isDirectory: true)
                try fm.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let backup = Recovery(category: entry.category, id: entry.id, payload: old, replacedBy: entry.stamp, savedAt: .now)
                try SyncHash.encode(backup).write(to: recovery.appendingPathComponent(entry.category.rawValue + "-" + SyncHash.digest(old) + ".json"), options: .atomic)
            }
            guard allowed() else { throw SyncError.cancelled }
            let pending = intents.appendingPathComponent(entry.category.rawValue + "-" + SyncHash.digest(Data(entry.key.utf8)) + ".json")
            try SyncHash.encode(Intent(entry: entry, previous: old.map(SyncHash.digest))).write(to: pending, options: .atomic)
            do {
                let applied = try module.applyIfUnchanged(id: entry.id, data: data, fingerprint: original?.fingerprint)
                journal.applied(entry, fingerprint: applied)
            } catch SyncError.cancelled {
                // The cloud event has been observed, but a newer local write won the gate.
                // Keep its old baseline so the next pass publishes that local edit.
                journal.applied(entry); try save(); try fm.removeItem(at: pending)
                throw SyncError.cancelled
            }
            completedIntents.append(pending)
            changed.insert(entry.category); didApply(entry.category)
        }
        guard allowed() else { throw SyncError.cancelled }
        try save()
        for pending in completedIntents { try fm.removeItem(at: pending) }
        let manifest = journal.manifest(name: name)
        // Preserve the last *published* paused state, not an interrupted pass's unsent edits.
        let selected = Set(participants.map(\.category))
        var paused: [String: SyncEntry] = [:]
        for document in remote where document.device == journal.device {
            for entry in document.entries where !selected.contains(entry.category) {
                if paused[entry.key].map({ $0.stamp >= entry.stamp }) != true { paused[entry.key] = entry }
            }
        }
        var published = manifest
        published.entries = (manifest.entries.filter { selected.contains($0.category) } + paused.values).sorted { $0.key < $1.key }
        let previous = remote.filter { $0.device == journal.device }.max { $0.updated < $1.updated }
        if let previous, previous.entries.sorted(by: { $0.key < $1.key }) == published.entries,
           previous.deviceName == published.deviceName, Date().timeIntervalSince(previous.updated) < 300 {
            published.updated = previous.updated
        } else { try transport.publish(published) }
        for module in participants where changed.contains(module.category) { counts[module.category] = try module.snapshot().payloads.count }
        let otherDevices = Dictionary(grouping: remote.filter { $0.device != manifest.device }, by: \.device)
            .values.compactMap { $0.max { $0.updated < $1.updated } }.sorted { $0.updated > $1.updated }
        return ([published] + otherDevices, counts, changed)
    }
}
