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
    const state = useCachedPromise(async () => "x".repeat(2300));
    return Detail({ markdown: String(state.data?.length), isLoading: state.isLoading });
  };
  const result = await render(command, { cache: {} });
  assert.equal(result.detail.markdown, "2300");
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
