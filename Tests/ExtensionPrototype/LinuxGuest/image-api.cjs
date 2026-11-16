const fs = require("node:fs");
const path = require("node:path");
const { builtInIcons, colorVariants } = require("./presentation-values.cjs");

const root = "/assets";
const formats = new Map([[".png", "png"], [".jpeg", "jpeg"], [".jpg", "jpeg"]]);

function asset(source) {
  const name = source.startsWith(root + "/") ? source.slice(root.length + 1) : source;
  const format = formats.get(path.extname(name).toLowerCase());
  if (!format || /[\\:\p{Cc}\p{Cf}]/u.test(name) ||
      name.split("/").some((part) => !part || part === "." || part === "..")) return;
  try {
    const resolved = fs.realpathSync(path.join(root, name));
    if (!resolved.startsWith(root + "/")) return;
    const fd = fs.openSync(resolved, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    try {
      const info = fs.fstatSync(fd);
      if (!info.isFile() || info.size < 1 || info.size > 1800) return;
      const data = Buffer.alloc(info.size);
      if (fs.readSync(fd, data, 0, data.length, 0) !== data.length) return;
      return `data:image/${format};base64,${data.toString("base64")}`;
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return undefined;
  }
}

function variant(value) {
  if (typeof value !== "string" || Buffer.byteLength(value) > 2448) return;
  if (builtInIcons.has(value)) return { symbol: value };
  if (/^data:image\/(?:png|jpeg);base64,[A-Za-z0-9+/]+={0,2}$/.test(value)) return { raster: value };
  if (Buffer.byteLength(value) <= 64 && /^(?:[0-9#*]\ufe0f?\u20e3|[\p{Extended_Pictographic}\p{Regional_Indicator}][\p{Extended_Pictographic}\p{Regional_Indicator}\p{Emoji_Modifier}\ufe0f\u200d]*)$/u.test(value)) return { emoji: value };
  const raster = asset(value);
  if (raster) return { raster };
}

function describeImage(value, includePlainSymbol = false) {
  if (value == null) return;
  const source = value?.source ?? value;
  const themed = source !== null && typeof source === "object";
  const mask = ["circle", "roundedRectangle"].includes(value?.mask) ? value.mask : undefined;
  const tint = colorVariants(value?.tintColor);
  if (!includePlainSymbol && builtInIcons.has(source) && !mask && !tint.light && !tint.dark && !value?.fallback) return;
  const light = variant(themed ? source.light : source);
  const dark = themed ? variant(source.dark) : undefined;
  const fallback = value?.fallback;
  const fallbackLight = variant(fallback?.light ?? fallback);
  const fallbackDark = variant(fallback?.dark) ?? fallbackLight;
  if (!light && !dark && !fallbackLight && !fallbackDark) return;
  return { light, dark, fallbackLight, fallbackDark, ...(themed && { themed }), mask, tintColor: tint.light, darkTintColor: tint.dark };
}

function limitImagePayloads(result) {
  let remaining = 4800;
  function visit(node) {
    if (!node || typeof node !== "object") return;
    for (const [key, child] of Object.entries(node)) {
      if (key === "imageDescriptor" && child) {
        for (const name of ["light", "dark", "fallbackLight", "fallbackDark"]) {
          const bytes = Buffer.byteLength(child[name]?.raster ?? "");
          if (bytes <= remaining) remaining -= bytes;
          else delete child[name];
        }
      } else {
        visit(child);
      }
    }
  }
  visit(result);
  return result;
}

module.exports = { describeImage, limitImagePayloads };
