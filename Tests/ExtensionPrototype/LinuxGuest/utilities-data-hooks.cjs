const { constants } = require("node:fs");
const { open } = require("node:fs/promises");
const { fileURLToPath } = require("node:url");

const inputLimit = 1024 * 1024;
const itemLimit = 2048;
const depthLimit = 64;

function requestURL(input) {
  if (input instanceof Request) return new URL(input.url);
  if (input instanceof URL || typeof input === "string") return new URL(input);
  throw new TypeError("Expected a URL or Request");
}

async function* fileChunks(input) {
  const url = requestURL(input);
  if (url.protocol !== "file:" || url.host || url.username || url.password || url.search || url.hash) {
    throw new Error("useStreamJSON requires a guest-local file URL");
  }

  const file = await open(fileURLToPath(url), constants.O_RDONLY | constants.O_NONBLOCK);
  try {
    const stat = await file.stat();
    if (!stat.isFile()) throw new Error("Expected a regular JSON file");
    if (stat.size > inputLimit) throw new Error("JSON input exceeds the guest limit");

    let bytes = 0;
    const stream = file.createReadStream({ autoClose: false, highWaterMark: 16 * 1024 });
    const decoder = new TextDecoder("utf-8", { fatal: true });
    for await (const chunk of stream) {
      bytes += chunk.length;
      if (bytes > inputLimit) throw new Error("JSON input exceeds the guest limit");
      const text = decoder.decode(chunk, { stream: true });
      if (text) yield text;
    }
    const tail = decoder.decode();
    if (tail) yield tail;
  } finally {
    await file.close();
  }
}

async function* streamArray(chunks) {
  let phase = "start";
  let nesting = 0;
  let quoted = false;
  let escaped = false;
  let token = "";

  for await (const chunk of chunks) {
    for (const character of chunk) {
      const whitespace = " \n\r\t".includes(character);
      if (phase !== "item" && whitespace) continue;
      if (phase === "start") {
        if (character !== "[") throw new Error("Expected a JSON array");
        phase = "first";
        continue;
      }
      if (phase === "done") throw new Error("Unexpected data after the JSON array");
      if (phase === "first" || phase === "next") {
        if (phase === "first" && character === "]") {
          phase = "done";
          continue;
        }
        if (character === "]" || character === ",") throw new Error("Expected a JSON array item");
        phase = "item";
      }

      if (quoted) {
        if (escaped) escaped = false;
        else if (character === "\\") escaped = true;
        else if (character === '"') quoted = false;
      } else if (nesting === 0 && (character === "," || character === "]")) {
        yield JSON.parse(token);
        token = "";
        phase = character === "]" ? "done" : "next";
        continue;
      } else if (character === '"') {
        quoted = true;
      } else if (character === "[" || character === "{") {
        if (++nesting > depthLimit) throw new Error("JSON nesting exceeds the guest limit");
      } else if (character === "]" || character === "}") {
        if (--nesting < 0) throw new Error("Invalid JSON array item");
      }
      token += character;
    }
  }
  if (phase !== "done") throw new Error("Incomplete JSON array");
}

async function* arraysAtPath(chunks, dataPath) {
  let text = "";
  for await (const chunk of chunks) text += chunk;
  const root = JSON.parse(text);
  if (typeof dataPath === "string") {
    let node = root;
    for (const key of dataPath.split(".")) {
      node = node && typeof node === "object" && Object.hasOwn(node, key) ? node[key] : undefined;
    }
    if (Array.isArray(node)) yield* node;
    return;
  }
  if (!(dataPath instanceof RegExp)) throw new TypeError("Expected a string or regular expression dataPath");

  const expression = new RegExp(dataPath.source, dataPath.flags);
  function* visit(node, path, depth) {
    if (depth > depthLimit) throw new Error("JSON nesting exceeds the guest limit");
    if (Array.isArray(node)) {
      expression.lastIndex = 0;
      if (expression.test(path)) yield* node;
    } else if (node && typeof node === "object") {
      for (const [key, child] of Object.entries(node)) {
        yield* visit(child, path ? path + "." + key : key, depth + 1);
      }
    }
  }
  yield* visit(root, "", 0);
}

function requestOptions(options) {
  const { method, headers, body, cache, credentials, integrity, keepalive, mode, redirect,
    referrer, referrerPolicy, signal, duplex } = options;
  return { method, headers, body, cache, credentials, integrity, keepalive, mode, redirect,
    referrer, referrerPolicy, signal, duplex };
}

function initialState(result, initialData) {
  return { ...result, data: result.data === undefined ? initialData : result.data, pagination: undefined };
}

function utilitiesDataHooksFor(usePromise, executeSQL) {
  function useFetch(input, options = {}) {
    const { parseResponse, mapResult, initialData } = options;
    const run = async (resource, init) => {
      const request = new Request(resource, init);
      const url = new URL(request.url);
      if (url.protocol !== "data:") throw new Error("useFetch requires an inline data URL in the guest");
      if (Buffer.byteLength(url.href) > inputLimit) throw new Error("Fetch input exceeds the guest limit");
      const response = await fetch(request);
      if (!response.ok) throw new Error(`Request failed with status ${response.status}`);
      const contentType = response.headers.get("content-type")?.split(";")[0].trim().toLowerCase() ?? "";
      const result = parseResponse ? await parseResponse(response)
        : contentType === "application/json" || contentType.endsWith("+json")
          ? await response.json() : await response.text();
      return mapResult ? mapResult(result).data : result;
    };
    return initialState(usePromise(run, [input, requestOptions(options)], options), initialData);
  }

  function useStreamJSON(input, options = {}) {
    const { dataPath, filter, transform, initialData } = options;
    const run = async (resource) => {
      const chunks = fileChunks(resource);
      const source = dataPath === undefined ? streamArray(chunks) : arraysAtPath(chunks, dataPath);
      const items = [];
      for await (const item of source) {
        const transformed = transform ? transform(item) : item;
        for (const candidate of transform && Array.isArray(transformed) ? transformed : [transformed]) {
          if (filter && !filter(candidate)) continue;
          if (items.length >= itemLimit) throw new Error("JSON result exceeds the guest item limit");
          items.push(candidate);
        }
      }
      return items;
    };
    return initialState(usePromise(run, [input], options), initialData);
  }

  function useSQL(databasePath, query, options = {}) {
    return { ...usePromise(executeSQL, [databasePath, query], options), permissionView: null };
  }

  return { useFetch, useStreamJSON, useSQL };
}

module.exports = { utilitiesDataHooksFor };
