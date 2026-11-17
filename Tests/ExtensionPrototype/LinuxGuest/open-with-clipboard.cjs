const { absoluteFilePath } = require("./finder-reveal.cjs");
const { openActionEffect, webURL } = require("./open-api.cjs");
const { Upload } = require("./icon-values.cjs");

function openWithComponent(component) {
  const openWith = component("openWith");
  return (props) => openWith({ ...props, title: props?.title ?? "Open With", icon: props?.icon ?? Upload });
}

function openWithEffect(path) {
  if (typeof path === "string") {
    const { kind, paths, text } = openActionEffect({ type: "open", props: { target: path } });
    if (kind === "openFile") {
      if (!/^(?:\/|~\/|file:)/i.test(path)) throw new TypeError("Expected an absolute file path");
      return { kind: "openWithFile", paths };
    }
    return { kind: "openWithURL", text: webURL(text) };
  }
  return { kind: "openWithFile", paths: [absoluteFilePath(path)] };
}

function makeClearClipboard(emit) {
  return async function clear() {
    emit({ kind: "clearClipboard" });
  };
}

module.exports = { openWithComponent, openWithEffect, makeClearClipboard };
