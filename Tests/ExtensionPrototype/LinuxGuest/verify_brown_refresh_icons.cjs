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
  assert.deepEqual(Color.Brown, { light: "#714426", dark: "#9F6138" });
});

test("List serializes a refresh symbol and the Brown tint for both appearances", async () => {
  const view = await render(() => List({ children: List.Item({
    title: "Refresh",
    icon: { source: Icon.ArrowClockwise, tintColor: { ...Color.Brown, adjustContrast: false } },
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
    Grid.Item({ title: "Revert", content: { source: Icon.ArrowCounterClockwise, tintColor: { ...Color.Brown, adjustContrast: false } } }),
    Grid.Item({ title: "Brown", content: { color: { ...Color.Brown, adjustContrast: false } } }),
  ] }), {});
  const [refresh, revert, swatch] = view.grid.sections[0].items;
  assert.equal(refresh.glyph, Icon.ArrowClockwise);
  assert.equal(revert.glyph, Icon.ArrowCounterClockwise);
  assert.equal(revert.tintColor, Color.Brown.light);
  assert.equal(revert.darkTintColor, Color.Brown.dark);
  assert.equal(swatch.color, Color.Brown.light);
  assert.equal(swatch.darkColor, Color.Brown.dark);
});

test("raw RGB and HSL colors preserve alpha in grid, icons and detail metadata", async () => {
  const { Detail } = require("./view-api.cjs");
  const { grid } = await render(() => Grid({ children: [
    Grid.Item({ title: "RGB", content: { color: { light: "rgb(255, 0, 127)", adjustContrast: false } } }),
    Grid.Item({ title: "RGBA", content: { color: { light: "rgba(100%, 0%, 50%, 25%)", adjustContrast: false } } }),
    Grid.Item({ title: "Dynamic", content: { color: { light: "hsl(120, 100%, 50%)", dark: "hsla(-120, 100%, 50%, .5)", adjustContrast: false } } }),
    Grid.Item({ title: "Short hex alpha", content: { color: { light: "#abc8", adjustContrast: false } } }),
    Grid.Item({ title: "Invalid", content: { color: "rgba(20, 25, 30, 0.5) trailing" } }),
  ] }), {});
  assert.deepEqual(grid.sections[0].items.map(({ color, darkColor }) => [color, darkColor]), [
    ["#ff007f", undefined], ["#ff008040", undefined], ["#00ff00", "#0000ff80"],
    ["#abc8", undefined], [undefined, undefined],
  ]);

  const { detail } = await render(() => Detail({ metadata: Detail.Metadata({ children: Detail.Metadata.Label({
    title: "Colour", text: { value: "Blue", color: { light: "hsla(240,100%,50%,0.5)", adjustContrast: false } },
    icon: { source: Icon.Circle, tintColor: { light: "rgba(255,0,0,0.5)", adjustContrast: false } },
  }) }) }), {});
  assert.equal(detail.metadata[0].color, "#0000ff80");
  assert.equal(detail.metadata[0].imageDescriptor.tintColor, "#ff000080");
});

test("CSS color keywords work across appearance variants and reject non-color names", async () => {
  const { colorVariants } = require("./presentation-values.cjs");
  assert.deepEqual(colorVariants({ light: " AliceBlue ", dark: "REBECCAPURPLE", adjustContrast: false }),
    { light: "#f0f8ff", dark: "#663399" });
  assert.deepEqual(colorVariants({ light: "grey", dark: "gray", adjustContrast: false }), { light: "#808080", dark: "#808080" });
  for (const invalid of ["constructor", "__proto__", "currentColor", "var(--color)", "red blue", "CanvasText"]) {
    assert.equal(colorVariants(invalid).light, undefined);
  }

  const { grid } = await render(() => Grid({ children: [
    Grid.Item({ title: "Invisible swatch", content: { color: "transparent" } }),
    Grid.Item({ title: "Icon", content: { source: Icon.Circle, tintColor: { light: "yellowgreen", adjustContrast: false } } }),
  ] }), {});
  assert.equal(grid.sections[0].items[0].color, "#00000000");
  assert.equal(grid.sections[0].items[1].tintColor, "#9acd32");
});

test("default contrast adapts raw and dynamic colors while opt-out preserves the supplied values", () => {
  const { colorVariants } = require("./presentation-values.cjs");
  const lightOnLight = colorVariants("#ffffff");
  assert.notEqual(lightOnLight.light, "#ffffff");
  assert.equal(lightOnLight.dark, "#ffffff");
  const darkOnDark = colorVariants("#000000");
  assert.equal(darkOnDark.light, "#000000");
  assert.notEqual(darkOnDark.dark, "#000000");
  const grayLuminance = (hex) => ((parseInt(hex.slice(1, 3), 16) / 255 + 0.055) / 1.055) ** 2.4;
  assert.ok(1.05 / (grayLuminance(lightOnLight.light) + 0.05) >= 4.5);
  assert.ok((grayLuminance(darkOnDark.dark) + 0.05) / (grayLuminance("#202020") + 0.05) >= 4.5);
  assert.deepEqual(colorVariants({ light: "#ffffff", dark: "#000000" }),
    { light: lightOnLight.light, dark: darkOnDark.dark });
  assert.deepEqual(colorVariants({ light: "#ffffff", dark: "#000000", adjustContrast: false }),
    { light: "#ffffff", dark: "#000000" });
  assert.deepEqual(colorVariants(Color.Red), { light: Color.Red, dark: undefined });
  assert.deepEqual(colorVariants("transparent"), { light: "#00000000", dark: undefined });
});
