const { URL } = require("node:url");
const { absoluteFilePath } = require("./finder-reveal.cjs");
const { Finder, Globe } = require("./icon-values.cjs");

const unsafeURLCharacters = /[\\\s\p{Cc}\p{Cf}]/u;
const unsafeURLBytes = /%(?:0[\da-f]|1[\da-f]|7f)|%c2%[89][\da-f]/i;
const invalidPercentEscape = /%(?![\da-f]{2})/i;

function webURL(target) {
  if (typeof target !== "string" || Buffer.byteLength(target) > 2048 ||
      unsafeURLCharacters.test(target) || unsafeURLBytes.test(target) || invalidPercentEscape.test(target)) {
    throw new Error("Invalid web URL");
  }

  const authority = /^https?:\/\/([^/?#]+)/i.exec(target)?.[1];
  if (!authority || authority.includes("@")) throw new Error("Expected an HTTP(S) URL without credentials");

  let url;
  try {
    url = new URL(target);
  } catch {
    throw new Error("Invalid web URL");
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:") || !url.hostname || url.username || url.password ||
      Buffer.byteLength(url.href) > 2048) {
    throw new Error("Invalid web URL");
  }
  return url.href;
}

function openActionComponents(component) {
  const open = component("open");
  const openInBrowser = component("openInBrowser");
  return {
    Open: (props) => open({ ...props, title: props?.title ?? "Open", icon: props?.icon ?? Finder }),
    OpenInBrowser: (props) => openInBrowser({ ...props, title: props?.title ?? "Open in Browser", icon: props?.icon ?? Globe }),
  };
}

function applicationSelector(value) {
  if (value === undefined) return undefined;
  const checked = (text, limit) => {
    if (typeof text !== "string" || !text.trim() || Buffer.byteLength(text) > limit || /[\p{Cc}\p{Cf}]/u.test(text)) {
      throw new TypeError("Invalid application selector");
    }
    return text;
  };
  if (typeof value === "string") {
    return value.startsWith("/") ? { path: absoluteFilePath(value) } : { name: checked(value, 256) };
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new TypeError("Invalid application selector");
  const path = value.path === undefined ? undefined : absoluteFilePath(value.path);
  const bundleId = value.bundleId === undefined ? undefined : checked(value.bundleId, 256);
  const name = value.name === undefined ? undefined : checked(value.name, 256);
  if (!path && !bundleId && !name) throw new TypeError("Invalid application selector");
  return { path, bundleId, name };
}

function openEffect(target, application) {
  if (typeof target !== "string") throw new TypeError("Invalid open target");
  const app = applicationSelector(application);
  if (target.startsWith("~/")) {
    return { kind: "openFile", paths: ["~" + absoluteFilePath(target.slice(1))], ...(app && { application: app }) };
  }
  if (target.startsWith("/") || /^file:/i.test(target)) {
    if (!target.startsWith("/") && (!/^file:\/\/\/(?!\/)/i.test(target) ||
        /[\\\p{Cc}\p{Cf}]/u.test(target) ||
        target.split("/").some((part) => /^(?:\.|%2e){1,2}$/i.test(part)))) {
      throw new TypeError("Invalid local file URL");
    }
    const path = absoluteFilePath(target.startsWith("/") ? target : new URL(target));
    return { kind: "openFile", paths: [path], ...(app && { application: app }) };
  }
  return { kind: "openURL", text: webURL(target), ...(app && { application: app }) };
}

function openActionEffect(node) {
  if (node?.type === "open") return openEffect(node.props.target, node.props.application);
  if (node?.type === "openInBrowser") return { kind: "openURL", text: webURL(node.props.url) };
  throw new Error("Expected an open action");
}

function makeOpen(emit) {
  return async function open(target, application) {
    await emit(openEffect(target, application));
  };
}

module.exports = { makeOpen, openActionComponents, openActionEffect, webURL };
