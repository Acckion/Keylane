const { absoluteFilePath } = require("./finder-reveal.cjs");
const { openActionEffect } = require("./open-api.cjs");
const { Upload } = require("./icon-values.cjs");

function openWithComponent(component) {
  const openWith = component("openWith");
  return (props) => openWith({ ...props, title: props?.title ?? "Open With", icon: props?.icon ?? Upload });
}

function openWithEffect(path) {
  if (typeof path === "string") {
    const { kind, paths, text } = openActionEffect({ type: "open", props: { target: path } });
    return kind === "openFile" ? { kind: "openWithFile", paths } : { kind: "openWithURL", text };
  }
  return { kind: "openWithFile", paths: [absoluteFilePath(path)] };
}

function makeClearClipboard(emit) {
  return async function clear() {
    emit({ kind: "clearClipboard" });
  };
}

module.exports = { openWithComponent, openWithEffect, makeClearClipboard };
