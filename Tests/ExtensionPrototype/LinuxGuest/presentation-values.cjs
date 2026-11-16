const Icon = require("./icon-values.cjs");

// Runtime values from the public @raycast/api 2.11.1 declarations and Keyboard reference.
const Color = Object.freeze({
  Blue: "raycast-blue",
  // The public SDK declares a dynamic brown without publishing its RGB values.
  Brown: Object.freeze({ light: "#a2845e", dark: "#ac8e68" }),
  Green: "raycast-green",
  Magenta: "raycast-magenta",
  Orange: "raycast-orange",
  Purple: "raycast-purple",
  Red: "raycast-red",
  Yellow: "raycast-yellow",
  PrimaryText: "raycast-primary-text",
  SecondaryText: "raycast-secondary-text",
});

// Older reviewed payloads can still contain the original symbolic names.
const builtInIcons = new Set([
  ...Object.values(Icon), "Clipboard", "Clock", "Document", "Folder", "Key", "Link", "Pencil", "Tag", "Trash", "Warning",
]);
const standardColors = new Set(Object.values(Color).filter((value) => typeof value === "string"));

function supportedColor(value) {
  return typeof value === "string" && (standardColors.has(value) || /^#(?:[\da-f]{3}|[\da-f]{6})$/i.test(value))
    ? value : undefined;
}

function colorVariants(value) {
  const light = supportedColor(value) ?? supportedColor(value?.light);
  const dark = supportedColor(value?.dark);
  return { light, dark };
}

function iconTint(source, value) {
  if (!builtInIcons.has(source)) return {};
  const { light, dark } = colorVariants(value);
  return light !== undefined || dark !== undefined ? { tintColor: light, darkTintColor: dark } : {};
}

const ImageMask = Object.freeze({
  Circle: "circle",
  RoundedRectangle: "roundedRectangle",
});
const Image = Object.freeze({ Mask: ImageMask });

function chord(key, ...modifiers) {
  return Object.freeze({ key, modifiers: Object.freeze(modifiers) });
}

function shortcut(macOS, Windows) {
  return Object.freeze({ macOS, Windows });
}

const copy = shortcut(chord("c", "cmd", "shift"), chord("c", "ctrl", "shift"));
const common = Object.freeze({
  Copy: copy,
  CopyDeeplink: copy,
  CopyName: shortcut(chord("c", "cmd", "opt"), chord("c", "ctrl", "alt")),
  CopyPath: shortcut(chord("c", "cmd", "ctrl"), chord("c", "alt", "shift")),
  Save: shortcut(chord("s", "cmd"), chord("s", "ctrl")),
  Duplicate: shortcut(chord("d", "cmd"), chord("s", "ctrl", "shift")),
  Edit: shortcut(chord("e", "cmd"), chord("e", "ctrl")),
  MoveDown: shortcut(chord("arrowDown", "cmd", "opt"), chord("arrowDown", "ctrl", "alt")),
  MoveUp: shortcut(chord("arrowUp", "cmd", "opt"), chord("arrowUp", "ctrl", "alt")),
  New: shortcut(chord("n", "cmd"), chord("n", "ctrl")),
  Open: shortcut(chord("o", "cmd"), chord("o", "ctrl")),
  OpenWith: shortcut(chord("o", "cmd", "shift"), chord("o", "ctrl", "shift")),
  Pin: shortcut(chord(".", "cmd"), chord(".", "ctrl")),
  Refresh: shortcut(chord("r", "cmd"), chord("r", "ctrl")),
  Remove: shortcut(chord("x", "ctrl"), chord("d", "ctrl")),
  RemoveAll: shortcut(chord("x", "ctrl", "shift"), chord("d", "ctrl", "alt")),
  ToggleQuickLook: shortcut(chord("y", "cmd"), chord("y", "ctrl")),
});
const Keyboard = Object.freeze({ Shortcut: Object.freeze({ Common: common }) });

module.exports = { Color, Icon, Image, ImageMask, Keyboard, builtInIcons, colorVariants, iconTint };
