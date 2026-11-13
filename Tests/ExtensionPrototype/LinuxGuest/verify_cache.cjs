const assert = require("node:assert/strict");
const { test } = require("node:test");
const { Cache, configureCache, setCacheWritesAllowed, takeCacheSnapshot, withCacheWritesBlocked } = require("./cache-api.cjs");
const { useCachedState, withCache } = require("./utilities-cache.cjs");

test("Cache shares a namespace and round-trips empty strings without exposing other namespaces", () => {
  configureCache({});
  const cache = new Cache();
  const shared = new Cache();
  const named = new Cache({ namespace: "test" });
  assert.equal(cache.isEmpty, true);
  assert.equal(cache.get("entry"), undefined);
  assert.equal(cache.has("entry"), false);
  assert.equal(takeCacheSnapshot(), undefined);
  cache.set("entry", "");
  named.set("entry", "other");
  const snapshot = takeCacheSnapshot();
  configureCache(JSON.parse(JSON.stringify(snapshot)));
  assert.equal(shared.get("entry"), "");
  assert.equal(cache.isEmpty, false);
  assert.equal(named.get("entry"), "other");
  assert.equal(shared.has("entry"), true);
  assert.equal(takeCacheSnapshot(), undefined);
  assert.equal(shared.remove("entry"), true);
  assert.equal(shared.remove("entry"), false);
  assert.equal(cache.isEmpty, true);
  named.clear();
  assert.deepEqual(takeCacheSnapshot(), {});
});

test("Cache applies namespace capacity in least-recently-used order", () => {
  configureCache({});
  const cache = new Cache({ capacity: 4 });
  const events = [];
  const unsubscribe = new Cache().subscribe((...args) => events.push(args));
  cache.set("a", "中");
  cache.set("b", "B");
  assert.equal(cache.get("a"), "中");
  assert.equal(cache.has("b"), true);
  cache.set("c", "C");
  assert.equal(cache.has("b"), false);
  assert.equal(cache.get("a"), "中");
  assert.deepEqual(events.slice(-2), [["b", undefined], ["c", "C"]]);
  cache.clear({ notifySubscribers: false });
  assert.equal(events.length, 4);
  cache.clear();
  assert.deepEqual(events.at(-1), [undefined, undefined]);
  unsubscribe();
  cache.set("a", "A");
  assert.equal(events.length, 5);
});

test("Cache wire keys preserve separate Unicode spellings across Swift dictionaries", () => {
  configureCache({});
  const cache = new Cache({ namespace: "中文" });
  cache.set("é", "composed");
  cache.set("e\u0301", "decomposed");
  assert.deepEqual(Object.keys(takeCacheSnapshot()), [
    '["\\u4e2d\\u6587","\\u00e9"]',
    '["\\u4e2d\\u6587","e\\u0301"]',
  ]);
  configureCache(takeCacheSnapshot());
  assert.equal(cache.get("é"), "composed");
  assert.equal(cache.get("e\u0301"), "decomposed");
});

test("Cache rejects malformed or oversize data atomically and blocks writes during sensitive actions", () => {
  configureCache({});
  const cache = new Cache();
  cache.set("💾", "x".repeat(2048));
  const original = takeCacheSnapshot();
  assert.throws(() => cache.set("bad", 7), /cache value/);
  assert.throws(() => cache.set("bad", "\uD800"), /cache value/);
  assert.throws(() => cache.set("x".repeat(129), "bad"), /cache key/);
  assert.throws(() => cache.set("over", "x".repeat(2048)), /size limit/);
  assert.deepEqual(takeCacheSnapshot(), original);
  setCacheWritesAllowed(false);
  assert.throws(() => cache.set("secret", "confidential"), /unavailable/);
  assert.throws(() => cache.remove("💾"), /unavailable/);
  assert.throws(() => cache.clear(), /unavailable/);
  assert.equal(takeCacheSnapshot(), undefined);
  assert.equal(cache.has("secret"), false);
  setCacheWritesAllowed(true);
  assert.deepEqual(takeCacheSnapshot(), original);
  assert.throws(() => configureCache({ example: "bad" }));
  assert.throws(() => cache.get("💾"), /unavailable/);
});

test("useCachedState shares values and applies functional updates against the latest state", () => {
  configureCache({});
  const [initial, set] = useCachedState("state", 2, { cacheNamespace: "settings" });
  assert.equal(initial, 2);
  set((value) => value + 2);
  const [shared, update] = useCachedState("state", 1, { cacheNamespace: "settings" });
  assert.equal(shared, 4);
  update((value) => value + 2);
  const snapshot = takeCacheSnapshot();
  configureCache(snapshot);
  assert.equal(useCachedState("state", 0, { cacheNamespace: "settings" })[0], 6);
  assert.equal(useCachedState("state", 0)[0], 0);
  const [, setUnset] = useCachedState("unset", "fallback");
  setUnset(undefined);
  assert.equal(useCachedState("unset", "fallback")[0], undefined);
});

test("Cache writes remain blocked in detached work from a replay or sensitive callback", async () => {
  configureCache({});
  const cache = new Cache();
  let detached;
  withCacheWritesBlocked(() => {
    assert.throws(() => cache.set("replay", "blocked"), /unavailable/);
    detached = new Promise((resolve) => {
      setImmediate(() => {
        assert.throws(() => cache.set("detached", "blocked"), /unavailable/);
        assert.equal(takeCacheSnapshot(), undefined);
        resolve();
      });
    });
  });
  cache.set("interactive", "allowed");
  await detached;
  assert.deepEqual(takeCacheSnapshot(), { '["","interactive"]': "allowed" });
});

test("withCache reuses results across invocations and honors validation, expiry and clearCache", async () => {
  let calls = 0;
  async function compute(value) { return [value, ++calls]; }
  configureCache({});
  const cached = withCache(compute);
  assert.deepEqual(await cached("a"), ["a", 1]);
  assert.deepEqual(await cached("b"), ["b", 2]);
  configureCache(takeCacheSnapshot());
  assert.deepEqual(await withCache(compute)("a"), ["a", 1]);
  const strict = withCache(compute, { validate: ([, count]) => count > 1 });
  assert.deepEqual(await strict("a"), ["a", 3]);
  const expired = Object.fromEntries(Object.entries(takeCacheSnapshot()).map(([key, value]) => [
    key, JSON.stringify({ ...JSON.parse(value), timestamp: 0 }),
  ]));
  configureCache(expired);
  assert.deepEqual(await withCache(compute, { maxAge: 10 })("a"), ["a", 4]);
  cached.clearCache();
  assert.deepEqual(takeCacheSnapshot(), {});
});

test("Cache presence checks stay read-only across namespaces and do not refresh LRU", () => {
  configureCache({});
  const cache = new Cache({ capacity: 2 });
  const other = new Cache({ namespace: "other" });
  cache.set("first", "1");
  cache.set("second", "2");
  assert.equal(cache.has("first"), true);
  assert.equal(cache.has("x".repeat(1024)), false);
  assert.equal(other.isEmpty, true);
  assert.equal(cache.isEmpty, false);
  cache.set("third", "3");
  assert.equal(cache.has("first"), false);
  configureCache(takeCacheSnapshot(), { writable: false });
  assert.equal(cache.has("third"), true);
  assert.equal(other.isEmpty, true);
  assert.equal(takeCacheSnapshot(), undefined);
});

test("ordered snapshots persist reads and same-value writes as LRU touches across runs", async () => {
  const key = (name) => JSON.stringify(["", name]);
  configureCache([[key("first"), "1"], [key("second"), "2"]]);
  const cache = new Cache({ capacity: 2 });
  assert.equal(await withCacheWritesBlocked(() => cache.get("first")), "1");
  assert.equal(takeCacheSnapshot(), undefined);
  assert.equal(cache.get("first"), "1");
  assert.deepEqual(takeCacheSnapshot(), [[key("second"), "2"], [key("first"), "1"]]);

  configureCache(takeCacheSnapshot());
  cache.set("second", "2");
  assert.deepEqual(takeCacheSnapshot(), [[key("first"), "1"], [key("second"), "2"]]);
  configureCache(takeCacheSnapshot());
  cache.set("third", "3");
  assert.equal(cache.has("first"), false);
  assert.equal(cache.get("x".repeat(300)), undefined);
  assert.equal(cache.remove("x".repeat(300)), false);
});

test("Cache subscriptions register and unsubscribe independently", () => {
  configureCache([]);
  const cache = new Cache();
  const events = [];
  const subscriber = (...event) => events.push(event);
  const first = cache.subscribe(subscriber);
  const second = cache.subscribe(subscriber);
  cache.set("a", "A");
  first();
  first();
  cache.remove("a");
  cache.clear({ notifySubscribers: false });
  cache.clear();
  second();
  cache.set("b", "B");
  assert.deepEqual(events, [["a", "A"], ["a", "A"], ["a", undefined], [undefined, undefined]]);
});
