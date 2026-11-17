const { applicationSelector, metadataLinkURL } = require("./open-api.cjs");
const { absoluteFilePath } = require("./finder-reveal.cjs");

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
  const { link, name, application, icon } = checkedObject(value, "quicklink");
  const template = checkedString(link, "quicklink URL", 2048);
  const isPath = template.startsWith("/") || template.startsWith("~/");
  if (!isPath && !/^[a-z][a-z0-9+.-]{0,63}:/i.test(template)) throw new Error("Expected a quicklink with a fixed scheme");
  const authority = /^[a-z][a-z0-9+.-]*:\/\/([^/?#]*)/i.exec(template)?.[1];
  if (authority && /[{}]/.test(authority)) throw new Error("Expected a quicklink with a fixed host");

  // Keylane QuicklinkTemplate replaces named parameters only outside the URL authority.
  const defaults = new Map();
  const mailRecipientEnd = /^mailto:/i.test(template) ? template.split("?", 1)[0].length : -1;
  const isTelephone = /^tel:/i.test(template);
  // The authoritative host parser validates attributes and modifiers before opening the draft.
  const literalURL = template.replace(/\{([^{}]+)\}/gu, (match, body, offset) => {
    const legacy = /^([\p{L}\p{M}\p{N}_-]+)(?:[=:]([^{}]*))?$/u.exec(body);
    if (legacy) {
      const [, parameter, fallback] = legacy;
      if (defaults.has(parameter) && defaults.get(parameter) !== fallback) throw new Error("Quicklink parameter has conflicting defaults");
      defaults.set(parameter, fallback);
    }
    if (isTelephone) return "123";
    if (offset === "mailto:".length && offset + match.length === mailRecipientEnd) return "user@example.invalid";
    return "value";
  });
  if (/[{}]/.test(literalURL)) throw new Error("Invalid quicklink parameter");
  if (isPath) {
    absoluteFilePath(literalURL.startsWith("~/") ? literalURL.slice(1) : literalURL);
  } else {
    metadataLinkURL(literalURL);
  }
  const app = applicationSelector(application);
  const symbol = checkedString(icon, "quicklink icon", 96, { optional: true });
  return { link: template, name: checkedString(name, "quicklink name", 256, { optional: true }),
    ...(app && { application: app }), ...(symbol !== undefined && { icon: symbol }) };
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
