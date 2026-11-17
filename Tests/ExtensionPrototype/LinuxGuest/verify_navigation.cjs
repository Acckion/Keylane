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
});

test("showHUD carries its title and close options only from a selected view action", async () => {
  const { showHUD } = require("./view-api.cjs");
  const command = (onAction) => () => Detail({
    actions: ActionPanel({ children: Action({ title: "Show HUD", onAction }) }),
  });
  const selection = { action: { row: 0, id: 0 } };
  assert.deepEqual(await render(command(() => showHUD("完成", {
    clearRootSearch: true, popToRootType: PopToRootType.Immediate,
  })), selection), { kind: "hud", text: "完成", clearRootSearch: true, popToRootType: "immediate" });
  assert.deepEqual(await render(command(() => showHUD("Done")), selection),
    { kind: "hud", text: "Done", clearRootSearch: false, popToRootType: "default" });
  await assert.rejects(render(command(() => showHUD("x".repeat(2049))), selection), /feedback limit/);
  await assert.rejects(render(command(() => showHUD("Done", { clearRootSearch: "true" })), selection), /must be a boolean/);
  await assert.rejects(render(() => List({ onSearchTextChange: () => showHUD("Passive") }), { query: "test" }),
    /requires a selected view action/);
});

test("reviewed command HUD still returns feedback without a selected view action", async () => {
  const { runCommand, showHUD } = require("./view-api.cjs");
  const result = await runCommand(() => showHUD("Done"), {});
  assert.deepEqual(result, { kind: "hud", text: "Done", clearRootSearch: false, popToRootType: "default" });
});

test("no-view closeMainWindow waits for the host and propagates a rejection", async (t) => {
  const api = require("./raycast-api.cjs");
  let acknowledge;
  const reply = new Promise((resolve) => { acknowledge = resolve; });
  const request = t.mock.method(api, "request", () => reply);
  await assert.rejects(api.closeMainWindow({ clearRootSearch: "true" }), /must be a boolean/);
  assert.equal(request.mock.callCount(), 0);

  let completed = false;
  const closing = api.closeMainWindow({ clearRootSearch: true, popToRootType: PopToRootType.Suspended })
    .then(() => { completed = true; });
  await new Promise(setImmediate);
  assert.equal(completed, false);
  const [topic, payload] = request.mock.calls[0].arguments;
  assert.equal(topic, "navigation.closeWindow");
  assert.deepEqual(JSON.parse(payload), { clearRootSearch: true, popToRootType: "suspended" });
  acknowledge("");
  await closing;
  assert.equal(completed, true);

  request.mock.mockImplementation(() => Promise.reject(new Error("Host rejected close")));
  await assert.rejects(api.closeMainWindow(), /Host rejected close/);
});

test("live view and form callbacks wait for close and propagate host refusal", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { Form } = require("./view-api.cjs");
  const input = { liveNavigation: true, navigationCloseAllowed: true, action: { row: 0, id: 0 } };
  let acknowledge;
  let notify;
  const arrived = new Promise((resolve) => { notify = resolve; });
  const request = t.mock.method(bridge, "request", (topic, payload) => {
    notify([topic, JSON.parse(payload)]);
    return new Promise((resolve) => { acknowledge = resolve; });
  });
  let resumed = false;
  const onAction = async () => {
    await closeMainWindow({ clearRootSearch: true, popToRootType: PopToRootType.Suspended });
    resumed = true;
  };
  const view = () => Detail({ actions: ActionPanel({ children: Action({ title: "Close", onAction }) }) });
  const result = render(view, input);
  assert.deepEqual(await arrived, ["navigation.closeWindow", { clearRootSearch: true, popToRootType: "suspended" }]);
  assert.equal(resumed, false);
  acknowledge("");
  assert.deepEqual(await result, { kind: "action" });
  assert.equal(resumed, true);

  request.mock.mockImplementation(async () => { throw new Error("Host refused close"); });
  const form = () => Form({ actions: ActionPanel({ children: Action.SubmitForm({
    async onSubmit() { await assert.rejects(closeMainWindow(), /Host refused close/); },
  }) }) });
  assert.deepEqual(await render(form, { ...input, formValues: {} }), { kind: "action" });
  await assert.rejects(render(view, { ...input, navigationCloseAllowed: undefined }), /Host window closure unavailable/);
  await assert.rejects(render(() => List({ onSearchTextChange: () => closeMainWindow() }), {
    ...input, action: undefined, query: "passive",
  }), /requires a selected view action/);
  assert.equal(request.mock.callCount(), 2);
});


test("live clearSearchBar waits for the host before continuing the selected callback", async (t) => {
  const bridge = require("./raycast-api.cjs");
  let acknowledge;
  let notify;
  const arrived = new Promise((resolve) => { notify = resolve; });
  const request = t.mock.method(bridge, "request", (topic, payload) => {
    notify([topic, JSON.parse(payload)]);
    return new Promise((resolve) => { acknowledge = resolve; });
  });
  const input = { liveNavigation: true, navigationCloseAllowed: true, action: { row: 0, id: 0 } };
  let resumed = false;
  const view = () => Detail({ actions: ActionPanel({ children: Action({
    title: "Clear",
    async onAction() {
      await clearSearchBar({ forceScrollToTop: false });
      resumed = true;
    },
  }) }) });
  const result = render(view, input);
  assert.deepEqual(await arrived, ["navigation.clearSearch", { forceScrollToTop: false }]);
  assert.equal(resumed, false);
  acknowledge("");
  assert.deepEqual(await result, { kind: "action" });
  assert.equal(resumed, true);

  request.mock.mockImplementation(async () => { throw new Error("Host rejected clear"); });
  await assert.rejects(render(view, input), /Host rejected clear/);
  await assert.rejects(render(view, { ...input, navigationCloseAllowed: undefined }), /Host search bar unavailable/);
  assert.equal(request.mock.callCount(), 2);
});

test("a live search callback waits for the host before clearing and loses access when it returns", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const request = t.mock.method(bridge, "request", async (topic, payload) => {
    assert.equal(topic, "navigation.clearSearch");
    assert.deepEqual(JSON.parse(payload), { forceScrollToTop: false });
  });
  let detached;
  const command = () => List({
    onSearchTextChange: async () => {
      await clearSearchBar({ forceScrollToTop: false });
      detached = new Promise((resolve) => {
        setImmediate(() => resolve(clearSearchBar().catch((error) => error)));
      });
    },
  });
  await render(command, { query: "clear", searchClearAllowed: true });
  assert.match((await detached).message, /requires a selected view action/);
  await assert.rejects(render(command, { query: "clear", searchClearAllowed: true, sensitiveFormSubmission: true }),
    /requires a selected view action/);
  assert.equal(request.mock.callCount(), 1);
});

test("clearSearchBar works from a search view effect when the host authorized a live render", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { useEffect } = require("./view-api.cjs");
  const request = t.mock.method(bridge, "request", async (topic, payload) => {
    assert.equal(topic, "navigation.clearSearch");
    assert.deepEqual(JSON.parse(payload), { forceScrollToTop: true });
  });
  const command = () => {
    useEffect(async () => { await clearSearchBar(); });
    return List({});
  };
  await render(command, { searchClearAllowed: true });
  await assert.rejects(render(command, {}), /requires a selected view action/);
  assert.equal(request.mock.callCount(), 1);
});

test("live popToRoot waits for a host transition before continuing the view action", async (t) => {
  const bridge = require("./raycast-api.cjs");
  let acknowledge;
  let notify;
  const arrived = new Promise((resolve) => { notify = resolve; });
  const request = t.mock.method(bridge, "request", (topic, payload) => {
    notify([topic, JSON.parse(payload)]);
    return new Promise((resolve) => { acknowledge = resolve; });
  });
  const input = { liveNavigation: true, navigationCloseAllowed: true, action: { row: 0, id: 0 } };
  let resumed = false;
  const command = () => Detail({ actions: ActionPanel({ children: Action({
    title: "Return to root",
    async onAction() {
      await popToRoot({ clearSearchBar: true });
      resumed = true;
    },
  }) }) });
  const result = render(command, input);
  assert.deepEqual(await arrived, ["navigation.popToRoot", { clearSearchBar: true }]);
  assert.equal(resumed, false);
  acknowledge("");
  assert.deepEqual(await result, { kind: "action" });
  assert.equal(resumed, true);

  request.mock.mockImplementation(async () => { throw new Error("Host rejected root navigation"); });
  await assert.rejects(render(command, input), /Host rejected root navigation/);
  await assert.rejects(render(command, { ...input, navigationCloseAllowed: undefined }), /Host root navigation unavailable/);
  assert.equal(request.mock.callCount(), 2);
});

test("an awaited first-render effect can pop to root but other renders cannot", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { useEffect } = require("./view-api.cjs");
  const request = t.mock.method(bridge, "request", async (topic, payload) => {
    assert.equal(topic, "navigation.popToRoot");
    assert.deepEqual(JSON.parse(payload), { clearSearchBar: false });
    return "";
  });
  const command = () => {
    useEffect(async () => {
      await Promise.resolve();
      await popToRoot();
    });
    return Detail({ markdown: "Before returning" });
  };
  const result = await render(command, { initialPreferencesAllowed: true });
  assert.equal(result.detail.markdown, "Before returning");
  assert.equal(request.mock.callCount(), 1);
  await assert.rejects(render(command, {}), /requires a selected view action/);
  assert.equal(request.mock.callCount(), 1);
});

test("no-view popToRoot forwards the option and propagates host refusal", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const request = t.mock.method(bridge, "request", async () => { throw new Error("Host rejected root navigation"); });
  await assert.rejects(bridge.popToRoot({ clearSearchBar: true }), /Host rejected root navigation/);
  assert.deepEqual(request.mock.calls[0].arguments, ["navigation.popToRoot", '{"clearSearchBar":true}']);
});

test("selected menu-bar actions await root navigation and cannot grant it to refreshes", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { MenuBarExtra, runMenuBar, useEffect } = require("./view-api.cjs");
  let acknowledge;
  let notify;
  const arrived = new Promise((resolve) => { notify = resolve; });
  const request = t.mock.method(bridge, "request", (topic, payload) => {
    notify([topic, JSON.parse(payload)]);
    return new Promise((resolve) => { acknowledge = resolve; });
  });
  let resumed = false;
  const command = () => MenuBarExtra({ children: MenuBarExtra.Item({
    title: "Return to root",
    async onAction() {
      await popToRoot({ clearSearchBar: true });
      resumed = true;
    },
  }) });
  const pending = runMenuBar(command, { wallTime: 1, menuAction: 0, menuAlertAllowed: true });
  assert.deepEqual(await arrived, ["navigation.popToRoot", { clearSearchBar: true }]);
  assert.equal(resumed, false);
  acknowledge("");
  assert.deepEqual(await pending, { kind: "menuAction" });
  assert.equal(resumed, true);
  await assert.rejects(runMenuBar(command, { wallTime: 1, menuAction: 0 }), /Host root navigation unavailable/);
  await assert.rejects(runMenuBar(() => {
    useEffect(() => popToRoot());
    return MenuBarExtra({});
  }, { wallTime: 1 }), /requires a selected view action/);
  assert.equal(request.mock.callCount(), 1);
});

test("signed UUID suite generation and selected history actions share root acknowledgments", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { Clipboard, runCommand } = require("./view-api.cjs");
  const requests = [];
  t.mock.method(bridge, "request", async (topic, payload) => { requests.push([topic, JSON.parse(payload)]); return ""; });
  const generate = async () => {
    await popToRoot();
    await Clipboard.copy("generated");
  };
  assert.deepEqual(await runCommand(generate, { mode: "generate", suitePreferencesAllowed: true, storage: {} }),
    { kind: "copy", text: "generated" });
  await assert.rejects(runCommand(generate, { mode: "generate" }), /requires a selected view action/);

  const history = () => Detail({ actions: ActionPanel({ children: Action({
    title: "History action", onAction: () => popToRoot({ clearSearchBar: true }),
  }) }) });
  assert.deepEqual(await render(history, { mode: "history", suitePreferencesAllowed: true, action: { row: 0, id: 0 } }),
    { kind: "action" });
  assert.deepEqual(requests, [
    ["navigation.popToRoot", { clearSearchBar: false }],
    ["navigation.popToRoot", { clearSearchBar: true }],
  ]);
});

test("no-view and selected menu actions await search clearing without granting it to refreshes", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { MenuBarExtra, runMenuBar, useEffect } = require("./view-api.cjs");
  const request = t.mock.method(bridge, "request", async (topic, payload) => {
    assert.equal(topic, "navigation.clearSearch");
    assert.equal(typeof JSON.parse(payload).forceScrollToTop, "boolean");
  });
  await bridge.clearSearchBar();
  const command = () => MenuBarExtra({ children: MenuBarExtra.Item({
    title: "Clear Search",
    onAction: () => clearSearchBar({ forceScrollToTop: false }),
  }) });
  assert.deepEqual(await runMenuBar(command, { wallTime: 1, menuAction: 0, menuAlertAllowed: true }), { kind: "menuAction" });
  await assert.rejects(runMenuBar(command, { wallTime: 1, menuAction: 0 }), /Host search bar unavailable/);
  await assert.rejects(runMenuBar(() => {
    useEffect(() => clearSearchBar());
    return MenuBarExtra({});
  }, { wallTime: 1, menuAlertAllowed: true }), /requires a selected view action/);
  assert.deepEqual(request.mock.calls.map(({ arguments: [, payload] }) => JSON.parse(payload).forceScrollToTop), [true, false]);
});

test("a selected menu action awaits window closure while refreshes and ungranted actions cannot close it", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { MenuBarExtra, runMenuBar, useEffect } = require("./view-api.cjs");
  let acknowledge;
  let notify;
  const arrived = new Promise((resolve) => { notify = resolve; });
  const request = t.mock.method(bridge, "request", (topic, payload) => {
    notify([topic, JSON.parse(payload)]);
    return new Promise((resolve) => { acknowledge = resolve; });
  });
  let resumed = false;
  const command = () => MenuBarExtra({ children: MenuBarExtra.Item({
    title: "Close launcher",
    async onAction() {
      await closeMainWindow({ clearRootSearch: true, popToRootType: PopToRootType.Suspended });
      resumed = true;
    },
  }) });
  const pending = runMenuBar(command, { wallTime: 1, menuAction: 0, menuAlertAllowed: true });
  assert.deepEqual(await arrived, ["navigation.closeWindow", { clearRootSearch: true, popToRootType: "suspended" }]);
  assert.equal(resumed, false);
  acknowledge("");
  assert.deepEqual(await pending, { kind: "menuAction" });
  assert.equal(resumed, true);
  await assert.rejects(runMenuBar(command, { wallTime: 1, menuAction: 0 }), /Host window closure unavailable/);
  await assert.rejects(runMenuBar(() => {
    useEffect(() => closeMainWindow());
    return MenuBarExtra({});
  }, { wallTime: 1, menuAlertAllowed: true }), /requires a selected view action/);
  assert.equal(request.mock.callCount(), 1);
});

test("live view and menu HUD calls wait for native presentation", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { MenuBarExtra, runMenuBar, showHUD } = require("./view-api.cjs");
  const calls = [];
  let acknowledge;
  let arrived;
  const request = t.mock.method(bridge, "request", (topic, payload) => {
    calls.push([topic, JSON.parse(payload)]);
    return new Promise((resolve, reject) => {
      acknowledge = { resolve, reject };
      arrived();
    });
  });
  let resumed = false;
  const action = async () => {
    await showHUD("已保存", { clearRootSearch: true, popToRootType: PopToRootType.Immediate });
    resumed = true;
  };
  const view = () => Detail({ actions: ActionPanel({ children: Action({ title: "Save", onAction: action }) }) });
  const viewRequest = new Promise((resolve) => { arrived = resolve; });
  const runningView = render(view, { action: { row: 0, id: 0 }, liveNavigation: true, navigationCloseAllowed: true });
  await viewRequest;
  assert.equal(resumed, false);
  acknowledge.resolve("");
  assert.equal((await runningView).kind, "action");
  assert.equal(resumed, true);

  resumed = false;
  const menu = () => MenuBarExtra({ children: MenuBarExtra.Item({ title: "Save", onAction: action }) });
  const menuRequest = new Promise((resolve) => { arrived = resolve; });
  const runningMenu = runMenuBar(menu, { wallTime: 1, menuAction: 0, menuAlertAllowed: true });
  await menuRequest;
  assert.equal(resumed, false);
  const rejected = assert.rejects(runningMenu, /HUD unavailable/);
  acknowledge.reject(new Error("HUD unavailable"));
  await rejected;
  assert.equal(resumed, false);
  assert.deepEqual(calls, Array(2).fill(["feedback.hud", { text: "已保存", clearRootSearch: true, popToRootType: "immediate" }]));
});

test("only signed initial mount effects can request live window closure or HUD presentation", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const { useEffect, showHUD } = require("./view-api.cjs");
  const calls = [];
  t.mock.method(bridge, "request", async (topic, payload) => { calls.push([topic, JSON.parse(payload)]); });
  const command = () => {
    useEffect(async () => {
      await Promise.resolve();
      await closeMainWindow({ popToRootType: PopToRootType.Suspended });
      await showHUD("已完成");
    });
    return Detail({ markdown: "Initial view" });
  };
  const mounted = await render(command, { query: "", initialPreferencesAllowed: true, mountNavigation: true });
  assert.equal(mounted.detail.markdown, "Initial view");
  assert.deepEqual(calls, [
    ["navigation.closeWindow", { clearRootSearch: false, popToRootType: "suspended" }],
    ["feedback.hud", { text: "已完成", clearRootSearch: false, popToRootType: "default" }],
  ]);
  const passiveCases = [
    {},
    { mountNavigation: true },
    { initialPreferencesAllowed: true },
    { initialPreferencesAllowed: true, mountNavigation: true, query: "different" },
    { initialPreferencesAllowed: true, mountNavigation: true, sensitiveFormSubmission: true },
  ];
  for (const input of passiveCases) {
    await assert.rejects(render(command, { query: "", ...input }), /requires a selected view action/);
  }
  assert.equal(calls.length, 2);
});
