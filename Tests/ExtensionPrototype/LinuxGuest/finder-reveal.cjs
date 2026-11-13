const { URL, fileURLToPath } = require("node:url");
const { Finder } = require("./icon-values.cjs");

const maximumFilePathBytes = 2048;
const unsafePathCharacters = /[\p{Cc}\p{Cs}]/u;
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

function absoluteFilePath(value) {
  let path = value;
  if (value instanceof URL) {
    if (value.protocol !== "file:" || value.hostname || value.search || value.hash) {
      throw new TypeError("Expected a local file URL");
    }
    path = fileURLToPath(value);
  } else if (Buffer.isBuffer(value)) {
    path = utf8.decode(value);
  }

  if (typeof path !== "string" || !path.startsWith("/") || path.startsWith("//") ||
      Buffer.byteLength(path) > maximumFilePathBytes || unsafePathCharacters.test(path) ||
      path.split("/").some((part) => part === "." || part === "..")) {
    throw new TypeError("Expected a bounded absolute file path");
  }
  return path;
}

function finderRevealComponent(component) {
  const reveal = component("showInFinder");
  return (props) => reveal({ ...props, title: props?.title ?? "Show in Finder", icon: props?.icon ?? Finder });
}

function finderRevealEffect(path) {
  return { kind: "showInFinder", paths: [absoluteFilePath(path)] };
}

function makeShowInFinder(emit) {
  return async function showInFinder(path) {
    emit(finderRevealEffect(path));
  };
}

module.exports = { absoluteFilePath, finderRevealComponent, finderRevealEffect, makeShowInFinder };
