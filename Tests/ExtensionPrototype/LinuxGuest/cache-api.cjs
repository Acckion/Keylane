const { AsyncLocalStorage } = require("node:async_hooks");

const maximumSnapshotBytes = 4096;
const maximumEntries = 64;
const maximumNameBytes = 128;
const maximumValueBytes = 2048;
const unpairedSurrogate = /[\uD800-\uDFFF]/u;
const cacheWriteBlock = new AsyncLocalStorage();
const currentViewInput = Symbol("currentViewInput");

let scope;

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
  scope = { entries, subscribers: new Map(), writable, changed: false, ordered };
}

function setCacheWritesAllowed(allowed) {
  if (scope) scope.writable = allowed;
}

function withCacheWritesBlocked(callback) {
  return cacheWriteBlock.run(true, callback);
}

function withCurrentViewInput(callback) {
  const parent = cacheWriteBlock.getStore();
  return cacheWriteBlock.run(parent === true || parent?.active === false ? true : currentViewInput, callback);
}

function withCacheWriteLifetime(lifetime, callback) {
  const parent = cacheWriteBlock.getStore();
  return cacheWriteBlock.run(parent === true || parent === currentViewInput || parent?.active === false ? parent : lifetime, callback);
}

function cacheAvailable() {
  return scope !== undefined;
}

function cacheWritesBlocked() {
  const guard = cacheWriteBlock.getStore();
  return scope?.writable === false || guard === true || guard === currentViewInput || guard?.active === false;
}

function cachedQueriesBlocked() {
  const guard = cacheWriteBlock.getStore();
  return scope?.writable === false || guard === true || guard?.active === false;
}

function takeCacheSnapshot() {
  if (!scope?.writable || !scope.changed || cacheWriteBlock.getStore()) return undefined;
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
    cache.entries = entries;
    for (const removed of evicted) notify(cache, this.#namespace, removed, undefined);
    if (entries.has(encoded)) notify(cache, this.#namespace, key, data);
  }

  remove(key) {
    const cache = currentScope(true);
    const removed = cache.entries.delete(lookupKey(this.#namespace, key));
    if (removed) {
      cache.changed = true;
      notify(cache, this.#namespace, key, undefined);
    }
    return removed;
  }

  clear({ notifySubscribers = true } = {}) {
    const cache = currentScope(true);
    for (const [encoded] of namespaceEntries(cache.entries, this.#namespace)) {
      cache.entries.delete(encoded);
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

module.exports = { Cache, configureCache, setCacheWritesAllowed, takeCacheSnapshot, withCacheWritesBlocked, withCurrentViewInput, withCacheWriteLifetime, cacheAvailable, cacheWritesBlocked, cachedQueriesBlocked };
