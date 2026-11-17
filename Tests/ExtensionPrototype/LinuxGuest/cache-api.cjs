const { AsyncLocalStorage } = require("node:async_hooks");

const maximumSnapshotBytes = 32 * 1024;
const maximumEntries = 64;
const maximumNameBytes = 128;
const maximumValueBytes = 16 * 1024;
const unpairedSurrogate = /[\uD800-\uDFFF]/u;
const cacheWriteBlock = new AsyncLocalStorage();

let scope;
let stateRevision = 0;

function validateString(value, bytes, description) {
  if (typeof value !== "string" || unpairedSurrogate.test(value) || Buffer.byteLength(value) > bytes) {
    throw new TypeError(`Invalid ${description}`);
  }
  return value;
}

function wireKey(namespace, key) {
  const tuple = JSON.stringify([namespace, validateString(key, maximumNameBytes, "cache key")]);
  // ASCII wire keys preserve distinct Unicode spellings in Swift dictionaries.
  return tuple.replace(/[^\x00-\x7F]/g, (character) => `\\u${character.charCodeAt(0).toString(16).padStart(4, "0")}`);
}

function validateSize(entries) {
  const snapshot = Object.fromEntries(entries);
  if (entries.size > maximumEntries || Buffer.byteLength(JSON.stringify(snapshot)) > maximumSnapshotBytes) {
    throw new RangeError("Extension cache exceeds the reviewed size limit");
  }
  return snapshot;
}

function configureCache(snapshot, { writable = true } = {}) {
  for (const pending of scope?.pending.values() ?? []) clearTimeout(pending.timer);
  scope = undefined;
  if (snapshot === undefined) return;
  if (!snapshot || typeof snapshot !== "object") throw new TypeError("Invalid extension cache snapshot");
  const ordered = Array.isArray(snapshot);
  const pairs = ordered ? snapshot : Object.entries(snapshot);
  if (pairs.length > maximumEntries ||
      pairs.some((pair) => !Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== "string")) {
    throw new TypeError("Invalid extension cache entries");
  }
  const entries = new Map(pairs);
  if (entries.size !== pairs.length) throw new TypeError("Duplicate extension cache keys");
  validateSize(entries);
  for (const [encoded, data] of entries) {
    const pair = JSON.parse(encoded);
    if (!Array.isArray(pair) || pair.length !== 2) throw new TypeError("Invalid extension cache entry");
    const namespace = validateString(pair[0], maximumNameBytes, "cache namespace");
    if (wireKey(namespace, pair[1]) !== encoded) throw new TypeError("Invalid extension cache entry");
    validateString(data, maximumValueBytes, "cache value");
  }
  scope = { entries, subscribers: new Map(), pending: new Map(), writable, changed: false, ordered };
}

function setCacheWritesAllowed(allowed) {
  if (scope) scope.writable = allowed;
}

function withCacheWritesBlocked(callback) {
  return cacheWriteBlock.run(true, callback);
}

function withCacheWriteLifetime(lifetime, callback) {
  return cacheWriteBlock.run(cacheWriteBlock.getStore() === true ? true : lifetime, callback);
}

function cacheAvailable() {
  return scope !== undefined;
}

function cacheWritesBlocked() {
  const guard = cacheWriteBlock.getStore();
  return scope?.writable === false || guard === true || guard?.active === false;
}

function hasCacheChanges() {
  return scope?.writable === true && !cacheWriteBlock.getStore() && (scope.changed || scope.pending.size > 0);
}

function cacheStateRevision() {
  return stateRevision;
}

function commitCachedState(cache, encoded, pending) {
  if (scope !== cache || cache.pending.get(encoded) !== pending) return;
  cache.pending.delete(encoded);
  // The update was validated in its original write context and belongs to this invocation.
  if (cache.writable) cacheWriteBlock.exit(() => pending.target.set(pending.key, pending.value));
}

function takeCacheSnapshot({ flushPending = false } = {}) {
  if (!scope?.writable || cacheWriteBlock.getStore()) return undefined;
  if (flushPending) {
    if (scope.pendingError) throw scope.pendingError;
    for (const [encoded, pending] of scope.pending) {
      clearTimeout(pending.timer);
      commitCachedState(scope, encoded, pending);
    }
  }
  if (!scope.changed) return undefined;
  const snapshot = validateSize(scope.entries);
  return scope.ordered ? [...scope.entries] : snapshot;
}

function currentScope(writing = false) {
  if (!scope) throw new Error("Cache is unavailable for this extension invocation");
  if (writing && cacheWritesBlocked()) throw new Error("Cache changes are unavailable in this context");
  return scope;
}

function namespaceEntries(entries, namespace) {
  return [...entries].filter(([encoded]) => JSON.parse(encoded)[0] === namespace);
}

function lastKeyInNamespace(entries, namespace) {
  return namespaceEntries(entries, namespace).at(-1)?.[0];
}

function lookupKey(namespace, key) {
  if (typeof key !== "string") throw new TypeError("Invalid cache key");
  if (unpairedSurrogate.test(key) || Buffer.byteLength(key) > maximumNameBytes) return undefined;
  return wireKey(namespace, key);
}

function notify(cache, namespace, key, data) {
  const subscribers = cache.subscribers.get(namespace);
  if (subscribers) for (const callback of [...subscribers]) callback(key, data);
}

function readCachedState(target, namespace, key) {
  return currentScope().pending.get(lookupKey(namespace, key))?.value ?? target.get(key);
}

function writeCachedState(target, namespace, key, value, delay) {
  const scope = currentScope(true);
  const encoded = wireKey(namespace, key);
  const previous = scope.pending.get(encoded);
  if (!(delay >= 0) || !Number.isFinite(delay)) {
    target.set(key, value);
    clearTimeout(previous?.timer);
    if (scope.pending.delete(encoded)) stateRevision++;
    return;
  }

  validateString(value, maximumValueBytes, "cache value");
  const projected = new Map(scope.entries);
  for (const [pendingKey, pending] of scope.pending) projected.set(pendingKey, pending.value);
  projected.set(encoded, value);
  validateSize(projected);

  clearTimeout(previous?.timer);
  const pending = { target, key, value };
  pending.timer = setTimeout(() => {
    try {
      commitCachedState(scope, encoded, pending);
    } catch (error) {
      scope.pendingError = error;
    }
  }, Math.min(delay, 2 ** 31 - 1));
  pending.timer.unref();
  scope.pending.set(encoded, pending);
  stateRevision++;
}

class Cache {
  static get DEFAULT_CAPACITY() { return 10 * 1024 * 1024; }

  #namespace;
  #capacity;

  constructor({ namespace = "", capacity = Cache.DEFAULT_CAPACITY, directory } = {}) {
    this.#namespace = validateString(namespace, maximumNameBytes, "cache namespace");
    if (!Number.isSafeInteger(capacity) || capacity < 0) throw new RangeError("Invalid cache capacity");
    if (directory !== undefined) throw new Error("Custom cache directories are unavailable in Keylane");
    this.#capacity = capacity;
  }

  get storageDirectory() {
    throw new Error("The Keylane extension cache has no guest filesystem directory");
  }

  get(key) {
    const cache = currentScope();
    const encoded = lookupKey(this.#namespace, key);
    const data = cache.entries.get(encoded);
    if (data !== undefined && !cacheWritesBlocked() &&
        lastKeyInNamespace(cache.entries, this.#namespace) !== encoded) {
      cache.entries.delete(encoded);
      cache.entries.set(encoded, data);
      // Older object snapshots preserve in-run order only.
      cache.changed ||= cache.ordered;
    }
    return data;
  }

  has(key) {
    return currentScope().entries.has(lookupKey(this.#namespace, key));
  }

  get isEmpty() {
    for (const encoded of currentScope().entries.keys()) {
      if (JSON.parse(encoded)[0] === this.#namespace) return false;
    }
    return true;
  }

  set(key, data) {
    const cache = currentScope(true);
    const encoded = wireKey(this.#namespace, key);
    validateString(data, maximumValueBytes, "cache value");
    const entries = new Map(cache.entries);
    entries.delete(encoded);
    entries.set(encoded, data);
    const scoped = namespaceEntries(entries, this.#namespace);
    let totalBytes = scoped.reduce((total, [, value]) => total + Buffer.byteLength(value), 0);
    const evicted = [];
    for (const [candidate, value] of scoped) {
      if (totalBytes <= this.#capacity) break;
      entries.delete(candidate);
      totalBytes -= Buffer.byteLength(value);
      evicted.push(JSON.parse(candidate)[1]);
    }
    validateSize(entries);
    cache.changed ||= evicted.length > 0 || cache.entries.get(encoded) !== data ||
      (cache.ordered && lastKeyInNamespace(cache.entries, this.#namespace) !== encoded);
    if (evicted.length || entries.get(encoded) !== cache.entries.get(encoded)) stateRevision++;
    cache.entries = entries;
    for (const removed of evicted) notify(cache, this.#namespace, removed, undefined);
    if (entries.has(encoded)) notify(cache, this.#namespace, key, data);
  }

  remove(key) {
    const cache = currentScope(true);
    const removed = cache.entries.delete(lookupKey(this.#namespace, key));
    if (removed) {
      stateRevision++;
      cache.changed = true;
      notify(cache, this.#namespace, key, undefined);
    }
    return removed;
  }

  clear({ notifySubscribers = true } = {}) {
    const cache = currentScope(true);
    for (const [encoded] of namespaceEntries(cache.entries, this.#namespace)) {
      cache.entries.delete(encoded);
      stateRevision++;
      cache.changed = true;
    }
    if (notifySubscribers) notify(cache, this.#namespace, undefined, undefined);
  }

  subscribe(callback) {
    const cache = currentScope();
    if (typeof callback !== "function") throw new TypeError("Invalid cache subscriber");
    const namespace = this.#namespace;
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

module.exports = { Cache, configureCache, setCacheWritesAllowed, takeCacheSnapshot, withCacheWritesBlocked, withCacheWriteLifetime, cacheAvailable, cacheWritesBlocked,
  hasCacheChanges, cacheStateRevision, readCachedState, writeCachedState };
