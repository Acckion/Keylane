const { createHash } = require("node:crypto");
const assert = require("node:assert/strict");
const test = require("node:test");
const { describeImage, limitImagePayloads } = require("./image-api.cjs");
const { Action, ActionPanel, Form, Icon, List, render } = require("./view-api.cjs");
const raster = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jK5cAAAAASUVORK5CYII=";

test("theme variants preserve masked inline images and fallback symbols", () => {
  const icon = describeImage({
    source: { light: raster, dark: "https://example.invalid/dark.png" },
    fallback: { light: Icon.Folder, dark: "⭐" },
    mask: "circle", tintColor: { light: "#abc", dark: "#123", adjustContrast: false },
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

test("bundled images look up the dark sibling without changing the light source", (t) => {
  const fs = require("node:fs");
  const path = require("node:path");
  const bytes = Buffer.from(raster.split(",")[1], "base64");
  const light = Buffer.from("light fixture");
  const large = Buffer.alloc(262144, 0x42);
  const files = new Map([
    ["/assets/nested/icon.png", light],
    ["/assets/nested/icon@dark.png", bytes],
    ["/assets/explicit.png", light],
    ["/assets/large.png", large],
    ["/assets/large@dark.png", bytes],
    ["/assets/oversize.png", Buffer.alloc(262145)],
  ]);
  t.mock.method(fs, "realpathSync", (name) => {
    if (name === "/assets/escape@dark.png") return "/tmp/private.png";
    if (files.has(name)) return name;
    throw new Error("Missing fixture");
  });
  t.mock.method(fs, "openSync", (name) => name);
  t.mock.method(fs, "fstatSync", (name) => ({ isFile: () => true, size: files.get(name).length }));
  t.mock.method(fs, "readSync", (name, target) => files.get(name).copy(target));
  t.mock.method(fs, "closeSync", () => {});

  const lightRaster = `data:image/png;base64,${light.toString("base64")}`;
  const image = describeImage(path.join("nested", "icon.png"));
  assert.deepEqual(image.light, { raster: lightRaster });
  assert.deepEqual(image.dark, { raster });
  const fallback = describeImage({ source: "absent.png", fallback: "nested/icon.png" });
  assert.deepEqual(fallback.fallbackLight, { raster: lightRaster });
  assert.deepEqual(fallback.fallbackDark, { raster });
  const explicit = describeImage({ source: { light: "nested/icon.png", dark: "explicit.png" } });
  assert.deepEqual(explicit.dark, { raster: lightRaster });
  assert.equal(describeImage("escape.png"), undefined);
  const largeImage = describeImage("/assets/large.png");
  assert.deepEqual(largeImage.light, {
    assetDigest: createHash("sha256").update(large).digest("hex"), assetFormat: "png",
  });
  assert.deepEqual(largeImage.dark, { raster });
  assert.equal(describeImage("oversize.png"), undefined);
});

test("FileIcon sends a type hint without exposing its path to macOS", async () => {
  assert.deepEqual(describeImage({ fileIcon: "/private/tmp/私人文件.PDF" }).light, { fileExtension: "pdf" });
  assert.deepEqual(describeImage({ fileIcon: "/private/tmp/folder/" }).light, { fileType: "folder" });
  assert.deepEqual(describeImage({ fileIcon: "README" }).light, { fileType: "item" });
  for (const fileIcon of ["../escape.pdf", "//remote/file.pdf", "https://example.invalid/file.pdf", "bad\0.pdf"]) {
    assert.equal(describeImage({ fileIcon }), undefined);
  }

  const reply = await render(() => List({ children: List.Item({
    title: "Example",
    icon: { fileIcon: "/private/tmp/hidden.pdf" },
    accessories: [{ icon: { fileIcon: "/private/tmp/hidden.png" } }],
  }) }), {});
  const [row] = reply.rows;
  assert.deepEqual(row.imageDescriptor.light, { fileExtension: "pdf" });
  assert.deepEqual(row.accessories[0].imageDescriptor.light, { fileExtension: "png" });
  assert.doesNotMatch(JSON.stringify(reply), /private|hidden/);
});

test("remote HTTPS image references retain appearance and local fallback for host admission", () => {
  const light = "https://example.com/light.png";
  const dark = "https://example.com/dark.png";
  const descriptor = describeImage({ source: { light, dark }, fallback: "circle-16", mask: "circle" }, true, true);
  assert.deepEqual(descriptor.light, { remoteURL: light });
  assert.deepEqual(descriptor.dark, { remoteURL: dark });
  assert.deepEqual(descriptor.fallbackLight, { symbol: "circle-16" });
  assert.equal(descriptor.mask, "circle");
  for (const invalid of ["http://example.com/image.png", "https://user@example.com/image.png",
    "https://example.com/image.png#fragment", "https://example.com/a b.png"]) {
    assert.equal(describeImage(invalid, true, true), undefined);
  }
  assert.equal(describeImage({ source: "circle-16", fallback: dark }, true, true).fallbackLight, undefined);
});
