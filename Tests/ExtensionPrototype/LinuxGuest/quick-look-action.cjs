const { absoluteFilePath } = require("./finder-reveal.cjs");
const { Eye } = require("./icon-values.cjs");

function quickLookComponent(component) {
  const toggle = component("toggleQuickLook");
  return (props) => toggle({ ...props, title: props?.title ?? "Quick Look", icon: props?.icon ?? Eye });
}

function quickLookEffect(quickLook) {
  if (quickLook == null) throw new Error("Quick Look requires a selected item with a preview path");
  const { path, name } = quickLook;
  const target = typeof path === "string" && path.startsWith("~/")
    ? "~" + absoluteFilePath(path.slice(1)) : absoluteFilePath(path);
  if (name != null && (typeof name !== "string" || Buffer.byteLength(name) > 512 || /\p{Cc}/u.test(name))) {
    throw new TypeError("Invalid Quick Look name");
  }
  return { kind: "toggleQuickLook", paths: [target], ...(name && { previewTitle: name }) };
}

module.exports = { quickLookComponent, quickLookEffect };
