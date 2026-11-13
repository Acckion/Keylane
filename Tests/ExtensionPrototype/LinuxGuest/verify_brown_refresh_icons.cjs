const assert = require("node:assert/strict");
const { test } = require("node:test");
const { Action, ActionPanel, Color, Grid, Icon, List, render } = require("./view-api.cjs");
const noView = require("./raycast-api.cjs");

test("refresh symbols match the declared Raycast values in both adapters", () => {
  assert.equal(Icon.ArrowClockwise, "arrow-clockwise-16");
  assert.equal(Icon.ArrowCounterClockwise, "arrow-counter-clockwise-16");
  assert.equal(noView.Icon, Icon);
  assert.equal(noView.Color.Brown, Color.Brown);
  assert.ok(Object.isFrozen(Color.Brown));
  assert.notEqual(Color.Brown.light, Color.Brown.dark);
});

test("List serializes a refresh symbol and the Brown tint for both appearances", async () => {
  const view = await render(() => List({ children: List.Item({
    title: "Refresh",
    icon: { source: Icon.ArrowClockwise, tintColor: Color.Brown },
    actions: ActionPanel({ children: Action({
      title: "Refresh",
      icon: Icon.ArrowCounterClockwise,
      onAction() {},
    }) }),
  }) }), {});
  const [row] = view.rows;
  assert.equal(row.icon, Icon.ArrowClockwise);
  assert.equal(row.tintColor, Color.Brown.light);
  assert.equal(row.darkTintColor, Color.Brown.dark);
  assert.equal(row.actions[0].icon, Icon.ArrowCounterClockwise);
});

test("Grid serializes both refresh symbols and preserves the Brown swatch by appearance", async () => {
  const view = await render(() => Grid({ children: [
    Grid.Item({ title: "Refresh", content: Icon.ArrowClockwise }),
    Grid.Item({ title: "Revert", content: { source: Icon.ArrowCounterClockwise, tintColor: Color.Brown } }),
    Grid.Item({ title: "Brown", content: { color: Color.Brown } }),
  ] }), {});
  const [refresh, revert, swatch] = view.grid.sections[0].items;
  assert.equal(refresh.glyph, Icon.ArrowClockwise);
  assert.equal(revert.glyph, Icon.ArrowCounterClockwise);
  assert.equal(revert.tintColor, Color.Brown.light);
  assert.equal(revert.darkTintColor, Color.Brown.dark);
  assert.equal(swatch.color, Color.Brown.light);
  assert.equal(swatch.darkColor, Color.Brown.dark);
});
