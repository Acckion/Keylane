const { createHash } = require("node:crypto");
const { Cache, cacheAvailable, cacheWritesBlocked } = require("./cache-api.cjs");

const halfLifeMilliseconds = 7 * 24 * 60 * 60 * 1000;
const maximumRankedItems = 24;
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

function writeCache(cache, key, data) {
  if (!cacheAvailable() || cacheWritesBlocked()) return;
  let encoded;
  try {
    encoded = JSON.stringify(data);
  } catch {
    // Preserve this run's value when it cannot be represented in the cache.
    return;
  }
  if (encoded === undefined || Buffer.byteLength(encoded) > 2048) return;
  try {
    cache.set(key, encoded);
  } catch (error) {
    // Hitting the extension's shared cache budget does not invalidate fresh data.
    if (!(error instanceof RangeError)) throw error;
  }
}

function elapsedScore(entry, now) {
  return entry ? entry.score * 2 ** (-Math.max(0, now - entry.updated) / halfLifeMilliseconds) : 0;
}

function ranking(cache) {
  const entries = readCache(cache, "ranking");
  const valid = entries && typeof entries === "object" && !Array.isArray(entries) ? Object.entries(entries) : [];
  return new Map(valid.filter(([, entry]) => entry && Number.isFinite(entry.score) &&
    entry.score > 0 && Number.isFinite(entry.updated)));
}

function useFrecencySorting(data = [], { namespace = "", key = (item) => item.id, sortUnvisited } = {}) {
  if (typeof namespace !== "string") throw new TypeError("Expected a string frecency namespace");
  const cache = new Cache({ namespace: `frecency:${hash(namespace)}` });
  function itemKey(item) {
    const id = key(item);
    if (typeof id !== "string") throw new TypeError("Frecency items require a string key");
    return hash(id).slice(0, 32);
  }

  const visited = ranking(cache);
  const now = Date.now();
  const sorted = data.map((item) => ({ item, score: elapsedScore(visited.get(itemKey(item)), now) }))
    .sort((first, second) => second.score - first.score ||
      (!first.score && !second.score ? (sortUnvisited?.(first.item, second.item) ?? 0) : 0))
    .map(({ item }) => item);

  return {
    data: sorted,
    async visitItem(item) {
      const current = ranking(cache);
      const id = itemKey(item);
      const timestamp = Date.now();
      current.set(id, { score: elapsedScore(current.get(id), timestamp) + 1, updated: timestamp });
      const highest = [...current].sort(([, a], [, b]) => elapsedScore(b, timestamp) - elapsedScore(a, timestamp));
      writeCache(cache, "ranking", Object.fromEntries(highest.slice(0, maximumRankedItems)));
    },
    async resetRanking(item) {
      const current = ranking(cache);
      if (current.delete(itemKey(item))) writeCache(cache, "ranking", Object.fromEntries(current));
    },
  };
}

function utilitiesRuntimeHooksFor(apiProvider, usePromise) {
  function useCachedPromise(fn, args = [], options = {}) {
    const { environment } = apiProvider();
    const namespace = hash(JSON.stringify([environment?.entryPointName, Function.prototype.toString.call(fn)]));
    const cache = new Cache({ namespace: `promise:${namespace}` });
    let key;
    try {
      key = hash(JSON.stringify(args));
    } catch {
      // Nonserializable arguments still work for the current run.
    }

    const state = usePromise(fn, args, {
      ...options,
      execute: options.execute !== false && !cacheWritesBlocked(),
      onData(data) {
        if (key !== undefined) writeCache(cache, key, data);
        options.onData?.(data);
      },
    }, () => key === undefined ? undefined : readCache(cache, key));

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
