const assert = require("node:assert/strict");
const test = require("node:test");
const api = require("./view-api.cjs");
const { utilitiesHooksFor } = require("./utilities-hooks.cjs");
const { utilitiesRuntimeHooksFor } = require("./utilities-runtime-hooks.cjs");

const provider = () => api;
const { usePromise } = utilitiesHooksFor(provider, { Required: "required" });
const { DeeplinkType, useCachedPromise, useFrecencySorting } = utilitiesRuntimeHooksFor(provider, usePromise);
const { Action, ActionPanel, Detail, List, render } = api;
const select = { row: 0, id: 0 };

test("useCachedPromise restores stale data and refreshes it when enabled", async () => {
  let execute = true;
  let calls = 0;
  const operation = async (input) => `${input} ${++calls}`;
  const command = ({ arguments: { input } }) => {
    const state = useCachedPromise(operation, [input], { execute, initialData: "initial" });
    return Detail({ markdown: state.data, isLoading: state.isLoading });
  };
  const first = await render(command, { query: "中文", cache: {} });
  assert.equal(first.detail.markdown, "中文 1");
  assert.ok(first.cache);
  execute = false;
  assert.equal((await render(command, { query: "中文", cache: first.cache })).detail.markdown, "中文 1");
  assert.equal((await render(command, { query: "other", cache: first.cache })).detail.markdown, "initial");
  assert.equal(calls, 1);
  execute = true;
  const refreshed = await render(command, { query: "中文", cache: first.cache });
  assert.equal(refreshed.detail.markdown, "中文 2");
  assert.notDeepEqual(refreshed.cache, first.cache);
});

test("useCachedPromise keeps the stale result during route replay without restarting work", async () => {
  let calls = 0;
  const command = () => {
    const state = useCachedPromise(async () => `result ${++calls}`);
    return Detail({ actions: ActionPanel({ children: Action.Push({
      title: "Show data", target: Detail({ markdown: state.data }),
    }) }) });
  };
  const parent = await render(command, { cache: {} });
  const child = await render(command, {
    cache: parent.cache,
    viewRoute: [{ mode: "action", row: 0, id: 0, query: "" }],
  });
  assert.equal(child.detail.markdown, "result 1");
  assert.equal(calls, 1);
  assert.equal(child.cache, undefined);
});

test("useCachedPromise retains successful data larger than the cache budget", async () => {
  const command = () => {
    const state = useCachedPromise(async () => "x".repeat(17000));
    return Detail({ markdown: String(state.data?.length), isLoading: state.isLoading });
  };
  const result = await render(command, { cache: {} });
  assert.equal(result.detail.markdown, "17000");
  assert.equal(result.cache, undefined);
});

test("useFrecencySorting persists visits, applies decay and resets ranking", async (t) => {
  let now = 1_800_000_000_000;
  t.mock.method(Date, "now", () => now);
  const rows = [{ name: "Z", id: "z" }, { name: "B", id: "b" }, { name: "A", id: "a" }];
  const command = () => {
    const { data, visitItem, resetRanking } = useFrecencySorting(rows, {
      namespace: "frecency test",
      key: (item) => item.id,
      sortUnvisited: (a, b) => a.name.localeCompare(b.name),
    });
    return List({ children: data.map((item) => List.Item({
      title: item.name,
      actions: ActionPanel({ children: [
        Action({ title: "Visit", onAction: () => visitItem(item) }),
        Action({ title: "Reset", onAction: () => resetRanking(item) }),
      ] }),
    })) });
  };
  const titles = async (cache) => (await render(command, { cache })).rows.map((row) => row.title);
  assert.deepEqual(await titles({}), ["A", "B", "Z"]);
  const first = await render(command, { cache: {}, action: { ...select, row: 2 } });
  assert.deepEqual(await titles(first.cache), ["Z", "A", "B"]);
  const second = await render(command, { cache: first.cache, action: select });
  assert.deepEqual(await titles(second.cache), ["Z", "A", "B"]);
  now += 14 * 24 * 60 * 60 * 1000;
  const third = await render(command, { cache: second.cache, action: { ...select, row: 2 } });
  assert.deepEqual(await titles(third.cache), ["B", "Z", "A"]);
  const reset = await render(command, { cache: third.cache, action: { ...select, id: 1 } });
  assert.deepEqual(await titles(reset.cache), ["Z", "A", "B"]);
  assert.equal((await render(() => Detail({ markdown: String(useFrecencySorting().data.length) }), {})).detail.markdown, "0");
});

test("DeeplinkType exposes the declared script and extension values", () => {
  assert.deepEqual(DeeplinkType, { ScriptCommand: "script-command", Extension: "extension" });
  assert.equal(Object.isFrozen(DeeplinkType), true);
});

test("useCachedPromise caches the first page and restores it between invocations", async () => {
  let execute = true;
  const observed = [];
  const fetchPage = () => async ({ page }) => ({ data: ["page " + page], hasMore: page < 2 });
  const command = () => {
    const { data, pagination } = useCachedPromise(fetchPage, [], {
      execute,
      onData: (_items, options) => observed.push(options.page),
    });
    return List({ pagination, children: data?.map((title) => List.Item({ title })) });
  };

  const result = await render(command, { cache: {}, pageCount: 2 });
  assert.deepEqual(result.rows.map(({ title }) => title), ["page 0", "page 1", "page 2"]);
  assert.deepEqual(observed, [0, 1, 2]);
  assert.ok(result.cache);
  execute = false;
  const restored = await render(command, { cache: result.cache });
  assert.deepEqual(restored.rows.map(({ title }) => title), ["page 0"]);
  assert.deepEqual(observed, [0, 1, 2]);
});

test("frecency uses the pinned SDK's ten-day decay and migrates legacy rankings on the next write", async (t) => {
  const { createHash } = require("node:crypto");
  const { Cache, configureCache, takeCacheSnapshot } = require("./cache-api.cjs");
  const digest = (value) => createHash("sha256").update(value).digest("hex");
  const day = 86_400_000;
  let now = 1_800_000_000_000;
  t.mock.method(Date, "now", () => now);
  configureCache([]);
  const items = [{ id: "old" }, { id: "new" }];
  const rank = () => useFrecencySorting(items);
  await rank().visitItem(items[0]);
  await rank().visitItem(items[0]);
  now += 8 * day;
  await rank().visitItem(items[1]);
  assert.deepEqual(rank().data, items);
  now += 4 * day;
  await rank().visitItem(items[1]);
  assert.deepEqual(rank().data, [...items].reverse());

  configureCache([]);
  const cache = new Cache({ namespace: "frecency:" + digest("") });
  cache.set("ranking", JSON.stringify({
    [digest("old").slice(0, 32)]: { score: 2, updated: now - 8 * day },
    [digest("new").slice(0, 32)]: { score: 1, updated: now },
  }));
  assert.deepEqual(rank().data, [...items].reverse());
  await rank().visitItem(items[0]);
  assert.deepEqual(rank().data, items);
  assert.ok(Object.values(JSON.parse(cache.get("ranking"))).every(Number.isFinite));
  configureCache(takeCacheSnapshot());
  assert.deepEqual(rank().data, items);
});

test("frecency preserves more than 24 rankings and isolates namespaces", async () => {
  const { configureCache, takeCacheSnapshot } = require("./cache-api.cjs");
  configureCache([]);
  const items = Array.from({ length: 52 }, (_, index) => String(index));
  const sorter = (namespace, data = items) => useFrecencySorting(data, { namespace, key: (item) => item });
  for (const item of items.slice(0, 50)) await sorter("project").visitItem(item);
  configureCache(takeCacheSnapshot());
  const reversed = [...items].reverse();
  const after = sorter("project", reversed);
  assert.ok(after.data.slice(0, 50).every((item) => Number(item) < 50));
  assert.deepEqual(after.data.slice(-2), ["51", "50"]);
  assert.deepEqual(sorter("other", reversed).data, reversed);
  await after.resetRanking("3");
  assert.ok(sorter("project", reversed).data.slice(-3).includes("3"));
});

test("useCachedPromise keeps typed arguments and cached undefined distinct across invocations", async () => {
  let execute = true;
  const load = async (argument) => argument === null ? { date: new Date(1000), bytes: Buffer.from([255]) } : undefined;
  const command = (input) => () => {
    const state = useCachedPromise(load, [input], { execute, initialData: "uncached" });
    const value = state.data;
    return Detail({ markdown: value === undefined ? "stored undefined"
      : typeof value === "string" ? value : String(value.date instanceof Date && Buffer.isBuffer(value.bytes)) });
  };

  const first = await render(command(undefined), { cache: [] });
  const second = await render(command(null), { cache: first.cache });
  execute = false;
  assert.equal((await render(command(undefined), { cache: second.cache })).detail.markdown, "stored undefined");
  assert.equal((await render(command(null), { cache: second.cache })).detail.markdown, "true");
  assert.equal((await render(command(false), { cache: second.cache })).detail.markdown, "uncached");
});

test("useCachedPromise persists a debounced optimistic mutation and restores the correct value after rejection", async () => {
  let execute = true;
  const load = async () => ({ count: 4, bytes: Buffer.from([255]) });
  const command = ({ arguments: { input } }) => {
    const state = useCachedPromise(load, [], { execute, cacheWriteDebounce: 10_000 });
    return Detail({ markdown: Buffer.isBuffer(state.data?.bytes) ? String(state.data.count) : "invalid buffer", actions: ActionPanel({ children: Action({
      title: "Update",
      async onAction() {
        const update = input === "fail" ? Promise.reject(new Error("update failed")) : Promise.resolve();
        try {
          await state.mutate(update, { optimisticUpdate: (current) => ({ ...current, count: current.count + 1 }), shouldRevalidateAfter: false });
        } catch (error) {
          assert.equal(error.message, "update failed");
        }
      },
    }) }) });
  };

  const seed = await render(command, { cache: [] });
  execute = false;
  const success = await render(command, { action: select, cache: seed.cache });
  assert.equal(success.detail.markdown, "5");
  assert.equal((await render(command, { cache: success.cache })).detail.markdown, "5");
  const failure = await render(command, { query: "fail", action: select, cache: success.cache });
  assert.equal(failure.detail.markdown, "5");
  assert.equal((await render(command, { cache: failure.cache ?? success.cache })).detail.markdown, "5");
});

test("an older failed cached mutation cannot overwrite a newer optimistic write", async () => {
  let execute = true;
  const load = async () => "saved";
  const command = () => {
    const state = useCachedPromise(load, [], { execute });
    return Detail({ markdown: state.data, actions: ActionPanel({ children: Action({
      title: "Update",
      async onAction() {
        let fail;
        const request = new Promise((_resolve, reject) => { fail = reject; });
        const older = state.mutate(request, {
          rollbackOnError: () => "obsolete",
          shouldRevalidateAfter: false,
        });
        await state.mutate(undefined, {
          optimisticUpdate: () => "newer",
          shouldRevalidateAfter: false,
        });
        fail(new Error("older request failed"));
        await assert.rejects(older, /older request failed/);
      },
    }) }) });
  };
  const seed = await render(command, { cache: [] });
  execute = false;
  const updated = await render(command, { cache: seed.cache, action: select });
  assert.equal(updated.detail.markdown, "newer");
  assert.equal((await render(command, { cache: updated.cache })).detail.markdown, "newer");
});
