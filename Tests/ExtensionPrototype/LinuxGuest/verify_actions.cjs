const assert = require("node:assert/strict");
const test = require("node:test");
const { actionPanelComponents, describeActions, findAction } = require("./action-api.cjs");

const component = (type) => (props) => ({ type, props });
const children = (node) => [node?.props.children].flat(Infinity).filter(Boolean);
const panel = actionPanelComponents(component);
const copy = component("copy");
const callback = component("callback");
const describe = (value) => describeActions(value, children);

test("flat and section actions keep their replay indices", () => {
  const first = copy({ content: "original" });
  const second = callback({ title: "Delete", style: "destructive" });
  const root = panel({ children: [panel.Section({ children: [first] }), panel.Section({ children: [second] })] });
  assert.deepEqual(describe(root), [
    { id: 0, title: "Copy", kind: "copy", destructive: false },
    { id: 1, title: "Delete", kind: "callback", group: 1, destructive: true },
  ]);
  assert.equal(findAction(root, 0, children), first);
  assert.equal(findAction(root, 1, children), second);
});

test("nested submenus retain groups, and only their leaves can be replayed", () => {
  const original = copy({ title: "Copy root", content: "root" });
  const nested = copy({ title: "Copy nested", content: "nested" });
  const direct = callback({ title: "Update" });
  const root = panel({ children: [
    original,
    panel.Submenu({ title: "More", children: [
      panel.Section({ title: "Copy", children: panel.Submenu({ title: "Nested", children: nested }) }),
      direct,
    ] }),
  ] });
  assert.deepEqual(describe(root), [
    { id: 0, title: "Copy root", kind: "copy", destructive: false },
    { id: 1, title: "More", kind: "submenu", children: [
      { id: 2, title: "Nested", kind: "submenu", groupTitle: "Copy", children: [
        { id: 3, title: "Copy nested", kind: "copy", destructive: false },
      ] },
      { id: 4, title: "Update", kind: "callback", group: 1, destructive: false },
    ] },
  ]);
  assert.equal(findAction(root, 1, children), undefined);
  assert.equal(findAction(root, 2, children), undefined);
  assert.equal(findAction(root, 3, children), nested);
  assert.equal(findAction(root, 4, children), direct);
  assert.equal(findAction(root, "3", children), undefined);
  assert.equal(findAction(root, -1, children), undefined);
});

test("action trees reject oversized or deeply nested input during rendering and replay", () => {
  const leaf = copy({ content: "ok" });
  const wide = panel({ children: Array.from({ length: 13 }, () => leaf) });
  let deep = leaf;
  for (let i = 0; i < 4; i++) deep = panel.Submenu({ title: "Deep", children: deep });
  for (const value of [wide, panel({ children: deep })]) {
    assert.throws(() => describe(value), /Action panel limit exceeded/);
    assert.throws(() => findAction(value, 0, children), /Action panel limit exceeded/);
  }
});

test("reviewed List, Grid and Detail replay nested action leaves", async () => {
  const { Action, ActionPanel, Detail, Grid, List, render } = require("./view-api.cjs");
  const actions = ActionPanel({ children: ActionPanel.Submenu({
    title: "Tools",
    children: ActionPanel.Submenu({
      title: "Copy options",
      children: Action.CopyToClipboard({ title: "Copy fixture", content: "nested fixture" }),
    }),
  }) });
  const cases = [
    { command: () => List({ children: List.Item({ title: "List fixture", actions }) }),
      renderedActions: (snapshot) => snapshot.rows[0].actions },
    { command: () => Grid({ children: Grid.Item({ title: "Grid fixture", content: "🧪", actions }) }),
      renderedActions: (snapshot) => snapshot.grid.sections[0].items[0].actions },
    { command: () => Detail({ markdown: "Fixture", actions }),
      renderedActions: (snapshot) => snapshot.detail.actions },
  ];
  for (const { command, renderedActions } of cases) {
    const root = renderedActions(await render(command, { query: "" }))[0];
    assert.equal(root.kind, "submenu");
    const child = root.children[0];
    assert.equal(child.kind, "submenu");
    const leaf = child.children[0];
    assert.deepEqual(await render(command, { query: "", action: { row: 0, id: leaf.id } }),
      { kind: "copy", text: "nested fixture" });
    await assert.rejects(render(command, { query: "", action: { row: 0, id: root.id } }), /Unknown action/);
  }
});

test("current and deprecated action styles use the same SDK values in native action descriptors", async () => {
  const { Action, ActionPanel, Detail, Icon, render } = require("./view-api.cjs");
  assert.deepEqual(Action.Style, { Regular: "regular", Destructive: "destructive" });
  assert.equal(ActionPanel.Item.Style, Action.Style);
  assert.ok(Object.isFrozen(Action.Style));
  assert.equal(Icon.Warning, "warning-16");
  const { detail } = await render(() => Detail({ actions: ActionPanel({ children: [
    Action({ title: "Regular", style: Action.Style.Regular }),
    ActionPanel.Item({ title: "Destructive", style: ActionPanel.Item.Style.Destructive, icon: Icon.Warning }),
  ] }) }), {});
  assert.deepEqual(detail.actions.map(({ destructive, icon }) => [destructive, icon]), [
    [false, undefined], [true, "warning-16"],
  ]);
});

test("panel titles follow the selected target, including empty states and form overrides", async () => {
  const { Action, ActionPanel, Detail, Form, Grid, List, render, useActionPanel } = require("./view-api.cjs");
  const actions = (title) => ActionPanel({ title, children: Action({ title: "Continue", onAction() {} }) });
  const list = () => List({ children: [
    List.Item({ title: "First", actions: actions("First actions") }),
    List.Item({ title: "Second", actions: actions("Second actions") }),
    List.EmptyView({ title: "Empty", actions: actions("Empty actions") }),
  ] });
  assert.deepEqual((await render(list, {})).rows.map((row) => row.actionPanelTitle), ["First actions", "Second actions"]);
  assert.equal((await render(list, { query: "missing" })).empty.actionPanelTitle, "Empty actions");
  assert.deepEqual(await render(list, { action: { row: 0, id: 0 } }), { kind: "action" });
  const passive = () => List({ children: List.Item({ title: "Passive", actions: ActionPanel({
    children: Action({ title: "No operation" }),
  }) }) });
  assert.deepEqual(await render(passive, { action: { row: 0, id: 0 } }), { kind: "action" });

  const grid = () => Grid({ actions: actions("Empty grid"), children: [
    Grid.Item({ title: "Only", content: "★", actions: actions("Grid actions") }),
  ] });
  assert.equal((await render(grid, {})).grid.sections[0].items[0].actionPanelTitle, "Grid actions");
  assert.equal((await render(grid, { query: "missing" })).grid.actionPanelTitle, "Empty grid");

  const detail = await render(() => Detail({ markdown: "Fixture", actions: actions("Details") }), {});
  assert.equal(detail.detail.actionPanelTitle, "Details");
  const form = await render(() => {
    useActionPanel().update(actions("Form override"));
    return Form({ actions: actions("Original title") });
  }, {});
  assert.equal(form.formActionPanelTitle, "Form override");
});

test("shortcut descriptors accept macOS chords and expose the requested menu focus", () => {
  const { Action, ActionPanel, Keyboard } = require("./view-api.cjs");
  const tree = ActionPanel({ children: [
    Action({ title: "Open", shortcut: Keyboard.Shortcut.Common.Open, autoFocus: true }),
    ActionPanel.Submenu({ title: "Tools", shortcut: { key: "arrowRight", modifiers: ["cmd", "opt"] }, autoFocus: true }),
    Action({ title: "Windows only", shortcut: { key: "r", modifiers: ["windows"] } }),
    Action({ title: "Invalid", shortcut: { key: "q", modifiers: ["cmd", "cmd"] } }),
  ] });
  const items = describe(tree);
  assert.deepEqual(items[0].shortcut, { key: "o", modifiers: ["cmd"] });
  assert.deepEqual(items[1].shortcut, { key: "arrowRight", modifiers: ["cmd", "opt"] });
  assert.equal(items[0].autoFocus, true);
  assert.equal(items[1].autoFocus, true);
  assert.equal(items[2].shortcut, undefined);
  assert.equal(items[3].shortcut, undefined);
});

test("dynamic nested menus reconstruct onOpen and custom search before executing the scoped leaf", async () => {
  const { Action, ActionPanel, ActionPanelSubmenu, Detail, List, render, useState } = require("./view-api.cjs");
  function command() {
    const [opened, setOpened] = useState(false);
    const [query, setQuery] = useState(undefined);
    const children = [
      Action.CopyToClipboard({ title: "Outside", content: "outside" }),
      ActionPanelSubmenu({
        title: "Load", isLoading: !opened, throttle: true,
        async onOpen() {
          await new Promise(setImmediate);
          setOpened(true);
        },
        onSearchTextChange: setQuery,
        children: opened ? [
          ActionPanel.Section({ title: "Group", children: [
            ActionPanel.Submenu({
              title: "Nested",
              children: [
                Action.CopyToClipboard({ title: "Copy", content: query ?? "default" }),
                Action.Push({ title: "Open details", target: Detail({ markdown: query ?? "default" }) }),
              ],
            }),
          ] }),
        ] : [],
      }),
    ];
    return List({ children: List.Item({ title: "Row", actions: ActionPanel({ children }) }) });
  }

  const root = await render(command, { query: "" });
  assert.equal(root.rows[0].actions[1].submenu.isLoading, true);
  assert.equal(root.rows[0].actions[1].children.length, 0);
  const parent = { index: 1, query: "中文" };
  const loaded = await render(command, { query: "", actionMenuRow: 0, actionMenuRoute: [parent] });
  assert.equal(loaded.kind, "actionMenu");
  assert.equal(loaded.submenu.isLoading, false);
  assert.equal(loaded.submenu.observesSearch, true);
  assert.equal(loaded.submenu.nativeFiltering, false);
  assert.equal(loaded.actions[0].groupTitle, "Group");
  const actionMenuRoute = [parent, { index: 0 }];
  const nested = await render(command, { query: "", actionMenuRow: 0, actionMenuRoute });
  const id = nested.actions[0].id;
  assert.deepEqual(await render(command, { query: "", action: { row: 0, id }, actionMenuRoute }),
    { kind: "copy", text: "中文" });
  assert.deepEqual(await render(command, { query: "", action: { row: 0, id }, actionMenuRoute: [{ index: 1, query: "" }, { index: 0 }] }),
    { kind: "copy", text: "" });
  const pushID = nested.actions[1].id;
  assert.deepEqual(await render(command, { query: "", action: { row: 0, id: pushID }, actionMenuRoute }),
    { kind: "pushView", routeMode: "action" });
  const detail = await render(command, { query: "", viewRoute: [{ query: "", row: 0, id: pushID, mode: "action", actionMenuRoute }] });
  assert.equal(detail.detail.markdown, "中文");
  await assert.rejects(render(command, { query: "", actionMenuRow: 0, actionMenuRoute: [{ index: 0 }] }),
    /Unknown action submenu/);
  await assert.rejects(render(command, { query: "", actionMenuRow: 0, actionMenuRoute: [{ index: 1, query: "中".repeat(86) }] }),
    /Invalid action submenu route/);
});

test("submenu lifecycle callbacks cannot use selected-action or storage grants", async () => {
  const { ActionPanel, Detail, LocalStorage, render, open } = require("./view-api.cjs");
  const { Cache } = require("./cache-api.cjs");
  for (const callback of [
    () => open("https://example.com"),
    () => LocalStorage.setItem("fixture", "blocked"),
    () => new Cache().set("fixture", "blocked"),
  ]) {
    const command = () => Detail({ actions: ActionPanel({ children: ActionPanel.Submenu({ title: "Restricted", onOpen: callback }) }) });
    await assert.rejects(render(command, { cache: [], storage: {}, actionMenuRow: 0, actionMenuRoute: [{ index: 0 }] }),
      /requires|unavailable/);
  }
});
