const { resolve } = require("node:path");
const { URL, fileURLToPath } = require("node:url");
const { Finder } = require("./icon-values.cjs");

const maximumFilePathBytes = 2048;
const unsafePathCharacters = /[\p{Cc}\p{Cs}]/u;
const utf8 = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

function decodePathLike(value) {
  let path = value;
  if (value instanceof URL) {
    if (value.protocol !== "file:" || value.hostname || value.search || value.hash) {
      throw new TypeError("Expected a local file URL");
    }
    path = fileURLToPath(value);
  } else if (Buffer.isBuffer(value)) {
    path = utf8.decode(value);
  }

  if (typeof path !== "string" || !path || path.startsWith("//") || /^[a-z][a-z0-9+.-]*:\/\//i.test(path) ||
      Buffer.byteLength(path) > maximumFilePathBytes || unsafePathCharacters.test(path)) {
    throw new TypeError("Expected a bounded file path");
  }
  return path;
}

function absoluteFilePath(value) {
  const path = decodePathLike(value);
  if (!path.startsWith("/") || path.split("/").some((part) => part === "." || part === "..")) {
    throw new TypeError("Expected a bounded absolute file path");
  }
  return path;
}

function finderRevealComponent(component) {
  const reveal = component("showInFinder");
  return (props) => reveal({ ...props, title: props?.title ?? "Show in Finder", icon: props?.icon ?? Finder });
}

function resolvedFilePath(path) {
  return absoluteFilePath(resolve(decodePathLike(path)));
}

function finderRevealEffect(path) {
  return { kind: "showInFinder", paths: [resolvedFilePath(path)] };
}

function makeShowInFinder(emit) {
  return async function showInFinder(path) {
    await emit(finderRevealEffect(path));
  };
}

module.exports = { absoluteFilePath, resolvedFilePath, finderRevealComponent, finderRevealEffect, makeShowInFinder };
