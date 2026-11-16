const assert = require("node:assert/strict");
const { test } = require("node:test");
const { createHash } = require("node:crypto");
const { Action, ActionPanel, Color, Grid, Icon, List, render } = require("./view-api.cjs");
const noView = require("./raycast-api.cjs");

test("common icons expose their pinned Raycast values in both adapters", () => {
  assert.equal(Icon.Check, "check-16");
  assert.equal(Icon.MagnifyingGlass, "magnifying-glass-16");
  assert.equal(Icon.Plus, "plus-16");
  assert.equal(noView.Icon, Icon);
});

test("common icons use the existing List, action panel, dropdown, and Grid icon paths", async () => {
  const list = await render(() => List({
    searchBarAccessory: List.Dropdown({
      tooltip: "Filter",
      children: List.Dropdown.Item({ title: "All", value: "all", icon: Icon.MagnifyingGlass }),
    }),
    children: List.Item({
      title: "Add",
      icon: { source: Icon.Plus, tintColor: Color.Blue },
      actions: ActionPanel({ children: Action({ title: "Check", icon: Icon.Check }) }),
    }),
  }), {});
  const [row] = list.rows;
  assert.equal(row.icon, Icon.Plus);
  assert.equal(row.tintColor, Color.Blue);
  assert.equal(row.actions[0].icon, Icon.Check);
  assert.equal(list.dropdown.sections[0].items[0].icon, Icon.MagnifyingGlass);

  const grid = await render(() => Grid({
    children: Grid.Item({ title: "Search", content: Icon.MagnifyingGlass }),
  }), {});
  assert.equal(grid.grid.sections[0].items[0].glyph, Icon.MagnifyingGlass);
});

test("nine existing icon members match their SDK values through List, Grid, actions and menu-bar replies", async () => {
  const { MenuBarExtra, runMenuBar } = require("./view-api.cjs");
  const values = {
    Clipboard: "copy-clipboard-16", Clock: "clock-16", Document: "blank-document-16",
    Folder: "folder-16", Key: "key-16", Link: "link-16",
    Pencil: "pencil-16", Tag: "tag-16", Trash: "trash-16",
  };
  const names = Object.keys(values);
  const expected = Object.values(values);
  assert.deepEqual(names.map((name) => Icon[name]), expected);
  assert.equal(noView.Icon, Icon);

  const list = await render(() => List({ children: names.map((name) => List.Item({
    title: name, icon: { source: Icon[name], tintColor: Color.Blue },
    actions: ActionPanel({ children: Action({ title: name, icon: Icon[name] }) }),
  })) }), {});
  assert.deepEqual(list.rows.map((row) => [row.icon, row.tintColor, row.actions[0].icon]),
    expected.map((icon) => [icon, Color.Blue, icon]));

  const grid = await render(() => Grid({ children: names.map((name) => Grid.Item({
    title: name, content: Icon[name],
  })) }), {});
  assert.deepEqual(grid.grid.sections[0].items.map((item) => item.glyph), expected);

  const menu = await runMenuBar(() => MenuBarExtra({
    icon: Icon.Clock, children: names.map((name) => MenuBarExtra.Item({ title: name, icon: Icon[name] })),
  }), { wallTime: 0 });
  assert.equal(menu.icon, Icon.Clock);
  assert.deepEqual(menu.items.map((item) => item.icon), expected);
});

test("both adapters export every pinned SDK icon, including legacy aliases and numbered values", () => {
  assert.equal(Object.keys(Icon).length, 478);
  assert.equal(new Set(Object.values(Icon)).size, 459);
  assert.equal(createHash("sha256").update(JSON.stringify(Icon)).digest("hex"),
    "6969ad9577bdb7d8858108b7b6eb40d1e0c86b719488fd759ed357c975282cd1");
  assert.equal(noView.Icon, Icon);
  assert.ok(Object.isFrozen(Icon));
});

test("all standard Color constants match the pinned SDK and share the same guest object", () => {
  const { Brown, ...standard } = Color;
  assert.deepEqual(standard, {
    Blue: "raycast-blue", Green: "raycast-green", Magenta: "raycast-magenta", Orange: "raycast-orange",
    Purple: "raycast-purple", Red: "raycast-red", Yellow: "raycast-yellow", PrimaryText: "raycast-primary-text",
    SecondaryText: "raycast-secondary-text",
  });
  assert.equal(typeof Brown.light, "string");
  assert.equal(typeof Brown.dark, "string");
  assert.equal(noView.Color, Color);
});
