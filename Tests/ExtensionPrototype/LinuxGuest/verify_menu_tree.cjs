const assert = require("node:assert/strict");
const test = require("node:test");
const api = require("./view-api.cjs");
const { MenuBarExtra: Menu, Keyboard } = api;

const input = { wallTime: 1 };
const command = () => Menu({ tooltip: "Status", children: [
  Menu.Section({ title: "Tasks", children: Menu.Item({ title: "No tasks" }) }),
  Menu.Separator(),
  Menu.Submenu({ title: "Tools", children: Menu.Item({
    title: "Preferences", subtitle: "Extension", tooltip: "Open settings",
    shortcut: Keyboard.Shortcut.Common.MoveDown,
    onAction(event) {
      assert.equal(event.type, "left-click");
      return api.openCommandPreferences();
    },
  }) }),
] });

test("menu structure and shortcut survive guest serialization and nested action replay", async () => {
  const snapshot = await api.runMenuBar(command, input);
  assert.equal(snapshot.tooltip, "Status");
  assert.deepEqual(snapshot.items.map(({ kind }) => kind), ["section", "separator", "submenu"]);
  assert.equal(snapshot.items[0].children[0].enabled, false);
  const action = snapshot.items[2].children[0];
  assert.equal(action.key, "arrowDown");
  assert.deepEqual(action.modifiers, ["cmd", "opt"]);
  assert.equal(action.subtitle, "Extension");
  assert.equal(action.tooltip, "Open settings");
  const reply = await api.runMenuBar(command, { ...input, menuAction: action.id });
  assert.deepEqual(reply, { kind: "openPreferences" });
  await assert.rejects(api.runMenuBar(command, { ...input, menuAction: 0 }), /Unknown menu action/);
});

test("guest menu tree has a bounded node count and depth", async () => {
  const large = () => Menu({ children: Array.from({ length: 65 }, () => Menu.Item({ title: "Item" })) });
  await assert.rejects(api.runMenuBar(large, input), /Menu tree limit exceeded/);
  let node = Menu.Item({ title: "Item" });
  for (let index = 0; index < 5; index++) node = Menu.Submenu({ title: "Submenu", children: node });
  await assert.rejects(api.runMenuBar(() => Menu({ children: node }), input), /Menu tree limit exceeded/);
});

test("menu bar button, submenu and row transport generated icons as image descriptors", async () => {
  const { getAvatarIcon, getProgressIcon } = require("./utilities-visual-feedback.cjs");
  const avatar = getAvatarIcon("林 安");
  const progress = getProgressIcon(0.5);
  const command = () => Menu({
    icon: { source: { light: avatar, dark: progress }, mask: "circle" },
    children: Menu.Submenu({ title: "Group", icon: progress, children: [
      Menu.Item({ title: "Member", icon: avatar }),
      Menu.Item({ title: "Untrusted SVG", icon: "data:image/svg+xml,%3Cscript%3E" }),
    ] }),
  });
  const result = await api.runMenuBar(command, input);
  assert.equal(result.imageDescriptor.light.utility.initials, "林安");
  assert.equal(result.imageDescriptor.dark.utility.fraction, 0.5);
  assert.equal(result.imageDescriptor.mask, "circle");
  assert.equal(result.icon, undefined);
  assert.equal(result.items[0].imageDescriptor.light.utility.fraction, 0.5);
  assert.equal(result.items[0].children[0].imageDescriptor.light.utility.initials, "林安");
  assert.equal(result.items[0].children[1].imageDescriptor, undefined);
  assert.equal(result.items[0].children[1].icon, undefined);
});

test("Option alternate inherits the primary shortcut and dispatches its own callback", async () => {
  const calls = [];
  const fixture = () => Menu({ children: Menu.Submenu({ title: "Tools", children: Menu.Item({
    title: "Primary", shortcut: { key: "r", modifiers: ["cmd", "shift"] },
    onAction: () => calls.push("primary"),
    alternate: Menu.Item({ title: "Alternate", onAction: () => calls.push("alternate") }),
  }) }) });
  const snapshot = await api.runMenuBar(fixture, input);
  const [primary, alternate] = snapshot.items[0].children;
  assert.equal(primary.key, "r");
  assert.equal(alternate.key, "r");
  assert.equal(alternate.isAlternate, true);
  assert.deepEqual(alternate.modifiers, ["cmd", "shift", "opt"]);
  assert.notEqual(primary.id, alternate.id);
  await api.runMenuBar(fixture, { ...input, menuAction: primary.id });
  await api.runMenuBar(fixture, { ...input, menuAction: alternate.id });
  assert.deepEqual(calls, ["primary", "alternate"]);

  const noShortcut = await api.runMenuBar(() => Menu({ children: Menu.Item({
    title: "Plain", alternate: Menu.Item({ title: "Option only" }),
  }) }), input);
  assert.equal(noShortcut.items[1].key, undefined);
  assert.deepEqual(noShortcut.items[1].modifiers, ["opt"]);
});

test("alternate validation rejects conflicting shortcuts, nesting and excess items", async () => {
  const alternate = Menu.Item({ title: "Backup" });
  const withAlternate = (props) => api.runMenuBar(() => Menu({
    children: Menu.Item({ title: "Primary", alternate, ...props }),
  }), input);
  await assert.rejects(withAlternate({ shortcut: { key: "a", modifiers: ["opt"] } }), /Invalid menu item alternate/);
  await assert.rejects(withAlternate({ alternate: Menu.Submenu({ title: "Wrong" }) }), /Invalid menu item alternate/);
  await assert.rejects(withAlternate({ alternate: Menu.Item({ title: "Nested", alternate }) }), /Invalid menu item alternate/);
  await assert.rejects(withAlternate({ alternate: Menu.Item({ title: "Custom", shortcut: { key: "z" } }) }), /Invalid menu item alternate/);
  await assert.rejects(api.runMenuBar(() => Menu({
    children: Array.from({ length: 33 }, () => Menu.Item({ title: "Primary", alternate })),
  }), input), /Menu tree limit exceeded/);
});

test("menu callbacks receive explicit right clicks and default to left click for old callers", async () => {
  const events = [];
  const fixture = () => Menu({ children: Menu.Item({
    title: "Action", onAction: ({ type }) => events.push(type),
  }) });
  for (const menuActionType of [undefined, "left-click", "right-click"]) {
    assert.deepEqual(await api.runMenuBar(fixture, { ...input, menuAction: 0, menuActionType }), { kind: "menuAction" });
  }
  assert.deepEqual(events, ["left-click", "left-click", "right-click"]);
  await assert.rejects(api.runMenuBar(fixture, { ...input, menuAction: 0, menuActionType: "hover" }), /Invalid menu action event/);
  await assert.rejects(api.runMenuBar(fixture, { ...input, menuActionType: "right-click" }), /Invalid menu action event/);
  await assert.rejects(api.runMenuBar(fixture, { ...input, menuAction: "0" }), /Invalid menu action ID/);
  assert.equal(events.length, 3);
});

test("selected menu actions open web URLs with the requested browser", async () => {
  const fixture = () => Menu({ children: Menu.Item({
    title: "Home", onAction: () => api.open("https://example.invalid"),
    alternate: Menu.Item({ title: "Store", onAction: () => api.open("https://example.invalid/store", "com.apple.Safari") }),
  }) });
  const action = (menuAction) => api.runMenuBar(fixture, { ...input, menuAction });
  assert.deepEqual(await action(0), { kind: "openURL", text: "https://example.invalid/" });
  assert.deepEqual(await action(1), {
    kind: "openURL", text: "https://example.invalid/store", application: { name: "com.apple.Safari" },
  });
});

test("menu URL requests preserve file and callback boundaries", async () => {
  const action = (onAction) => api.runMenuBar(() => Menu({ children: Menu.Item({ title: "Test", onAction }) }),
    { ...input, menuAction: 0 });
  await assert.rejects(action(() => api.open("/tmp/asset.txt")), /only open URLs/);
  await assert.rejects(action(() => api.open("javascript:alert(1)")), /Unsupported open URL/);
  await assert.rejects(action(async () => {
    await api.open("https://example.invalid/a");
    await api.openCommandPreferences();
  }), /one active menu action/);
  let delayed;
  assert.deepEqual(await action(() => {
    delayed = new Promise((resolve) => setImmediate(() => resolve(api.open("https://example.invalid/a").catch((error) => error))));
  }), { kind: "menuAction" });
  assert.match((await delayed).message, /one active menu action/);
});

test("menu actions publish cache changes and return the updated menu", async () => {
  const command = () => {
    const cache = new api.Cache({ namespace: "menu" });
    return Menu({
      title: cache.get("status") ?? "Initial",
      children: Menu.Item({ title: "Save", onAction: () => cache.set("status", "Saved") }),
    });
  };
  const written = await api.runMenuBar(command, { ...input, cache: [], menuAction: 0 });
  assert.equal(written.kind, "menuBar");
  assert.equal(written.storageUpdated, true);
  assert.equal(written.title, "Saved");
  assert.deepEqual(written.cache, [['["menu","status"]', "Saved"]]);
  const restored = await api.runMenuBar(command, { ...input, cache: written.cache });
  assert.equal(restored.title, "Saved");
  assert.equal(restored.cache, undefined);
});

test("confirmation is available only inside the authorized selected menu callback", async (t) => {
  const bridge = require("./raycast-api.cjs");
  let choice = "primary";
  const broker = t.mock.method(bridge, "request", async (capability, text) => {
    if (capability === "preferences.open") {
      assert.equal(text, "command");
      return "";
    }
    assert.equal(capability, "feedback.confirmAlert");
    assert.equal(JSON.parse(text).title, "Apply changes?");
    return choice;
  });
  const selected = () => Menu({ children: Menu.Item({ title: "Apply", async onAction() {
    if (await api.confirmAlert({ title: "Apply changes?" })) await api.openCommandPreferences();
  } }) });
  await assert.rejects(api.runMenuBar(selected, { ...input, menuAction: 0 }), /authorized view action or menu action/);
  const passive = () => {
    api.useEffect(() => assert.rejects(api.confirmAlert({ title: "Apply changes?" }), /authorized view action or menu action/));
    return selected();
  };
  const authorized = { ...input, menuAlertAllowed: true };
  assert.equal((await api.runMenuBar(passive, authorized)).kind, "menuBar");
  assert.equal(broker.mock.callCount(), 0);
  assert.equal((await api.runMenuBar(selected, { ...authorized, menuAction: 0 })).kind, "menuAction");
  choice = "dismiss";
  assert.equal((await api.runMenuBar(selected, { ...authorized, menuAction: 0 })).kind, "menuAction");
  assert.equal(broker.mock.callCount(), 3);
});

test("clipboard read access is scoped to the authorized menu item", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const broker = t.mock.method(bridge, "request", async (capability, selector) => {
    assert.equal(capability, "clipboard.read");
    assert.equal(selector, "text:1");
    return '{"text":"fixture"}';
  });
  const authorized = { ...input, clipboardReadAllowed: true, menuAlertAllowed: true };
  let detached;
  const selected = () => {
    assert.equal(api.environment.canAccess(api.Clipboard), false);
    return Menu({ children: Menu.Item({ title: "Read", async onAction() {
      assert.equal(api.environment.canAccess(api.Clipboard.readText), true);
      assert.equal(await api.Clipboard.readText({ offset: 1 }), "fixture");
      detached = new Promise((resolve, reject) => setImmediate(() => {
        assert.rejects(api.Clipboard.read(), /requires a selected view action/).then(resolve, reject);
      }));
    } }) });
  };
  const denied = () => Menu({ children: Menu.Item({ title: "Denied", async onAction() {
    assert.equal(api.environment.canAccess(api.Clipboard), false);
    await assert.rejects(api.Clipboard.read(), /requires a selected view action/);
  } }) });
  await api.runMenuBar(selected, authorized);
  await api.runMenuBar(denied, { ...authorized, menuAction: 0, menuAlertAllowed: false });
  await api.runMenuBar(denied, { ...authorized, menuAction: 0, clipboardReadAllowed: false });
  assert.equal(broker.mock.callCount(), 0);
  await api.runMenuBar(selected, { ...authorized, menuAction: 0 });
  await detached;
  assert.equal(broker.mock.callCount(), 1);
});

test("menu refreshes and actions restore mounted hook IDs from the visible snapshot", async () => {
  let generated = 0;
  let clicked;
  const { jsx } = api.jsxRuntime;
  function MenuItem() {
    const custom = api.useId(undefined, () => `generated-${++generated}`);
    const automatic = api.useId();
    return jsx(Menu.Item, { title: custom, subtitle: automatic, onAction() { clicked = { custom, automatic }; } });
  }
  const command = () => jsx(Menu, { children: jsx(MenuItem, {}, "item") });
  const initial = await api.runMenuBar(command, { wallTime: 1 });
  const refreshed = await api.runMenuBar(command, { wallTime: 2, viewIDs: initial.viewIDs });
  assert.deepEqual(refreshed.items, initial.items);
  assert.equal(generated, 1);
  await api.runMenuBar(command, { wallTime: 2, viewIDs: refreshed.viewIDs, menuAction: refreshed.items[0].id });
  assert.deepEqual(clicked, { custom: initial.items[0].title, automatic: initial.items[0].subtitle });
  const reopened = await api.runMenuBar(command, { wallTime: 3 });
  assert.notEqual(reopened.items[0].title, initial.items[0].title);
  assert.notEqual(reopened.items[0].subtitle, initial.items[0].subtitle);
  await assert.rejects(api.runMenuBar(command, { wallTime: 1, viewIDs: [[0, "id"], [0, "forged"]] }), /Duplicate view ID/);
});
