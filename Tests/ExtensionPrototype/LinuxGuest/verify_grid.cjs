const assert = require("node:assert/strict");
const test = require("node:test");
const { Action, ActionPanel, Grid, render } = require("./view-api.cjs");

const png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jK5cAAAAASUVORK5CYII=";
const copy = (content) => ActionPanel({ children: Action.CopyToClipboard({ content }) });
const children = [
  Grid.Item({ title: "Café", content: "☕", actions: copy("coffee") }),
  Grid.Section({ title: "Palette", subtitle: "Samples", columns: 2, aspectRatio: "1",
    fit: Grid.Fit.Contain, inset: Grid.Inset.Zero, children: [
    Grid.Item({ title: "Azure", subtitle: "Colour", keywords: ["蓝色"], content: { color: "#10e" }, actions: copy("blue") }),
    Grid.Item({ title: "Pixel", content: { value: { source: png }, tooltip: "A pixel" } }),
    Grid.Item({ title: "Remote", content: { source: "https://example.invalid/asset.png" } }),
  ] }),
  Grid.EmptyView({ title: "No matches", description: "Try another search" }),
];
const command = () => Grid({ columns: 3, aspectRatio: "3/2", fit: Grid.Fit.Fill, inset: Grid.Inset.Small,
  children, actions: copy("empty") });

test("grid serializes sections, layouts, glyphs, colors, and inline images", async () => {
  const { kind, grid } = await render(command, {});
  assert.equal(kind, "grid");
  assert.deepEqual([grid.columns, grid.aspectRatio, grid.fit, grid.inset], [3, "3/2", "fill", "sm"]);
  assert.equal(grid.sections[0].items[0].glyph, "☕");
  assert.equal(grid.sections[0].columns, undefined);
  const { title, subtitle, columns, aspectRatio, fit, inset } = grid.sections[1];
  assert.deepEqual([title, subtitle, columns, aspectRatio, fit, inset], ["Palette", "Samples", 2, "1", "contain", "zero"]);
  assert.equal(grid.sections[1].items[0].color, "#10e");
  assert.equal(grid.sections[1].items[1].image, png);
  assert.equal(grid.sections[1].items[2].glyph, undefined);
  assert.equal(grid.sections[1].items[2].image, undefined);
});

test("filtered selection replays the action for the same item", async () => {
  assert.equal((await render(command, { query: "cafe" })).grid.sections[0].items[0].title, "Café");
  const { grid } = await render(command, { query: "蓝色" });
  assert.equal(grid.sections[0].columns, 2);
  const id = grid.sections[0].items[0].id;
  assert.deepEqual(await render(command, { query: "蓝色", action: { row: id, id: 0 } }), { kind: "copy", text: "blue" });
  await assert.rejects(render(command, { query: "蓝色", action: { row: 1, id: 0 } }), /Unknown grid item/);
});

test("empty state and root actions are available after filtering", async () => {
  const { grid } = await render(command, { query: "absent" });
  assert.deepEqual(grid.sections, []);
  assert.equal(grid.empty.title, "No matches");
  assert.deepEqual(await render(command, { query: "absent", action: { row: -1, id: 0 } }), { kind: "copy", text: "empty" });
  const custom = () => Grid({ filtering: false, children });
  assert.equal((await render(custom, { query: "absent" })).grid.sections.length, 2);
});

test("custom empty view actions take precedence and are hidden while loading without a query", async () => {
  const command = () => Grid({ isLoading: true, actions: copy("root"), children: [
    Grid.Item({ title: "Visible" }),
    Grid.EmptyView({ title: "No matches", icon: { source: "https://example.invalid/empty.png", fallback: "Folder" },
      actions: ActionPanel({ title: "Empty actions", children: ActionPanel.Submenu({ title: "More", children:
        Action.CopyToClipboard({ content: "empty" }),
      }) }),
    }),
  ] });

  for (const query of ["", "Visible"]) {
    const { grid } = await render(command, { query });
    assert.equal(grid.empty, undefined);
    assert.deepEqual(grid.actions, []);
    await assert.rejects(render(command, { query, action: { row: -1, id: 0 } }), /Unknown grid item/);
  }

  const query = "missing";
  const { grid } = await render(command, { query });
  assert.equal(grid.empty.title, "No matches");
  assert.equal(grid.empty.imageDescriptor.fallbackLight.symbol, "Folder");
  assert.equal(grid.actionPanelTitle, "Empty actions");
  assert.deepEqual(grid.actions.map(({ title }) => title), ["More"]);

  const actionMenuRoute = [{ index: 0 }];
  const menu = await render(command, { query, actionMenuRow: -1, actionMenuRoute });
  assert.equal(menu.kind, "actionMenu");
  const [{ id }] = menu.actions;
  assert.deepEqual(await render(command, { query, action: { row: -1, id }, actionMenuRoute }),
    { kind: "copy", text: "empty" });
});

test("grid ranks sections by the best visible item unless section order is fixed", async () => {
  const command = (filtering) => () => Grid({ filtering, children: [
    Grid.Section({ title: "First", children: [
      Grid.Item({ title: "XabZ", keywords: ["猫"], actions: copy("substring") }),
      Grid.Item({ title: "Absent" }),
    ] }),
    Grid.Section({ title: "Second", children: [
      Grid.Item({ title: "abacus", keywords: ["猫"] }),
      Grid.Item({ title: "ab", keywords: ["猫"], actions: copy("exact") }),
    ] }),
  ] });
  const query = "ab 猫";
  const ranked = await render(command(true), { query });
  assert.deepEqual(ranked.grid.sections.map(({ title }) => title), ["Second", "First"]);
  assert.deepEqual(ranked.grid.sections[0].items.map(({ title }) => title), ["ab", "abacus"]);
  const id = ranked.grid.sections[0].items[0].id;
  assert.deepEqual(await render(command(true), { query, action: { row: id, id: 0 } }),
    { kind: "copy", text: "exact" });
  const fixed = await render(command({ keepSectionOrder: true }), { query });
  assert.deepEqual(fixed.grid.sections.map(({ title }) => title), ["First", "Second"]);
  assert.deepEqual(fixed.grid.sections[1].items.map(({ title }) => title), ["ab", "abacus"]);
});

test("List and Grid selection callbacks receive item IDs and null, and replay before actions", async () => {
  const { List, useState, LocalStorage } = require("./view-api.cjs");
  for (const View of [List, Grid]) {
    const command = () => {
      const [id, select] = useState("initial");
      return View({ selectedItemId: id === "initial" ? "beta" : id, onSelectionChange: select, children: [
        View.Item({ id: "alpha", title: "Alpha", content: "A", actions: copy(String(id)) }),
        View.Item({ id: "beta", title: "Beta", content: "B", actions: copy(String(id)) }),
        View.EmptyView({ title: "No matches", actions: copy(String(id)) }),
      ] });
    };
    const initial = await render(command, {});
    assert.equal(initial.selectedRow, 1);
    assert.equal(initial.observesSelection, true);
    const change = await render(command, { selectedItemId: "alpha", selectionEvent: true });
    const rows = change.rows ?? change.grid.sections.flatMap(({ items }) => items);
    assert.equal(rows[0].itemID, "alpha");
    assert.equal(change.selectedRow, 0);
    assert.deepEqual(await render(command, { selectedItemId: "alpha", action: { row: 0, id: 0 } }),
      { kind: "copy", text: "alpha" });
    const alpha = await render(command, { query: "alpha", selectedItemId: "alpha", action: { row: 0, id: 0 } });
    assert.deepEqual(alpha, { kind: "copy", text: "alpha" });
    assert.deepEqual(await render(command, { query: "missing", action: { row: -1, id: 0 } }), { kind: "copy", text: "null" });
    await assert.rejects(render(() => View({ onSelectionChange: () => LocalStorage.setItem("denied", "value"),
      children: View.Item({ id: "one", title: "One", content: "1" }),
    }), { storage: {} }), /unavailable while reconstructing/);
  }
});

test("generated UUIDs for unkeyed List and Grid items survive filtering and action replay", async () => {
  const { List, useState } = require("./view-api.cjs");
  for (const View of [List, Grid]) {
    const command = () => {
      const [selected, setSelected] = useState(null);
      return View({ onSelectionChange: setSelected, children: [
        View.Item({ title: "Same", content: "A", actions: copy(String(selected)) }),
        View.Item({ title: "Same", content: "B", actions: copy(String(selected)) }),
        View.Item({ title: "Target", content: "C", actions: copy(String(selected)) }),
      ] });
    };
    const rows = (reply) => reply.rows ?? reply.grid.sections.flatMap(({ items }) => items);
    const ids = rows(await render(command, {})).map(({ itemID }) => itemID);
    assert.equal(new Set(ids).size, 3);
    assert.match(ids[2], /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/);
    const query = "Target";
    assert.equal(rows(await render(command, { query }))[0].itemID, ids[2]);
    assert.deepEqual(await render(command, { query, selectedItemId: ids[2], action: { row: 0, id: 0 } }),
      { kind: "copy", text: ids[2] });
  }
});
