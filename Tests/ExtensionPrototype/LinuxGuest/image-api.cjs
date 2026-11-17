const { createHash } = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { describeUtilityIcon } = require("./utilities-visual-feedback.cjs");
const { builtInIcons, colorVariants } = require("./presentation-values.cjs");

const root = "/assets";
const formats = new Map([[".png", "png"], [".jpeg", "jpeg"], [".jpg", "jpeg"], [".gif", "gif"]]);

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
      if (!info.isFile() || info.size < 1 || info.size > 262144) return;
      const data = Buffer.alloc(info.size);
      if (fs.readSync(fd, data, 0, data.length, 0) !== data.length) return;
      if (data.length <= 1800) return { raster: `data:image/${format};base64,${data.toString("base64")}` };
      return { assetDigest: createHash("sha256").update(data).digest("hex"), assetFormat: format };
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return undefined;
  }
}

function darkAsset(source) {
  if (typeof source !== "string" || !formats.has(path.extname(source).toLowerCase()) ||
      source.startsWith("data:")) return;
  const extension = path.extname(source);
  const name = source.slice(0, -extension.length);
  if (name.endsWith("@dark")) return;
  return asset(`${name}@dark${extension}`);
}

function variant(value, allowRemote = false) {
  const utility = describeUtilityIcon(value);
  if (utility) return { utility };
  if (typeof value !== "string" || Buffer.byteLength(value) > 2448) return;
  if (builtInIcons.has(value)) return { symbol: value };
  if (/^data:image\/(?:png|jpeg|gif);base64,[A-Za-z0-9+/]+={0,2}$/.test(value)) return { raster: value };
  if (Buffer.byteLength(value) <= 64 && /^(?:[0-9#*]\ufe0f?\u20e3|[\p{Extended_Pictographic}\p{Regional_Indicator}][\p{Extended_Pictographic}\p{Regional_Indicator}\p{Emoji_Modifier}\ufe0f\u200d]*)$/u.test(value)) return { emoji: value };
  if (allowRemote && /^https:\/\//i.test(value) && !/[\s\\\p{Cc}\p{Cf}]/u.test(value)) {
    try {
      const url = new URL(value);
      if (url.hostname && !url.username && !url.password && !url.hash && Buffer.byteLength(url.href) <= 2048) {
        return { remoteURL: url.href };
      }
    } catch {
      return;
    }
  }
  return asset(value);
}

function fileIcon(value) {
  const source = value?.fileIcon;
  if (typeof source !== "string" || !source || Buffer.byteLength(source) > 2048 ||
      /[\\:\p{Cc}\p{Cs}]/u.test(source) || source.startsWith("//") ||
      source.split("/").some((part) => part === "." || part === "..")) return;
  if (source.endsWith("/")) return { fileType: "folder" };
  const extension = path.extname(source).slice(1).toLowerCase();
  // Send only a type hint across the boundary, never a path to a host file.
  return /^[a-z0-9][a-z0-9_+-]{0,31}$/.test(extension) ? { fileExtension: extension } : { fileType: "item" };
}

function describeImage(value, includePlainSymbol = false, allowRemote = false) {
  if (value == null) return;
  const source = value?.source ?? value;
  const file = fileIcon(source);
  const themed = !file && source !== null && typeof source === "object";
  const mask = ["circle", "roundedRectangle"].includes(value?.mask) ? value.mask : undefined;
  const tint = colorVariants(value?.tintColor);
  if (!includePlainSymbol && builtInIcons.has(source) && !mask && !tint.light && !tint.dark && !value?.fallback) return;
  const light = file ?? variant(themed ? source.light : source, allowRemote);
  const dark = themed ? variant(source.dark, allowRemote) : darkAsset(source);
  const fallback = value?.fallback;
  const fallbackLight = variant(fallback?.light ?? fallback);
  const fallbackDark = variant(fallback?.dark) ?? darkAsset(fallback) ?? fallbackLight;
  if (!light && !dark && !fallbackLight && !fallbackDark) return;
  return { light, dark, fallbackLight, fallbackDark, ...(themed && { themed }), mask, tintColor: tint.light, darkTintColor: tint.dark };
}

function limitImagePayloads(result) {
  let remaining = 4800;
  function limitDescriptor(descriptor) {
    for (const name of ["light", "dark", "fallbackLight", "fallbackDark"]) {
      const variant = descriptor[name];
      const bytes = variant?.assetDigest ? Buffer.byteLength(JSON.stringify(variant))
        : Buffer.byteLength(variant?.raster ?? variant?.remoteURL ?? "");
      if (bytes <= remaining) remaining -= bytes;
      else delete descriptor[name];
    }
  }

  function visit(node) {
    if (!node || typeof node !== "object") return;
    for (const [key, child] of Object.entries(node)) {
      if (key === "imageDescriptor" && child) {
        limitDescriptor(child);
      } else if (key === "markdownImages" && Array.isArray(child)) {
        child.forEach(limitDescriptor);
      } else {
        visit(child);
      }
    }
  }
  visit(result);
  return result;
}

module.exports = { describeImage, limitImagePayloads };
