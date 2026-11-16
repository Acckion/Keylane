const assert = require("node:assert/strict");
const test = require("node:test");
const { makeNavigation, PopToRootType } = require("./navigation-api.cjs");

test("navigation emits the published default policies", async () => {
  const effects = [];
  const { closeMainWindow, clearSearchBar, popToRoot } = makeNavigation((effect) => effects.push(effect));

  assert.deepEqual(PopToRootType, { Default: "default", Immediate: "immediate", Suspended: "suspended" });
  assert.equal(await closeMainWindow(), undefined);
  assert.equal(await clearSearchBar({}), undefined);
  assert.equal(await popToRoot(undefined), undefined);
  assert.deepEqual(effects, [
    { kind: "closeMainWindow", clearRootSearch: false, popToRootType: "default" },
    { kind: "clearSearchBar", forceScrollToTop: true },
    { kind: "popToRoot", clearSearchBar: false },
  ]);
});

test("explicit navigation options survive without boolean coercion", async () => {
  const effects = [];
  const api = makeNavigation((effect) => effects.push(effect));

  await api.closeMainWindow({ clearRootSearch: true, popToRootType: PopToRootType.Immediate });
  await api.closeMainWindow({ clearRootSearch: false, popToRootType: PopToRootType.Suspended });
  await api.clearSearchBar({ forceScrollToTop: false });
  await api.popToRoot({ clearSearchBar: true });

  assert.deepEqual(effects, [
    { kind: "closeMainWindow", clearRootSearch: true, popToRootType: "immediate" },
    { kind: "closeMainWindow", clearRootSearch: false, popToRootType: "suspended" },
    { kind: "clearSearchBar", forceScrollToTop: false },
    { kind: "popToRoot", clearSearchBar: true },
  ]);
});

test("invalid navigation options and denied authorization never produce an effect", async () => {
  let emitted = false;
  const api = makeNavigation(() => {
    emitted = true;
    throw new Error("Requires a selected view action");
  });

  await assert.rejects(api.closeMainWindow({ clearRootSearch: "true" }), /must be a boolean/);
  await assert.rejects(api.closeMainWindow({ popToRootType: "always" }), /Invalid popToRootType/);
  await assert.rejects(api.clearSearchBar({ forceScrollToTop: 0 }), /must be a boolean/);
  await assert.rejects(api.popToRoot({ clearSearchBar: null }), /must be a boolean/);
  await assert.rejects(api.popToRoot(null), /Expected navigation options/);
  assert.equal(emitted, false);

  await assert.rejects(api.closeMainWindow(), /Requires a selected view action/);
  assert.equal(emitted, true);
});

const { Action, ActionPanel, Detail, List, clearSearchBar, closeMainWindow, popToRoot, render, useState } =
  require("./view-api.cjs");

test("reviewed view actions carry each navigation request through the result envelope", async () => {
  const command = () => {
    const [, setSearch] = useState("original");
    return Detail({ actions: ActionPanel({ children: [
      Action({ title: "Close", onAction: () => closeMainWindow({ popToRootType: PopToRootType.Suspended }) }),
      Action({ title: "Clear", onAction: async () => {
        await clearSearchBar({ forceScrollToTop: false });
        setSearch("state update");
      } }),
      Action({ title: "Root", onAction: () => popToRoot({ clearSearchBar: true }) }),
    ] }) });
  };

  const expected = [
    { kind: "closeMainWindow", clearRootSearch: false, popToRootType: "suspended" },
    { kind: "clearSearchBar", forceScrollToTop: false },
    { kind: "popToRoot", clearSearchBar: true },
  ];
  for (const [id, effect] of expected.entries()) {
    assert.deepEqual(await render(command, { action: { row: 0, id } }), effect);
  }
});

test("passive view work and detached callbacks cannot trigger launcher navigation", async () => {
  await assert.rejects(render(() => List({ onSearchTextChange: () => clearSearchBar() }),
    { query: "passive" }), /requires a selected view action/);

  const command = () => {
    const passive = new Promise((resolve) => {
      setImmediate(() => resolve(popToRoot().catch((error) => error)));
    });
    return Detail({ actions: ActionPanel({ children: Action({ title: "Close", onAction: async () => {
      assert.match((await passive).message, /requires a selected view action/);
      await closeMainWindow();
    } }) }) });
  };
  assert.deepEqual(await render(command, { action: { row: 0, id: 0 } }),
    { kind: "closeMainWindow", clearRootSearch: false, popToRootType: "default" });
  assert.equal(require("./raycast-api.cjs").closeMainWindow, undefined);
});
