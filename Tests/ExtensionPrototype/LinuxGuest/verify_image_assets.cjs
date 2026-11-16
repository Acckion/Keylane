const assert = require("node:assert/strict");
const test = require("node:test");
const { describeImage, limitImagePayloads } = require("./image-api.cjs");
const { Action, ActionPanel, Form, Icon, List, render } = require("./view-api.cjs");
const raster = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jK5cAAAAASUVORK5CYII=";

test("theme variants preserve masked inline images and fallback symbols", () => {
  const icon = describeImage({
    source: { light: raster, dark: "https://example.invalid/dark.png" },
    fallback: { light: Icon.Folder, dark: "⭐" },
    mask: "circle", tintColor: { light: "#abc", dark: "#123" },
  });
  assert.deepEqual(icon.light, { raster });
  assert.equal(icon.dark, undefined);
  assert.deepEqual(icon.fallbackLight, { symbol: Icon.Folder });
  assert.deepEqual(icon.fallbackDark, { emoji: "⭐" });
  assert.equal(icon.themed, true);
  assert.equal(icon.mask, "circle");
  assert.equal(icon.darkTintColor, "#123");
  for (const source of ["../fixture.png", "/tmp/fixture.png", "file:///assets/icon.png", "https://example.invalid/icon.png"]) {
    assert.equal(describeImage(source), undefined);
  }
});

test("image descriptors survive list, dropdown, action and form option serialization", async () => {
  const image = { source: raster, mask: "roundedRectangle", fallback: Icon.Folder };
  const result = await render(() => List({
    searchBarAccessory: List.Dropdown({ children: List.Dropdown.Item({ value: "choice", title: "Choice", icon: image }) }),
    children: List.Item({
      title: "Result", icon: image,
      actions: ActionPanel({ children: Action.CopyToClipboard({ content: "fixture", icon: image }) }),
    }),
  }), {});
  const row = result.rows[0];
  for (const icon of [row.imageDescriptor, row.actions[0].imageDescriptor, result.dropdown.sections[0].items[0].imageDescriptor]) {
    assert.deepEqual(icon.light, { raster });
    assert.deepEqual(icon.fallbackLight, { symbol: Icon.Folder });
  }
  const form = await render(() => Form({
    children: Form.Dropdown({
      id: "choice", children: Form.Dropdown.Item({ value: "value", title: "Value", icon: Icon.Folder }),
    }),
  }), {});
  assert.deepEqual(form.form.fields[0].options[0].imageDescriptor.light, { symbol: Icon.Folder });
});

test("raster overflow retains the fallback descriptor without growing the snapshot", () => {
  const full = "data:image/png;base64," + "A".repeat(2400);
  const rows = Array.from({ length: 5 }, () => ({
    imageDescriptor: describeImage({ source: full, fallback: Icon.Folder }),
  }));
  limitImagePayloads(rows);
  assert.equal(rows.filter(({ imageDescriptor }) => imageDescriptor.light?.raster).length, 1);
  assert(rows.every(({ imageDescriptor }) => imageDescriptor.fallbackLight.symbol === Icon.Folder));
});
