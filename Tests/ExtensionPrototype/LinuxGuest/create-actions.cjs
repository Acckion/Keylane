const { webURL } = require("./open-api.cjs");

function creationActionComponents(component) {
  const quicklink = component("createQuicklink");
  const snippet = component("createSnippet");
  return {
    CreateQuicklink: (props) => quicklink({ ...props, title: props?.title ?? "Create Quicklink" }),
    CreateSnippet: (props) => snippet({ ...props, title: props?.title ?? "Create Snippet" }),
  };
}

function checkedObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`Invalid ${name}`);
  }
  return value;
}

function checkedString(value, name, limit, { optional = false, multiline = false } = {}) {
  if (optional && value === undefined) return undefined;
  const invalid = multiline ? /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/u : /\p{Cc}/u;
  if (typeof value !== "string" || Buffer.byteLength(value) > limit || invalid.test(value)) {
    throw new TypeError(`Invalid ${name}`);
  }
  return value;
}

function checkedQuicklink(value) {
  const { link, name, application } = checkedObject(value, "quicklink");
  if (application !== undefined) throw new Error("Custom quicklink applications are unavailable");
  const template = checkedString(link, "quicklink URL", 2048);
  const authority = /^https?:\/\/([^/?#]+)/i.exec(template)?.[1];
  if (!authority || /[{}]/.test(authority)) throw new Error("Expected an HTTP(S) quicklink with a fixed host");

  // Keylane QuicklinkTemplate replaces named parameters only outside the URL authority.
  const definitions = new Map();
  const literalURL = template.replace(/\{([\p{L}\p{M}\p{N}_-]+)(?:=([^{}]*))?\}/gu, (_match, parameter, fallback) => {
    if (definitions.has(parameter) && definitions.get(parameter) !== fallback) {
      throw new Error("Quicklink parameter has conflicting defaults");
    }
    definitions.set(parameter, fallback);
    return "value";
  });
  if (/[{}]/.test(literalURL)) throw new Error("Invalid quicklink parameter");
  webURL(literalURL);
  return { link: template, name: checkedString(name, "quicklink name", 256, { optional: true }) };
}

function checkedSnippet(value) {
  const { text, name, keyword } = checkedObject(value, "snippet");
  return {
    text: checkedString(text, "snippet text", 4096, { multiline: true }),
    name: checkedString(name, "snippet name", 256, { optional: true }),
    keyword: checkedString(keyword, "snippet keyword", 128, { optional: true }),
  };
}

function creationActionEffect(action) {
  switch (action?.type) {
    case "createQuicklink":
      return { kind: "createQuicklink", quicklink: checkedQuicklink(action.props.quicklink) };
    case "createSnippet":
      return { kind: "createSnippet", snippet: checkedSnippet(action.props.snippet) };
    default:
      throw new Error("Expected a creation action");
  }
}

function makeOpenExtensionPreferences(emit) {
  return async function openExtensionPreferences() {
    await emit({ kind: "openExtensionPreferences" });
  };
}

module.exports = { creationActionComponents, creationActionEffect, makeOpenExtensionPreferences };
