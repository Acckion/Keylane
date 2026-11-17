const assert = require("node:assert/strict");
const { test } = require("node:test");
const { configureEnvironment } = require("./environment.cjs");
const noView = require("./raycast-api.cjs");
const view = require("./view-api.cjs");

const definition = {
  name: "choice",
  type: "dropdown",
  required: true,
  title: "Choice",
  description: "Choose a value",
  default: "one",
  data: [{ title: "One", value: "one" }, { title: "Two", value: "two" }],
};

test("view module imports see scoped preference metadata and resolved values", async () => {
  const imported = view.preferences;
  const input = {
    preferences: JSON.parse('{"choice":"two","active":false,"__proto__":"configured"}'),
    preferenceDefinitions: [
      { ...definition, title: "Shared choice" },
      definition,
      { name: "missing", type: "textfield", placeholder: "Type here", value: "unresolved" },
    ],
  };
  view.prepareInput(input);
  assert.equal(imported.choice.value, "two");
  assert.equal(imported.toString, undefined);

  const reply = await view.render(() => {
    assert.deepEqual(imported.choice, { ...definition, value: "two" });
    assert.equal(imported.active.type, "checkbox");
    assert.equal(imported.active.value, false);
    assert.equal(imported.__proto__.value, "configured");
    assert.equal(imported.missing.placeholder, "Type here");
    assert.equal("value" in imported.missing, false);
    assert.equal(Reflect.set(imported.choice.data[0], "value", "changed"), false);
    assert.equal(Reflect.set(imported, "choice", {}), false);
    assert.equal(Reflect.deleteProperty(imported, "choice"), false);
    assert.equal(Reflect.setPrototypeOf(imported, {}), false);
    assert.deepEqual(Object.keys(imported).sort(), ["__proto__", "active", "choice", "missing"]);
    assert.deepEqual(Object.fromEntries(
      Object.entries(imported).filter(([, field]) => "value" in field).map(([name, field]) => [name, field.value])
    ), view.getPreferenceValues());
    return view.Detail({ markdown: imported.choice.value });
  }, input);
  assert.equal(reply.detail.markdown, "two");
  view.prepareInput({});
  assert.deepEqual(Object.keys(imported), []);
});

test("no-view preferences use the existing broker snapshot and support legacy scalar payloads", async (t) => {
  const imported = noView.preferences;
  const request = t.mock.method(noView, "request", async () => JSON.stringify({
    preferences: { choice: "two" },
    preferenceDefinitions: [definition],
  }));
  await noView.loadPreferences();
  assert.deepEqual(imported.choice, { ...definition, value: "two" });
  assert.equal(imported.choice.value, noView.getPreferenceValues().choice);
  assert.deepEqual(request.mock.calls.map(({ arguments: args }) => args), [["preferences.read", ""]]);

  request.mock.mockImplementation(async () => '{"choice":"one"}');
  await noView.loadPreferences();
  assert.equal(imported.choice.value, "one");
  assert.equal(imported.choice.type, "textfield");
});

test("useId remains stable through rerenders and distinguishes calls and commands", async () => {
  const pairs = [];
  const command = () => {
    const first = view.useId();
    const [query, setQuery] = view.useState("");
    const second = view.useId();
    pairs.push([first, second, query]);
    return view.List({ onSearchTextChange: setQuery });
  };

  configureEnvironment({ ownerOrAuthorName: "example", extensionName: "fixture", entryPointName: "first" });
  await view.render(command, { query: "test" });
  assert.equal(typeof pairs[0][0], "string");
  assert.notEqual(pairs[0][0], pairs[0][1]);
  assert.deepEqual(pairs, [
    [...pairs[0].slice(0, 2), ""],
    [...pairs[0].slice(0, 2), "test"],
  ]);

  configureEnvironment({ ownerOrAuthorName: "example", extensionName: "fixture", entryPointName: "second" });
  await view.render(command, {});
  assert.notEqual(pairs[0][0], pairs[2][0]);
});

test("both adapters expose the same immutable keyboard key equivalents", () => {
  const names = [
    "return", "delete", "deleteForward", "tab", "arrowUp", "arrowDown", "arrowLeft", "arrowRight",
    "pageUp", "pageDown", "home", "end", "space", "escape", "enter", "backspace",
  ];
  assert.equal(view.specialKeys, noView.specialKeys);
  assert.equal(Object.isFrozen(view.specialKeys), true);
  assert.deepEqual(Object.keys(view.specialKeys), names);
  assert.deepEqual(Object.values(view.specialKeys), names);
});

test("legacy useId honors an initial ID or a custom generator and memoizes both on rerender", async () => {
  const renders = [];
  let calls = 0;
  const command = () => {
    const [query, setQuery] = view.useState("");
    renders.push([
      view.useId(query || "default", () => assert.fail("Unexpected generator call")),
      view.useId(undefined, () => `custom-${++calls}`),
      view.useId(""),
    ]);
    return view.List({ onSearchTextChange: setQuery });
  };
  await view.render(command, { query: "updated" });
  assert.deepEqual(renders, [["default", "custom-1", ""], ["default", "custom-1", ""]]);
  assert.equal(calls, 1);
  await view.render(command, {});
  assert.deepEqual(renders.at(-1), ["default", "custom-2", ""]);
});

test("modern and legacy preferences agree on defaults across view and no-view", async (t) => {
  const definitions = [
    { name: "choice", type: "dropdown", default: "shared" },
    { name: "choice", type: "dropdown", default: "command" },
    { name: "enabled", type: "checkbox", default: true },
    { name: "empty", type: "textfield", default: "fallback" },
    { name: "unresolved", type: "textfield", default: "shared value" },
    { name: "unresolved", type: "password" },
    { name: "__proto__", type: "textfield", default: "ordinary preference" },
  ];
  const input = { preferences: { enabled: false, empty: "" }, preferenceDefinitions: definitions };
  t.mock.method(noView, "request", async () => JSON.stringify(input));
  await noView.loadPreferences();
  view.prepareInput(input);

  for (const api of [view, noView]) {
    assert.deepEqual(api.getPreferenceValues(), {
      choice: "command", enabled: false, empty: "", ["__proto__"]: "ordinary preference",
    });
    assert.equal(api.preferences.choice.default, "command");
    assert.equal(api.preferences.choice.value, "command");
    assert.equal(api.preferences.enabled.value, false);
    assert.equal(api.preferences.empty.value, "");
    assert.equal("value" in api.preferences.unresolved, false);
    assert.equal(api.preferences.__proto__.value, "ordinary preference");
    api.getPreferenceValues().choice = "changed";
    assert.equal(api.getPreferenceValues().choice, "command");
  }
});

test("useId snapshots replay custom IDs into later invocations and stay out of password replies", async () => {
  let calls = 0;
  const command = () => {
    const id = view.useId(undefined, () => `generated-${++calls}`);
    return view.Detail({ markdown: id, actions: view.ActionPanel({
      children: view.Action.CopyToClipboard({ content: id }),
    }) });
  };
  const first = await view.render(command, {});
  assert.equal(first.detail.markdown, "generated-1");
  assert.deepEqual(first.viewIDs, [[0, "generated-1"]]);
  const second = await view.render(command, { viewIDs: first.viewIDs, action: { row: 0, id: 0 } });
  assert.equal(second.text, "generated-1");
  assert.equal(calls, 1);
  assert.equal((await view.render(command, {})).detail.markdown, "generated-2");
  await assert.rejects(view.render(command, { viewIDs: [[0, "one"], [0, "two"]] }), /Duplicate view ID/);
  const passwordForm = () => {
    const id = view.useId("secret-form");
    return view.Form({ children: view.Form.PasswordField({ id }), actions: view.ActionPanel({
      children: view.Action.SubmitForm({ onSubmit: () => true }),
    }) });
  };
  assert.equal((await view.render(passwordForm, { sensitiveFormSubmission: true,
    action: { row: 0, id: 0 }, formValues: { "secret-form": "test" },
  })).viewIDs, undefined);
});

test("updateCommandMetadata waits for the host, preserves empty text and clears with null", async (t) => {
  const bridge = require("./raycast-api.cjs");
  const api = require("./view-api.cjs");
  const sent = [];
  let completion;
  const pending = new Promise((resolve) => { completion = resolve; });
  t.mock.method(bridge, "request", async (capability, text) => {
    assert.equal(capability, "command.updateMetadata");
    sent.push(JSON.parse(text));
    if (sent.length === 1) await pending;
  });
  let finished = false;
  const update = bridge.updateCommandMetadata({ subtitle: "待处理" }).then(() => { finished = true; });
  await new Promise(setImmediate);
  assert.equal(finished, false);
  completion();
  await update;
  await bridge.updateCommandMetadata({});
  await bridge.updateCommandMetadata({ subtitle: "" });
  await bridge.updateCommandMetadata({ subtitle: null });
  await assert.rejects(bridge.updateCommandMetadata({ subtitle: 4 }), /Invalid command subtitle/);
  const command = () => {
    api.useEffect(async () => { await api.updateCommandMetadata({ subtitle: "Menu" }); });
    return api.MenuBarExtra({ title: "Menu" });
  };
  await api.runMenuBar(command, { commandMetadataAllowed: true, wallTime: 0 });
  assert.deepEqual(sent, [{ subtitle: "待处理" }, { subtitle: "" }, { subtitle: null }, { subtitle: "Menu" }]);
});

test("keyed component instances preserve their hook IDs across sibling reordering and request replay", async () => {
  const { jsx, Fragment } = view.jsxRuntime;
  let generated = 0;
  function Row({ name }) {
    const custom = view.useId(undefined, () => `${name}-${++generated}`);
    const standard = view.useId();
    return jsx(view.List.Item, { title: name, id: standard, actions: jsx(view.ActionPanel, {
      children: jsx(view.Action.CopyToClipboard, { content: custom }),
    }) });
  }
  const command = () => {
    const [reordered, setReordered] = view.useState(false);
    const names = reordered ? ["b", "a"] : ["a", "b"];
    return jsx(view.List, {
      filtering: false,
      onSearchTextChange: (query) => setReordered(query === "reorder"),
      children: jsx(Fragment, { children: names.map((name) => jsx(Row, { name }, name)) }),
    });
  };
  const first = await view.render(command, { query: "" });
  assert.equal(generated, 2);
  assert.equal(first.viewIDs.filter(([slot]) => slot !== Number.MAX_SAFE_INTEGER).length, 2);
  assert.notEqual(first.rows[0].itemID, first.rows[1].itemID);
  const replayed = await view.render(command, { query: "reorder", viewIDs: first.viewIDs });
  assert.deepEqual(replayed.rows.map(({ title }) => title), ["b", "a"]);
  assert.deepEqual(replayed.rows.map(({ itemID }) => itemID), first.rows.map(({ itemID }) => itemID).reverse());
  const action = await view.render(command, { query: "reorder", viewIDs: first.viewIDs, action: { row: 0, id: 0 } });
  assert.equal(action.text, "b-2");
  assert.equal(generated, 2);
});

test("equal keys in independent parents and unkeyed siblings get distinct IDs", async () => {
  const { jsx } = view.jsxRuntime;
  const Row = () => view.List.Item({ title: "Cell", id: view.useId() });
  const command = () => jsx(view.List, { children: [
    jsx(view.List.Section, { children: [jsx(Row, {}, "same"), jsx(Row, {}), jsx(Row, {})] }, "a"),
    jsx(view.List.Section, { children: jsx(Row, {}, "same") }, "b"),
  ] });
  const result = await view.render(command, {});
  assert.equal(new Set(result.rows.map(({ itemID }) => itemID)).size, 4);
});

test("removed component instances release their custom ID snapshots", async () => {
  const { jsx } = view.jsxRuntime;
  let generated = 0;
  const Row = () => view.List.Item({ title: view.useId(undefined, () => `id-${++generated}`) });
  const command = () => {
    const [visible, setVisible] = view.useState(true);
    return jsx(view.List, { onSearchTextChange: () => setVisible(false), children: visible ? jsx(Row, {}, "row") : null });
  };
  const first = await view.render(command, {});
  assert.equal(first.rows[0].title, "id-1");
  const removed = await view.render(command, { query: "hide", viewIDs: first.viewIDs });
  assert.deepEqual(removed.viewIDs, []);
  assert.equal((await view.render(command, {})).rows[0].title, "id-2");
});

test("automatic IDs reappear with a new identity after remount while the parent retains its ID", async () => {
  const { jsx } = view.jsxRuntime;
  const Child = () => view.List.Item({ title: "Child", id: view.useId() });
  const command = () => {
    const parentID = view.useId();
    const [visible, setVisible] = view.useState(true);
    return jsx(view.List, {
      filtering: false,
      onSearchTextChange: (query) => setVisible(query !== "hide"),
      children: [
        jsx(view.List.Item, { title: "Parent", id: parentID }, "parent"),
        visible ? jsx(Child, {}, "child") : null,
      ],
    });
  };
  const initial = await view.render(command, { query: "" });
  const retained = await view.render(command, { query: "refresh", viewIDs: initial.viewIDs });
  assert.deepEqual(retained.rows.map(({ itemID }) => itemID), initial.rows.map(({ itemID }) => itemID));

  const hidden = await view.render(command, { query: "hide", viewIDs: retained.viewIDs });
  assert.deepEqual(hidden.rows.map(({ itemID }) => itemID), [initial.rows[0].itemID]);
  const remounted = await view.render(command, { query: "show", viewIDs: hidden.viewIDs });
  assert.equal(remounted.rows[0].itemID, initial.rows[0].itemID);
  assert.notEqual(remounted.rows[1].itemID, initial.rows[1].itemID);
  const again = await view.render(command, { query: "refresh", viewIDs: remounted.viewIDs });
  assert.deepEqual(again.rows.map(({ itemID }) => itemID), remounted.rows.map(({ itemID }) => itemID));

  const fresh = await view.render(command, { query: "" });
  assert.notEqual(fresh.rows[0].itemID, initial.rows[0].itemID);
  assert.notEqual(fresh.rows[1].itemID, initial.rows[1].itemID);
  await assert.rejects(view.render(command, { viewIDs: [[Number.MAX_SAFE_INTEGER, "invalid"]] }), /Invalid view ID snapshot/);
});

test("large ID snapshots restore every custom ID in a long keyed list", async () => {
  const { jsx } = view.jsxRuntime;
  let generated = 0;
  const Row = ({ index }) => view.List.Item({
    title: String(index), subtitle: view.useId(undefined, () => `value-${++generated}-${"测".repeat(12)}`),
  });
  const command = () => jsx(view.List, {
    children: Array.from({ length: 64 }, (_, index) => jsx(Row, { index }, index)),
  });
  const first = await view.render(command, {});
  assert.equal(first.viewIDs.length, 64);
  assert.ok(Buffer.byteLength(JSON.stringify(first.viewIDs)) > 2048);
  const next = await view.render(command, { viewIDs: first.viewIDs });
  assert.equal(generated, 64);
  assert.deepEqual(next.rows.map(({ subtitle }) => subtitle), first.rows.map(({ subtitle }) => subtitle));
  await assert.rejects(view.render(command, {
    viewIDs: Array.from({ length: 97 }, (_, index) => [index, "id"]),
  }), /Invalid view ID snapshot/);
});
