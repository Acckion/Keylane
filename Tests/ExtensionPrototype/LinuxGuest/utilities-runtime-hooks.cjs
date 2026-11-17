const { createHash } = require("node:crypto");
const { serialize, deserialize } = require("node:v8");
const { Cache, cacheAvailable, cacheWritesBlocked, writeCachedState } = require("./cache-api.cjs");

const { argumentKey, readState, serializeState } = require("./utilities-cache.cjs");

const millisecondsPerDay = 24 * 60 * 60 * 1000;
const rankingHalfLife = 10 * millisecondsPerDay;
const legacyHalfLife = 7 * millisecondsPerDay;
const visitPoints = 100;
const rankingBytes = 16 * 1024;
const DeeplinkType = Object.freeze({ ScriptCommand: "script-command", Extension: "extension" });

function hash(text) {
  return createHash("sha256").update(text).digest("hex");
}

function readCache(cache, key) {
  if (!cacheAvailable()) return undefined;
  const encoded = cache.get(key);
  if (encoded === undefined) return undefined;
  try {
    return JSON.parse(encoded);
  } catch {
    return undefined;
  }
}

function writeCache(cache, key, data, maximumBytes = 2048) {
  if (!cacheAvailable() || cacheWritesBlocked()) return;
  let encoded;
  try {
    encoded = JSON.stringify(data);
  } catch {
    // Preserve this run's value when it cannot be represented in the cache.
    return;
  }
  if (encoded === undefined || Buffer.byteLength(encoded) > maximumBytes) return;
  try {
    cache.set(key, encoded);
  } catch (error) {
    // Hitting the extension's shared cache budget does not invalidate fresh data.
    if (!(error instanceof RangeError)) throw error;
  }
}

function ranking(cache, now) {
  const stored = readCache(cache, "ranking");
  const entries = new Map();
  if (!stored || typeof stored !== "object" || Array.isArray(stored)) return entries;

  for (const [key, value] of Object.entries(stored)) {
    if (!/^[a-f0-9]{32}$/.test(key)) continue;
    if (Number.isFinite(value)) {
      entries.set(key, value);
    } else if (value && Number.isFinite(value.score) && value.score > 0 && Number.isFinite(value.updated)) {
      // Preserve each old score at the current time before switching its decay rate.
      const decay = Math.max(0, now - value.updated) / legacyHalfLife;
      const rank = now + rankingHalfLife * (Math.log2(value.score) + Math.log2(visitPoints) - decay);
      if (Number.isFinite(rank)) entries.set(key, rank);
    }
  }
  return entries;
}

function persistRanking(cache, ranking) {
  const retained = Object.create(null);
  let available = rankingBytes - 2; // Braces around all entries.
  for (const [key, value] of [...ranking].sort(([, a], [, b]) => b - a)) {
    const bytes = Buffer.byteLength(JSON.stringify(key)) + Buffer.byteLength(JSON.stringify(value)) + 2;
    if (bytes > available) break;
    retained[key] = value;
    available -= bytes;
  }
  writeCache(cache, "ranking", retained, rankingBytes);
}

function useFrecencySorting(data = [], { namespace = "", key = (item) => item.id, sortUnvisited } = {}) {
  if (typeof namespace !== "string") throw new TypeError("Expected a string frecency namespace");
  const cache = new Cache({ namespace: `frecency:${hash(namespace)}` });
  function itemKey(item) {
    const id = key(item);
    if (typeof id !== "string") throw new TypeError("Frecency items require a string key");
    return hash(id).slice(0, 32);
  }

  const visited = ranking(cache, Date.now());
  const sorted = data.map((item) => ({ item, rank: visited.get(itemKey(item)) }))
    .sort((first, second) => {
      if (first.rank === undefined && second.rank === undefined) {
        return sortUnvisited?.(first.item, second.item) ?? 0;
      }
      if (first.rank === undefined) return 1;
      if (second.rank === undefined) return -1;
      return second.rank - first.rank;
    })
    .map(({ item }) => item);

  return {
    data: sorted,
    async visitItem(item) {
      const now = Date.now();
      const current = ranking(cache, now);
      const id = itemKey(item);
      const previous = current.get(id);
      const score = previous === undefined ? 0 : 2 ** ((previous - now) / rankingHalfLife);
      const rank = now + rankingHalfLife * Math.log2(score + visitPoints);
      if (Number.isFinite(rank)) {
        current.set(id, rank);
        persistRanking(cache, current);
      }
    },
    async resetRanking(item) {
      const current = ranking(cache, Date.now());
      if (current.delete(itemKey(item))) persistRanking(cache, current);
    },
  };
}

function utilitiesRuntimeHooksFor(apiProvider, usePromise) {
  function useCachedPromise(fn, args = [], options = {}) {
    const signature = hash(Function.prototype.toString.call(fn));
    const namespace = `promise:${signature}`;
    const cache = new Cache({ namespace });
    let key;
    try {
      key = argumentKey(args);
    } catch {
      // Nonserializable arguments still work for the current run.
    }

    function save(value) {
      if (key === undefined || !cacheAvailable() || cacheWritesBlocked()) return;
      try {
        writeCachedState(cache, namespace, key, serializeState(value), options.cacheWriteDebounce);
      } catch (error) {
        // Unsupported values and a full cache do not discard the live Promise result.
        if (!(error instanceof TypeError) && !(error instanceof RangeError)) throw error;
      }
    }

    const state = usePromise(fn, args, {
      ...options,
      execute: options.execute !== false && !cacheWritesBlocked(),
      onData(data, pagination) {
        if (!pagination || pagination.page === 0) save(data);
        options.onData?.(data, pagination);
      },
    }, {
      read: (fallback) => key === undefined || !cacheAvailable() ? fallback : readState(cache, namespace, key, fallback),
      writeMutation: save,
      cloneMutation: (value) => deserialize(serialize(value)),
    });

    return {
      ...state,
      async revalidate() {
        if (!cacheWritesBlocked()) await state.revalidate();
      },
      async mutate(update, settings) {
        if (cacheWritesBlocked()) throw new Error("Cache mutations are unavailable while reconstructing a view");
        return state.mutate(update, settings);
      },
    };
  }

  return { useCachedPromise, useFrecencySorting, DeeplinkType };
}

module.exports = { utilitiesRuntimeHooksFor };
