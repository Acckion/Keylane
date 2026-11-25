import Foundation

/// Extension-local cache scoped to an installation and its enrolled profile.
struct MacOSReviewedRaycastCache: Sendable {
    static let capability = "cache.write"
    static let maximumBytes = 32 * 1024

    let root: URL

    func read(for ticket: StoreGuestRunTicket) throws -> String {
        let path = file(installationID: ticket.installation.id)
        let descriptor = Darwin.open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor == -1 && errno == ENOENT { return "[]" }
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_size <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        try Self.validate(data)
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ data: Data, for ticket: StoreGuestRunTicket) throws {
        try Self.validate(data)
        try data.write(to: file(installationID: ticket.installation.id), options: .atomic)
    }

    static func validate(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let entries = try ExtensionCacheTransport.entries(data)
        var keys = Set<Data>()
        for entry in entries {
            let key = Data(entry[0].utf8)
            guard key.allSatisfy({ $0 < 128 }), keys.insert(key).inserted,
                  let pair = try? JSONDecoder().decode([String].self, from: key), (2...3).contains(pair.count),
                  pair.allSatisfy({ $0.utf8.count <= 128 }),
                  pair.count == 2 || Self.validDirectory(pair[2]),
                  entry[1].utf8.count <= 16 * 1024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
    }

    private static func validDirectory(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return path.hasPrefix("/support/") && !path.contains("\\") && !path.contains("\0") &&
            parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0 != "cache" }
    }

    func remove(installationID: UUID) {
        _ = Darwin.unlink(file(installationID: installationID.uuidString).path)
    }

    private func file(installationID: String) -> URL {
        let digest = MacOSExtensionBuild.hash(Data(installationID.utf8))
        return root.appendingPathComponent("cache-\(digest).json")
    }
}

extension MacOSReviewedRaycastCache {
    static let source = #"""
    const maximumSnapshotBytes = 32 * 1024;
    const maximumEntries = 64;
    const maximumNameBytes = 128;
    const maximumValueBytes = 16 * 1024;
    const unpairedSurrogate = /[\uD800-\uDFFF]/u;
    const encode = new TextEncoder();
    const byteLength = value => encode.encode(value).length;
    const nativeCacheRead = globalThis.keylane.cacheSnapshot;
    const nativeCacheWrite = globalThis.keylane.updateCache;
    let cacheScope;

    function currentScope() {
      if (typeof nativeCacheRead !== "string" || typeof nativeCacheWrite !== "function") {
        throw new Error("Cache is unavailable for this extension invocation");
      }
      return cacheScope ??= { entries: new Map(JSON.parse(nativeCacheRead)), subscribers: new Map() };
    }

    function save(entries) {
      if (!nativeCacheWrite(validateSize(entries))) throw new Error("Updating cache is unavailable");
    }

    function validateString(value, bytes, description) {
      if (typeof value !== "string" || unpairedSurrogate.test(value) || byteLength(value) > bytes) {
        throw new TypeError(`Invalid ${description}`);
      }
      return value;
    }

    const defaultCacheParent = "/support";
    const cacheName = "cache";
    function cacheParent(path) {
      if (path === defaultCacheParent) return path;
      if (typeof path !== "string" || !path.startsWith("/support/") || byteLength(path) > maximumNameBytes ||
          /[\\\u0000]/u.test(path) || path.slice(1).split("/").some(part => !part || part === "." || part === ".." || part === cacheName)) {
        throw new TypeError("Expected an installation-scoped cache directory");
      }
      return path;
    }

    function wireKey(namespace, key, parent) {
      const fields = [namespace, validateString(key, maximumNameBytes, "cache key")];
      if (parent !== defaultCacheParent) fields.push(parent);
      const tuple = JSON.stringify(fields);
      // ASCII wire keys preserve distinct Unicode spellings in Swift dictionaries.
      return tuple.replace(/[^\x00-\x7F]/g, (character) => `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`);
    }

    function validateSize(entries) {
      const snapshot = JSON.stringify([...entries]);
      if (entries.size > maximumEntries || byteLength(snapshot) > maximumSnapshotBytes) {
        throw new RangeError("Extension cache exceeds the reviewed size limit");
      }
      return snapshot;
    }


    function cacheKeyMatches(encoded, namespace, parent) {
      const [name, , directory = defaultCacheParent] = JSON.parse(encoded);
      return namespace === name && parent === directory;
    }

    function namespaceEntries(entries, namespace, parent) {
      return [...entries].filter(([encoded]) => cacheKeyMatches(encoded, namespace, parent));
    }

    function lookupKey(namespace, key, parent) {
      if (typeof key !== "string") throw new TypeError("Invalid cache key");
      if (unpairedSurrogate.test(key) || byteLength(key) > maximumNameBytes) return undefined;
      return wireKey(namespace, key, parent);
    }

    function notify(cache, namespace, key, data) {
      const subscribers = cache.subscribers.get(namespace);
      if (subscribers) for (const callback of [...subscribers]) callback(key, data);
    }


    export function __keylaneReadCacheIndex(path) {
      if (typeof nativeCacheRead !== "string" || !path.endsWith("/" + cacheName + "/entries.json")) return undefined;
      const parent = cacheParent(path.slice(0, -("/" + cacheName + "/entries.json").length));
      return JSON.stringify([...currentScope().entries].filter(([encoded]) =>
        (JSON.parse(encoded)[2] ?? defaultCacheParent) === parent));
    }

    export class Cache {
      static get STORAGE_DIRECTORY_NAME() { return cacheName; }
      static get DEFAULT_CAPACITY() { return 10 * 1024 * 1024; }

      #namespace;
      #capacity;
      #parent;
      #subscriptionKey;

      constructor({ namespace = "", capacity = Cache.DEFAULT_CAPACITY, directory } = {}) {
        this.#namespace = validateString(namespace, maximumNameBytes, "cache namespace");
        if (!Number.isSafeInteger(capacity) || capacity < 0) throw new RangeError("Invalid cache capacity");
        this.#parent = cacheParent(directory ?? defaultCacheParent);
        this.#subscriptionKey = JSON.stringify([this.#parent, this.#namespace]);
        this.#capacity = capacity;
      }

      get storageDirectory() {
        return this.#parent + "/" + cacheName;
      }

      get(key) {
        const cache = currentScope();
        const encoded = lookupKey(this.#namespace, key, this.#parent);
        const data = cache.entries.get(encoded);
        if (data !== undefined &&
            namespaceEntries(cache.entries, this.#namespace, this.#parent).at(-1)?.[0] !== encoded) {
          const entries = new Map(cache.entries);
          entries.delete(encoded);
          entries.set(encoded, data);
          save(entries);
          cache.entries = entries;
        }
        return data;
      }

      has(key) {
        return currentScope().entries.has(lookupKey(this.#namespace, key, this.#parent));
      }

      get isEmpty() {
        for (const encoded of currentScope().entries.keys()) {
          if (cacheKeyMatches(encoded, this.#namespace, this.#parent)) return false;
        }
        return true;
      }

      set(key, data) {
        const cache = currentScope(true);
        const encoded = wireKey(this.#namespace, key, this.#parent);
        validateString(data, maximumValueBytes, "cache value");
        const entries = new Map(cache.entries);
        entries.delete(encoded);
        entries.set(encoded, data);
        const scoped = namespaceEntries(entries, this.#namespace, this.#parent);
        let totalBytes = scoped.reduce((total, [, value]) => total + byteLength(value), 0);
        const evicted = [];
        for (const [candidate, value] of scoped) {
          if (totalBytes <= this.#capacity) break;
          entries.delete(candidate);
          totalBytes -= byteLength(value);
          evicted.push(JSON.parse(candidate)[1]);
        }
        validateSize(entries);
        save(entries);
        cache.entries = entries;
        for (const removed of evicted) notify(cache, this.#subscriptionKey, removed, undefined);
        if (entries.has(encoded)) notify(cache, this.#subscriptionKey, key, data);
      }

      remove(key) {
        const cache = currentScope(true);
        const entries = new Map(cache.entries);
        const removed = entries.delete(lookupKey(this.#namespace, key, this.#parent));
        if (removed) {
          save(entries);
          cache.entries = entries;
          notify(cache, this.#subscriptionKey, key, undefined);
        }
        return removed;
      }

      clear({ notifySubscribers = true } = {}) {
        const cache = currentScope(true);
        const entries = new Map(cache.entries);
        for (const [encoded] of namespaceEntries(entries, this.#namespace, this.#parent)) entries.delete(encoded);
        if (entries.size !== cache.entries.size) {
          save(entries);
          cache.entries = entries;
        }
        if (notifySubscribers) notify(cache, this.#subscriptionKey, undefined, undefined);
      }

      subscribe(callback) {
        const cache = currentScope();
        if (typeof callback !== "function") throw new TypeError("Invalid cache subscriber");
        const namespace = this.#subscriptionKey;
        let subscribers = cache.subscribers.get(namespace);
        if (!subscribers) {
          subscribers = new Set();
          cache.subscribers.set(namespace, subscribers);
        }
        const subscription = (...args) => callback(...args);
        subscribers.add(subscription);
        return () => { subscribers.delete(subscription); };
      }
    }
    """#
}
