const { createHash } = require("node:crypto");
const { Cache, cacheAvailable, writeCache } = require("./cache-api.cjs");

function hash(text) {
  return createHash("sha256").update(text).digest("hex");
}

function readState(cache, key, fallback) {
  const data = cache.get(key);
  if (data === undefined) return fallback;
  if (data === "undefined") return undefined;
  try {
    return JSON.parse(data);
  } catch {
    return fallback;
  }
}

function useCachedState(key, initialState, { cacheNamespace } = {}) {
  const cache = new Cache({ namespace: cacheNamespace });
  const setState = (update) => {
    const value = typeof update === "function" ? update(readState(cache, key, initialState)) : update;
    const data = value === undefined ? "undefined" : JSON.stringify(value);
    if (data === undefined) throw new TypeError("Cached state values must be JSON serializable");
    cache.set(key, data);
  };
  return [readState(cache, key, initialState), setState];
}

function withCache(fn, { maxAge, validate } = {}) {
  if (typeof fn !== "function") throw new TypeError("Invalid cache function");
  if (validate !== undefined && typeof validate !== "function") throw new TypeError("Invalid cache validator");
  if (maxAge !== undefined && (typeof maxAge !== "number" || !Number.isFinite(maxAge) || maxAge < 0)) {
    throw new RangeError("Invalid cache maximum age");
  }
  const cache = new Cache({ namespace: `function:${hash(Function.prototype.toString.call(fn))}` });
  const wrapped = async function (...args) {
    const key = hash(JSON.stringify(args));
    const data = cacheAvailable() ? cache.get(key) : undefined;
    let entry;
    if (data !== undefined) {
      try { entry = JSON.parse(data); } catch { /* A corrupt entry is a cache miss. */ }
    }
    if (Number.isFinite(entry?.timestamp)
        && (maxAge === undefined || Date.now() - entry.timestamp <= maxAge)
        && (validate === undefined || validate(entry.result))) {
      return entry.result;
    }
    const result = await fn.apply(this, args);
    writeCache(cache, key, { timestamp: Date.now(), result });
    return result;
  };
  wrapped.clearCache = () => cache.clear();
  return wrapped;
}

module.exports = { useCachedState, withCache };
