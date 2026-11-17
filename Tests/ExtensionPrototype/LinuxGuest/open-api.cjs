const { URL, pathToFileURL } = require("node:url");
const { absoluteFilePath, resolvedFilePath } = require("./finder-reveal.cjs");
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

function metadataURL(target) {
  if (typeof target === "string" && Buffer.byteLength(target) <= 2048) {
    const mail = /^mailto:([a-z0-9_+.-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+)(?:\?([^#]+))?$/i.exec(target);
    if (mail?.[0] === target) {
      const seen = new Set();
      for (const field of mail[2]?.split("&") ?? []) {
        const match = /^(subject|body)=((?:[a-z0-9_.!~*'()-]|%[a-f0-9]{2})*)$/i.exec(field);
        if (match?.[0] !== field || seen.has(match[1].toLowerCase()) ||
            /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(decodeURIComponent(match[2]))) {
          throw new Error("Invalid mail link");
        }
        seen.add(match[1].toLowerCase());
      }
      return `mailto:${target.slice(7)}`;
    }
    const telephone = /^tel:(\+?[0-9().-]+)$/i.exec(target);
    if (telephone?.[0] === target) {
      const number = telephone[1].replace(/[().-]/g, "");
      if (/^\+?[0-9]{1,32}$/.test(number)) return `tel:${number}`;
    }
  }
  return webURL(target);
}

function openURL(target) {
  const scheme = /^[a-z][a-z0-9+.-]{0,63}(?=:)/i.exec(target)?.[0].toLowerCase();
  if (!scheme || ["http", "https", "mailto", "tel"].includes(scheme)) return metadataURL(target);
  if (["file", "javascript", "vbscript", "data", "blob", "about", "view-source"].includes(scheme) ||
      target.length === scheme.length + 1 || Buffer.byteLength(target) > 2048 ||
      unsafeURLCharacters.test(target) || unsafeURLBytes.test(target) || invalidPercentEscape.test(target)) {
    throw new TypeError("Unsupported open URL");
  }
  const authority = /^.+?:\/\/([^/?#]*)/.exec(target)?.[1];
  if (authority?.includes("@")) throw new TypeError("Invalid custom URL authority");
  const url = new URL(target);
  if (url.username || url.password || Buffer.byteLength(url.href) > 2048) throw new TypeError("Invalid custom URL");
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
  if (!/^[a-z][a-z0-9+.-]*:/i.test(target)) {
    return { kind: "openFile", paths: [resolvedFilePath(target)], ...(app && { application: app }) };
  }
  return { kind: "openURL", text: openURL(target), ...(app && { application: app }) };
}

function metadataLinkURL(target) {
  if (typeof target !== "string" || !/^[a-z][a-z0-9+.-]*:/i.test(target)) {
    throw new TypeError("Expected an absolute metadata link URL");
  }
  if (!/^file:/i.test(target)) return openURL(target);
  if (Buffer.byteLength(target) > 2048 || unsafeURLCharacters.test(target) || invalidPercentEscape.test(target)) {
    throw new TypeError("Invalid local file link");
  }
  const url = new URL(target);
  if (url.search || url.hash || target.includes("?") || target.includes("#")) throw new TypeError("Invalid local file link");
  const [path] = openEffect(target).paths;
  if (/[\\\p{Cf}]/u.test(path)) throw new TypeError("Invalid local file link");
  const normalized = pathToFileURL(path).href;
  if (Buffer.byteLength(normalized) > 2048) throw new TypeError("Invalid local file link");
  return normalized;
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

function requestOpen(request, effect) {
  return request("files.open", JSON.stringify({
    url: effect.text,
    path: effect.paths?.[0],
    application: effect.application,
  }));
}

module.exports = { makeOpen, requestOpen, openActionComponents, openActionEffect, applicationSelector, webURL, metadataURL, metadataLinkURL };
