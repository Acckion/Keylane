const { createHash } = require("node:crypto");
const { serialize, deserialize } = require("node:v8");
const { deflateRawSync, inflateRawSync } = require("node:zlib");
const { Cache, cacheAvailable, cacheWritesBlocked, readCachedState, writeCachedState } = require("./cache-api.cjs");

function hash(text) {
  return createHash("sha256").update(text).digest("hex");
}

function argumentKey(args) {
  const digest = createHash("sha256");
  const seen = new Map();
  let remainingBytes = 1024 * 1024;
  function token(type, value) {
    // Encoding each record as JSON preserves boundaries and the exact JavaScript code units.
    const record = JSON.stringify([type, value]) + "\n";
    remainingBytes -= Buffer.byteLength(record);
    if (remainingBytes < 0) throw new RangeError("Cache arguments exceed the hashing limit");
    digest.update(record);
  }

  function visit(value) {
    if (value === null) return token("null");
    const type = typeof value;
    if (type === "number") return token(type, Object.is(value, -0) ? "-0" : String(value));
    if (type === "symbol") {
      const key = Symbol.keyFor(value);
      if (key === undefined) throw new TypeError("A local symbol has no stable cache identity");
      return token(type, key);
    }
    if (type === "bigint") return token(type, String(value));
    if (type !== "object" && type !== "function") return token(type, value);
    if (seen.has(value)) return token("reference", seen.get(value));
    seen.set(value, seen.size);

    if (Array.isArray(value)) {
      token("array", value.length);
      for (let index = 0; index < value.length; index++) {
        if (Object.hasOwn(value, index)) visit(value[index]);
        else token("hole");
      }
      return;
    }
    if (value instanceof Date) return token("date", String(value.getTime()));
    if (value instanceof RegExp) return token("regexp", [value.source, value.flags]);
    if (value instanceof ArrayBuffer) return token("arraybuffer", Buffer.from(value).toString("base64"));
    if (ArrayBuffer.isView(value)) {
      const bytes = Buffer.from(value.buffer, value.byteOffset, value.byteLength);
      return token(value.constructor.name, bytes.toString("base64"));
    }
    if (value instanceof Map) {
      token("map", value.size);
      for (const [key, item] of value) { visit(key); visit(item); }
      return;
    }
    if (value instanceof Set) {
      token("set", value.size);
      for (const item of value) visit(item);
      return;
    }
    if (type === "function") token("function", [value.name, Function.prototype.toString.call(value)]);
    else {
      const prototype = Object.getPrototypeOf(value);
      if (prototype !== null && prototype !== Object.prototype) {
        // Objects with hidden state such as WeakMap cannot be compared by enumerable fields.
        throw new TypeError("Unsupported cache argument");
      }
      token("object", prototype === null);
    }
    const properties = Object.keys(value).sort();
    token("properties", properties.length);
    for (const key of properties) {
      token("key", key);
      visit(value[key]);
    }
  }
  visit(args);
  return "v2:" + digest.digest("hex");
}

const typedStatePrefix = "typed:";
const stateValueMarker = "~keylane:";

function serializeState(value) {
  if (value === undefined) return "undefined";
  let typed = false;
  const json = JSON.stringify(value, function (key, data) {
    const original = this[key];
    if (original instanceof Date) {
      typed = true;
      return stateValueMarker + "date:" + original.toISOString();
    }
    if (Buffer.isBuffer(original)) {
      typed = true;
      return stateValueMarker + "buffer:" + original.toString("base64");
    }
    if (typeof data === "string" && data.startsWith(stateValueMarker)) {
      typed = true;
      return stateValueMarker + "text:" + data;
    }
    return data;
  });
  if (json === undefined) throw new TypeError("Cached state values must be JSON serializable");
  return typed ? typedStatePrefix + json : json;
}

function restoreStateValue(_key, value) {
  if (typeof value !== "string" || !value.startsWith(stateValueMarker)) return value;
  const encoded = value.slice(stateValueMarker.length);
  if (encoded.startsWith("date:")) return new Date(encoded.slice(5));
  if (encoded.startsWith("buffer:")) return Buffer.from(encoded.slice(7), "base64");
  if (encoded.startsWith("text:")) return encoded.slice(5);
  return value;
}

function readState(cache, namespace, key, fallback) {
  const data = readCachedState(cache, namespace, key);
  if (data === undefined) return fallback;
  if (data === "undefined") return undefined;
  try {
    return data.startsWith(typedStatePrefix)
      ? JSON.parse(data.slice(typedStatePrefix.length), restoreStateValue)
      : JSON.parse(data);
  } catch {
    return fallback;
  }
}

function useCachedState(key, initialState, { cacheNamespace = "", cacheWriteDebounce } = {}) {
  const cache = new Cache({ namespace: cacheNamespace });
  const setState = (update) => {
    const value = typeof update === "function" ? update(readState(cache, cacheNamespace, key, initialState)) : update;
    writeCachedState(cache, cacheNamespace, key, serializeState(value), cacheWriteDebounce);
  };
  return [readState(cache, cacheNamespace, key, initialState), setState];
}

const compressionThreshold = 1024;
const maximumResultBytes = 1024 * 1024;

function encodeCacheResult(result) {
  const bytes = serialize(result);
  if (bytes.length > maximumResultBytes) throw new RangeError("Cached result exceeds the serialization limit");
  const timestamp = Date.now();
  if (bytes.length >= compressionThreshold) {
    const compressed = deflateRawSync(bytes);
    const encodedSavings = 4 * (Math.ceil(bytes.length / 3) - Math.ceil(compressed.length / 3));
    if (encodedSavings > ',"encoding":"deflate-raw"'.length) {
      return { timestamp, payload: compressed.toString("base64"), encoding: "deflate-raw" };
    }
  }
  return { timestamp, payload: bytes.toString("base64") };
}

function decodeCacheResult(entry) {
  const bytes = Buffer.from(entry.payload, "base64");
  if (entry.encoding === undefined) return deserialize(bytes);
  if (entry.encoding === "deflate-raw") {
    return deserialize(inflateRawSync(bytes, { maxOutputLength: maximumResultBytes }));
  }
  throw new TypeError("Unknown cache encoding");
}

function withCache(fn, { maxAge, validate } = {}) {
  if (typeof fn !== "function") throw new TypeError("Invalid cache function");
  if (validate !== undefined && typeof validate !== "function") throw new TypeError("Invalid cache validator");
  if (maxAge !== undefined && (typeof maxAge !== "number" || !Number.isFinite(maxAge) || maxAge < 0)) {
    throw new RangeError("Invalid cache maximum age");
  }
  const cache = new Cache({ namespace: `function:${hash(Function.prototype.toString.call(fn))}` });
  const wrapped = async function (...args) {
    if (!cacheAvailable()) return fn.apply(this, args);
    let key;
    try {
      key = argumentKey(args);
    } catch {
      return fn.apply(this, args);
    }
    const data = cache.get(key);
    let cached;
    if (data !== undefined) {
      try {
        const entry = JSON.parse(data);
        if (Number.isFinite(entry.timestamp) && (!maxAge || Date.now() - entry.timestamp <= maxAge)) {
          cached = { value: decodeCacheResult(entry) };
        }
      } catch {
        // Invalid or unreadable entries are cache misses.
      }
    }
    if (cached && (validate === undefined || validate(cached.value))) return cached.value;
    const result = await fn.apply(this, args);
    if (!cacheWritesBlocked() && cacheAvailable()) {
      // A cache miss still returns the wrapped function's result when it cannot be stored.
      try {
        cache.set(key, JSON.stringify(encodeCacheResult(result)));
      } catch {
        // A non-serializable or oversized result is recomputed next time.
      }
    }
    return result;
  };
  wrapped.clearCache = () => {
    if (cacheAvailable() && !cacheWritesBlocked()) cache.clear();
  };
  return wrapped;
}

module.exports = { useCachedState, withCache, argumentKey, readState, serializeState };
