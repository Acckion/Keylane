const Icon = require("./icon-values.cjs");

// Runtime values from the public @raycast/api 2.11.1 declarations and Keyboard reference.
const Color = Object.freeze({
  Blue: "raycast-blue",
  // The legacy dynamic color was verified through the public API in Raycast 2.12.1.0.
  Brown: Object.freeze({ light: "#714426", dark: "#9F6138" }),
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

// Named sRGB values from https://www.w3.org/TR/css-color-4/#named-colors.
const namedColors = new Map([
  ["aliceblue", "#f0f8ff"],
  ["antiquewhite", "#faebd7"],
  ["aqua", "#00ffff"],
  ["aquamarine", "#7fffd4"],
  ["azure", "#f0ffff"],
  ["beige", "#f5f5dc"],
  ["bisque", "#ffe4c4"],
  ["black", "#000000"],
  ["blanchedalmond", "#ffebcd"],
  ["blue", "#0000ff"],
  ["blueviolet", "#8a2be2"],
  ["brown", "#a52a2a"],
  ["burlywood", "#deb887"],
  ["cadetblue", "#5f9ea0"],
  ["chartreuse", "#7fff00"],
  ["chocolate", "#d2691e"],
  ["coral", "#ff7f50"],
  ["cornflowerblue", "#6495ed"],
  ["cornsilk", "#fff8dc"],
  ["crimson", "#dc143c"],
  ["cyan", "#00ffff"],
  ["darkblue", "#00008b"],
  ["darkcyan", "#008b8b"],
  ["darkgoldenrod", "#b8860b"],
  ["darkgray", "#a9a9a9"],
  ["darkgreen", "#006400"],
  ["darkgrey", "#a9a9a9"],
  ["darkkhaki", "#bdb76b"],
  ["darkmagenta", "#8b008b"],
  ["darkolivegreen", "#556b2f"],
  ["darkorange", "#ff8c00"],
  ["darkorchid", "#9932cc"],
  ["darkred", "#8b0000"],
  ["darksalmon", "#e9967a"],
  ["darkseagreen", "#8fbc8f"],
  ["darkslateblue", "#483d8b"],
  ["darkslategray", "#2f4f4f"],
  ["darkslategrey", "#2f4f4f"],
  ["darkturquoise", "#00ced1"],
  ["darkviolet", "#9400d3"],
  ["deeppink", "#ff1493"],
  ["deepskyblue", "#00bfff"],
  ["dimgray", "#696969"],
  ["dimgrey", "#696969"],
  ["dodgerblue", "#1e90ff"],
  ["firebrick", "#b22222"],
  ["floralwhite", "#fffaf0"],
  ["forestgreen", "#228b22"],
  ["fuchsia", "#ff00ff"],
  ["gainsboro", "#dcdcdc"],
  ["ghostwhite", "#f8f8ff"],
  ["gold", "#ffd700"],
  ["goldenrod", "#daa520"],
  ["gray", "#808080"],
  ["green", "#008000"],
  ["greenyellow", "#adff2f"],
  ["grey", "#808080"],
  ["honeydew", "#f0fff0"],
  ["hotpink", "#ff69b4"],
  ["indianred", "#cd5c5c"],
  ["indigo", "#4b0082"],
  ["ivory", "#fffff0"],
  ["khaki", "#f0e68c"],
  ["lavender", "#e6e6fa"],
  ["lavenderblush", "#fff0f5"],
  ["lawngreen", "#7cfc00"],
  ["lemonchiffon", "#fffacd"],
  ["lightblue", "#add8e6"],
  ["lightcoral", "#f08080"],
  ["lightcyan", "#e0ffff"],
  ["lightgoldenrodyellow", "#fafad2"],
  ["lightgray", "#d3d3d3"],
  ["lightgreen", "#90ee90"],
  ["lightgrey", "#d3d3d3"],
  ["lightpink", "#ffb6c1"],
  ["lightsalmon", "#ffa07a"],
  ["lightseagreen", "#20b2aa"],
  ["lightskyblue", "#87cefa"],
  ["lightslategray", "#778899"],
  ["lightslategrey", "#778899"],
  ["lightsteelblue", "#b0c4de"],
  ["lightyellow", "#ffffe0"],
  ["lime", "#00ff00"],
  ["limegreen", "#32cd32"],
  ["linen", "#faf0e6"],
  ["magenta", "#ff00ff"],
  ["maroon", "#800000"],
  ["mediumaquamarine", "#66cdaa"],
  ["mediumblue", "#0000cd"],
  ["mediumorchid", "#ba55d3"],
  ["mediumpurple", "#9370db"],
  ["mediumseagreen", "#3cb371"],
  ["mediumslateblue", "#7b68ee"],
  ["mediumspringgreen", "#00fa9a"],
  ["mediumturquoise", "#48d1cc"],
  ["mediumvioletred", "#c71585"],
  ["midnightblue", "#191970"],
  ["mintcream", "#f5fffa"],
  ["mistyrose", "#ffe4e1"],
  ["moccasin", "#ffe4b5"],
  ["navajowhite", "#ffdead"],
  ["navy", "#000080"],
  ["oldlace", "#fdf5e6"],
  ["olive", "#808000"],
  ["olivedrab", "#6b8e23"],
  ["orange", "#ffa500"],
  ["orangered", "#ff4500"],
  ["orchid", "#da70d6"],
  ["palegoldenrod", "#eee8aa"],
  ["palegreen", "#98fb98"],
  ["paleturquoise", "#afeeee"],
  ["palevioletred", "#db7093"],
  ["papayawhip", "#ffefd5"],
  ["peachpuff", "#ffdab9"],
  ["peru", "#cd853f"],
  ["pink", "#ffc0cb"],
  ["plum", "#dda0dd"],
  ["powderblue", "#b0e0e6"],
  ["purple", "#800080"],
  ["rebeccapurple", "#663399"],
  ["red", "#ff0000"],
  ["rosybrown", "#bc8f8f"],
  ["royalblue", "#4169e1"],
  ["saddlebrown", "#8b4513"],
  ["salmon", "#fa8072"],
  ["sandybrown", "#f4a460"],
  ["seagreen", "#2e8b57"],
  ["seashell", "#fff5ee"],
  ["sienna", "#a0522d"],
  ["silver", "#c0c0c0"],
  ["skyblue", "#87ceeb"],
  ["slateblue", "#6a5acd"],
  ["slategray", "#708090"],
  ["slategrey", "#708090"],
  ["snow", "#fffafa"],
  ["springgreen", "#00ff7f"],
  ["steelblue", "#4682b4"],
  ["tan", "#d2b48c"],
  ["teal", "#008080"],
  ["thistle", "#d8bfd8"],
  ["tomato", "#ff6347"],
  ["transparent", "#00000000"],
  ["turquoise", "#40e0d0"],
  ["violet", "#ee82ee"],
  ["wheat", "#f5deb3"],
  ["white", "#ffffff"],
  ["whitesmoke", "#f5f5f5"],
  ["yellow", "#ffff00"],
  ["yellowgreen", "#9acd32"],
]);

function supportedColor(value) {
  if (typeof value !== "string" || value.length > 128) return undefined;
  value = value.trim();
  if (standardColors.has(value) || /^#(?:[\da-f]{3,4}|[\da-f]{6}|[\da-f]{8})$/i.test(value)) return value;

  const named = namedColors.get(value.toLowerCase());
  if (named !== undefined) return named;

  const call = /^(rgb|rgba|hsl|hsla)\(([^()]*)\)$/i.exec(value);
  if (!call) return undefined;
  const name = call[1].toLowerCase();
  const parts = call[2].split(",").map((part) => part.trim());
  if (parts.length !== (name.endsWith("a") ? 4 : 3) ||
      parts.some((part) => !/^[+-]?(?:\d+(?:\.\d+)?|\.\d+)%?$/.test(part))) return undefined;
  const numbers = parts.map(parseFloat);
  if (numbers.some((number) => !Number.isFinite(number))) return undefined;
  const clamp = (number) => Math.max(0, Math.min(1, number));
  const fraction = (index, scale) => clamp(numbers[index] / (parts[index].endsWith("%") ? 100 : scale));
  let channels;
  if (name.startsWith("rgb")) {
    channels = [0, 1, 2].map((index) => fraction(index, 255));
  } else {
    if (parts[0].endsWith("%") || !parts[1].endsWith("%") || !parts[2].endsWith("%")) return undefined;
    const hue = ((numbers[0] % 360) + 360) % 360 / 30;
    const saturation = fraction(1, 100);
    const lightness = fraction(2, 100);
    const amplitude = saturation * Math.min(lightness, 1 - lightness);
    channels = [0, 8, 4].map((channel) => {
      const offset = (channel + hue) % 12;
      return lightness - amplitude * Math.max(-1, Math.min(offset - 3, 9 - offset, 1));
    });
  }
  if (parts.length === 4) channels.push(fraction(3, 1));
  return "#" + channels.map((number) => Math.round(number * 255).toString(16).padStart(2, "0")).join("");
}

function luminance(channels) {
  const linear = channels.map((channel) => {
    const value = channel / 255;
    return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrastColor(color, background) {
  if (!color?.startsWith("#")) return color;
  let hex = color.slice(1);
  if (hex.length < 5) hex = [...hex].map((digit) => digit.repeat(2)).join("");
  const [red, green, blue, alpha = 255] = hex.match(/../g).map((pair) => parseInt(pair, 16));
  if (!alpha) return color;

  const surface = [background, background, background];
  const backgroundLuminance = luminance(surface);
  const original = [red, green, blue];
  const contrast = (channels) => {
    const composited = channels.map((channel) => (channel * alpha + background * (255 - alpha)) / 255);
    const foreground = luminance(composited);
    return (Math.max(foreground, backgroundLuminance) + 0.05) /
      (Math.min(foreground, backgroundLuminance) + 0.05);
  };
  if (contrast(original) >= 4.5) return color;
  const endpoint = background > 127 ? 0 : 255;
  // Keep the original alpha even if its opacity makes the target contrast unreachable.
  if (contrast([endpoint, endpoint, endpoint]) < 4.5) return color;
  const mixed = (amount) => original.map((channel) => Math.round(channel + (endpoint - channel) * amount));
  let low = 0;
  let high = 1;
  for (let step = 0; step < 12; step++) {
    const middle = (low + high) / 2;
    if (contrast(mixed(middle)) >= 4.5) high = middle;
    else low = middle;
  }
  const adjusted = mixed(high).map((channel) => channel.toString(16).padStart(2, "0")).join("");
  return `#${adjusted}${hex.slice(6)}`;
}

function colorVariants(value) {
  const raw = supportedColor(value);
  const light = raw ?? supportedColor(value?.light);
  const dark = supportedColor(value?.dark);
  if (value?.adjustContrast === false) return { light, dark };
  const adjustedLight = contrastColor(light, 255);
  const adjustedDark = contrastColor(dark ?? light, 32);
  return { light: adjustedLight, dark: dark !== undefined || adjustedDark !== adjustedLight ? adjustedDark : undefined };
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

const modifiers = new Set(["cmd", "ctrl", "opt", "shift"]);
const specialKeys = new Set([
  "return", "enter", "delete", "backspace", "deleteForward", "tab", "arrowUp", "arrowDown", "arrowLeft", "arrowRight",
  "pageUp", "pageDown", "home", "end", "space", "escape",
]);

function macOSShortcut(shortcut) {
  const chord = shortcut?.macOS ?? shortcut;
  const key = chord?.key;
  const flags = chord?.modifiers;
  if (typeof key !== "string" || (!/^[a-z0-9.,;=+\[\]{}«»()/\\'`§^@$-]$/u.test(key) && !specialKeys.has(key)) ||
      !Array.isArray(flags) || flags.length > 4 || new Set(flags).size !== flags.length ||
      !flags.every((flag) => modifiers.has(flag))) return undefined;
  return { key, modifiers: [...flags] };
}

module.exports = { Color, Icon, Image, ImageMask, Keyboard, builtInIcons, colorVariants, iconTint, macOSShortcut };
