const assert = require("node:assert/strict");
const { test } = require("node:test");
const { randomBytes } = require("node:crypto");
const { deflateRawSync } = require("node:zlib");
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
  cache.set("💾", "x".repeat(16384));
  const original = takeCacheSnapshot();
  assert.throws(() => cache.set("bad", 7), /cache value/);
  assert.throws(() => cache.set("bad", "\uD800"), /cache value/);
  assert.throws(() => cache.set("x".repeat(129), "bad"), /cache key/);
  assert.throws(() => cache.set("over", "x".repeat(16384)), /size limit/);
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

test("reviewed no-view commands load cache before execution and stage only completed writes", async (t) => {
  const api = require("./raycast-api.cjs");
  const baseline = [['["shared","view"]', "V"]];
  const updates = [];
  let allowed = true;
  t.mock.method(api, "request", async (capability, text) => {
    if (capability === "preferences.read") {
      return JSON.stringify({ preferences: { defaultAction: "copy" }, cache: allowed ? baseline : undefined });
    }
    assert.equal(capability, "cache.commit");
    updates.push(JSON.parse(text));
    return "";
  });
  await api.loadPreferences();
  await api.runNoViewCommand(() => {
    const cache = new api.Cache({ namespace: "shared" });
    assert.equal(cache.get("view"), "V");
    cache.set("command", "C");
  });
  assert.deepEqual(updates, [[...baseline, ['["shared","command"]', "C"]]]);

  await api.loadPreferences();
  await assert.rejects(api.runNoViewCommand(() => {
    new api.Cache().set("failed", "ignore");
    throw new Error("Command failed");
  }), /Command failed/);
  assert.equal(updates.length, 1);

  allowed = false;
  await api.loadPreferences();
  await api.runNoViewCommand(() => assert.throws(() => new api.Cache().get("view"), /Cache is unavailable/));
  assert.equal(updates.length, 1);
});

test("withCache hashes argument types and restores structured results from a new cache scope", async () => {
  let calls = 0;
  async function compute() {
    return { sequence: ++calls, when: new Date("2026-11-16T00:00:00Z"), bytes: Buffer.from([1, 2, 3]),
      values: new Map([["flags", new Set([undefined, NaN])]]) };
  }
  configureCache([]);
  const cached = withCache(compute);
  const plain = { a: undefined, b: new Date("2026-11-16T00:00:00Z") };
  const original = await cached(plain);
  assert.equal((await cached(null)).sequence, 2);
  assert.equal((await cached(undefined)).sequence, 3);
  assert.equal((await cached({ b: "2026-11-16T00:00:00.000Z" })).sequence, 4);
  const cycle = {};
  cycle.self = cycle;
  assert.equal((await cached(cycle)).sequence, 5);
  const anotherCycle = {};
  anotherCycle.self = anotherCycle;
  assert.equal((await cached(anotherCycle)).sequence, 5);
  configureCache(takeCacheSnapshot());
  assert.deepEqual(await withCache(compute)({ b: plain.b, a: undefined }), original);
  assert.equal(calls, 5);
});

test("withCache returns fresh results when writing is blocked or the result exceeds storage", async () => {
  let calls = 0;
  async function compute(size) { return { order: ++calls, bytes: randomBytes(size) }; }
  configureCache([]);
  const cached = withCache(compute);
  assert.equal((await withCacheWritesBlocked(() => cached(1))).order, 1);
  assert.equal(takeCacheSnapshot(), undefined);
  assert.equal((await cached(20_000)).order, 2);
  assert.equal(takeCacheSnapshot(), undefined);
});

test("withCache compresses larger structured results and bounds their decoding", async () => {
  let calls = 0;
  async function compute() {
    return {
      sequence: ++calls, when: new Date("2026-11-16T00:00:00Z"),
      page: Array.from({ length: 800 }, (_, id) => ({ id, text: "重复的分页内容" })),
    };
  }
  configureCache([]);
  const original = await withCache(compute)("page");
  const [[key, encoded]] = takeCacheSnapshot();
  const entry = JSON.parse(encoded);
  assert.equal(entry.encoding, "deflate-raw");
  assert.ok(encoded.length < 16 * 1024);
  configureCache([[key, encoded]]);
  assert.deepEqual(await withCache(compute)("page"), original);
  assert.equal(calls, 1);

  for (const patch of [
    { encoding: "unknown" },
    { payload: "invalid" },
    { payload: deflateRawSync(Buffer.alloc(1024 * 1024 + 1)).toString("base64") },
  ]) {
    configureCache([[key, JSON.stringify({ ...entry, ...patch })]]);
    assert.equal((await withCache(compute)("page")).sequence, calls);
    assert.equal(JSON.parse(takeCacheSnapshot()[0][1]).encoding, "deflate-raw");
  }
  assert.equal(calls, 4);
});

test("useCachedState shares optimistic state, coalesces writes, and flushes on successful completion", async () => {
  configureCache({});
  const config = { cacheNamespace: "settings", cacheWriteDebounce: 25 };
  const cache = new Cache({ namespace: "settings" });
  const calls = [];
  cache.subscribe((...args) => calls.push(args));
  const [, set] = useCachedState("counter", 0, config);
  set((value) => value + 1);
  set((value) => value + 1);
  assert.equal(useCachedState("counter", 0, config)[0], 2);
  assert.equal(cache.get("counter"), undefined);
  assert.equal(takeCacheSnapshot(), undefined);
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(cache.get("counter"), "2");
  assert.deepEqual(calls, [["counter", "2"]]);

  set((value) => value + 1);
  assert.throws(() => withCacheWritesBlocked(() => set(5)), /unavailable/);
  assert.equal(cache.get("counter"), "2");
  const snapshot = takeCacheSnapshot({ flushPending: true });
  assert.deepEqual(calls, [["counter", "2"], ["counter", "3"]]);
  configureCache(snapshot);
  assert.equal(useCachedState("counter", 0, config)[0], 3);
  assert.equal(useCachedState("counter", 0)[0], 0);
});

test("a pending useCachedState write cannot escape its invocation or overwrite a newer immediate update", async () => {
  configureCache({});
  const [, old] = useCachedState("state", 0, { cacheWriteDebounce: 5 });
  old(1);
  const [, immediate] = useCachedState("state", 0);
  immediate(2);
  const snapshot = takeCacheSnapshot({ flushPending: true });
  const [, abandoned] = useCachedState("state", 0, { cacheWriteDebounce: 5 });
  abandoned(3);
  configureCache(snapshot);
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.equal(useCachedState("state", 0)[0], 2);
  assert.equal(takeCacheSnapshot({ flushPending: true }), undefined);
});

test("useCachedState restores Date and Buffer while preserving literal strings and legacy JSON", () => {
  configureCache({});
  new Cache().set("legacy", JSON.stringify("~keylane:date:2026-11-16T03:00:00Z"));
  const value = {
    date: new Date("2026-11-16T03:00:00Z"),
    payloads: [Buffer.from([0, 1, 255]), "~keylane:buffer:AAE="],
  };
  const config = { cacheWriteDebounce: 100 };
  const [, update] = useCachedState("new", null, config);
  update(value);
  assert.deepEqual(useCachedState("new", null, config)[0], value);
  configureCache(takeCacheSnapshot({ flushPending: true }));
  assert.deepEqual(useCachedState("new")[0], value);
  assert.equal(useCachedState("legacy")[0], "~keylane:date:2026-11-16T03:00:00Z");
});

test("large guest cache snapshots use bounded chunks independent of the view reply", async (t) => {
  const broker = require("./raycast-api.cjs");
  const entries = [['["transfer","data"]', "中".repeat(5000)]];
  const data = Buffer.from(JSON.stringify(entries));
  const received = [];
  const request = t.mock.method(broker, "request", async (capability, payload) => {
    if (capability === "cache.readChunk") {
      const offset = Number(payload);
      return data.subarray(offset, offset + 8192).toString("base64");
    }
    assert.equal(capability, "cache.writeChunk");
    received.push(payload);
    return "";
  });
  assert.deepEqual(await broker.readCache({ cacheSnapshotBytes: data.length }), entries);
  await broker.commitCache(entries, { legacy: true });
  assert.equal(received.pop(), "");
  assert.equal(received.length, 2);
  assert.deepEqual(Buffer.concat(received.map((chunk) => Buffer.from(chunk, "base64"))), data);

  request.mock.mockImplementation(async () => "AA==");
  await assert.rejects(broker.readCache({ cacheSnapshotBytes: data.length }), /Invalid cache transfer chunk/);
  await assert.rejects(broker.readCache({ cacheSnapshotBytes: 40_000 }), /Invalid cache transfer size/);
});
