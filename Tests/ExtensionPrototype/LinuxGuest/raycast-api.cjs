// Narrow no-view adapter for the reviewed UUID Generator formatUuid command.
const fs = require("node:fs");
const { AsyncLocalStorage } = require("node:async_hooks");
const assert = require("node:assert/strict");
const session = process.env.KEYLANE_SESSION;
const generation = 1;
const channel = 3; // Connected virtio socket inherited from the guest bootstrap.
let requestID = 0;
let pending = Buffer.alloc(0);

function send(frame) {
  const data = Buffer.from(JSON.stringify({ session, generation, ...frame }) + "\n");
  for (let offset = 0; offset < data.length;) {
    offset += fs.writeSync(channel, data, offset, data.length - offset);
  }
}

function exchange(frame) {
  send(frame);
  const buffer = Buffer.alloc(4096);
  while (pending.indexOf(10) < 0) {
    const count = fs.readSync(channel, buffer);
    if (count === 0) throw new Error("Keylane broker closed the session");
    pending = Buffer.concat([pending, buffer.subarray(0, count)]);
    if (pending.length > 16384) throw new Error("Keylane broker reply too large");
  }
  const end = pending.indexOf(10);
  const reply = JSON.parse(pending.subarray(0, end).toString("utf8"));
  pending = pending.subarray(end + 1);
  assert.equal(reply.session, session);
  assert.equal(reply.generation, generation);
  assert.equal(reply.version, 1);
  return reply;
}

exports.connect = () => {
  send({ kind: "hello", generation: 0, versions: [1] });
  assert.equal(exchange({ kind: "hello", versions: [1] }).kind, "ready");
};
exports.flood = (readReplies) => {
  for (let id = 1; id <= 8; id++) {
    const frame = { kind: "request", version: 1, requestID: id, capability: "echo", text: "x".repeat(12000) };
    if (readReplies) exchange(frame);
    else send(frame);
  }
};
exports.request = async (capability, text) => {
  const id = ++requestID;
  const reply = exchange({ kind: "request", version: 1, requestID: id, capability, text });
  assert.equal(reply.requestID, id);
  if (reply.kind === "denied" || reply.kind === "failed") throw new Error(reply.error);
  assert.equal(reply.kind, "result");
  return reply.text;
};

const { makeApplicationQueries } = require("./applications-api.cjs");
const { captureException, captureMemorySnapshot } = require("./diagnostics-api.cjs");
Object.assign(exports, makeApplicationQueries(exports.request), { captureException, captureMemorySnapshot });

const { environment, LaunchType, configureEnvironment, registerEnvironmentCapability } = require("./environment.cjs");
exports.environment = environment;
exports.LaunchType = LaunchType;

const { Alert, AlertActionStyle, makePreferences, resolvePreferenceValues, randomId, specialKeys, viewID } = require("./foundation-api.cjs");
const { makeBrokerLocalStorage } = require("./broker-local-storage.cjs");
const { localStorageAliases } = require("./storage-compat.cjs");
const { Cache, configureCache, takeCacheSnapshot } = require("./cache-api.cjs");
let localStorageAllowed = false;
const LocalStorage = makeBrokerLocalStorage((capability, text) => {
  if (!localStorageAllowed) throw new Error("LocalStorage unavailable");
  return exports.request(capability, text);
});
Object.assign(exports, { LocalStorage }, localStorageAliases(LocalStorage));

const cacheChunkBytes = 8192;
const inlineCacheBytes = 4224;
const maximumCacheBytes = 32 * 1024 + 128;

exports.readCache = async ({ cache, cacheSnapshotBytes }) => {
  if (cacheSnapshotBytes === undefined) return cache;
  if (!Number.isSafeInteger(cacheSnapshotBytes) || cacheSnapshotBytes <= inlineCacheBytes ||
      cacheSnapshotBytes > maximumCacheBytes || cache !== undefined) {
    throw new Error("Invalid cache transfer size");
  }
  const snapshot = Buffer.alloc(cacheSnapshotBytes);
  for (let offset = 0; offset < snapshot.length; offset += cacheChunkBytes) {
    const base64 = await exports.request("cache.readChunk", String(offset));
    const chunk = Buffer.from(base64, "base64");
    if (chunk.length !== Math.min(cacheChunkBytes, snapshot.length - offset)) {
      throw new Error("Invalid cache transfer chunk");
    }
    chunk.copy(snapshot, offset);
  }
  return JSON.parse(snapshot.toString("utf8"));
};

exports.commitCache = async (cache, { legacy = false } = {}) => {
  const json = JSON.stringify(cache);
  const data = Buffer.from(json);
  if (data.length > maximumCacheBytes) throw new Error("Cache transfer exceeds the size limit");
  if (legacy && data.length <= inlineCacheBytes) {
    await exports.request("cache.commit", json);
    return;
  }
  for (let offset = 0; offset < data.length; offset += cacheChunkBytes) {
    const chunk = data.subarray(offset, offset + cacheChunkBytes);
    await exports.request("cache.writeChunk", chunk.toString("base64"));
  }
  await exports.request("cache.writeChunk", "");
};

let preferenceDefinitions;
let interactiveToast = false;
let clipboardReadAllowed = false;
const clipboardCommandScope = new AsyncLocalStorage();
let preferences = { defaultAction: process.env.KEYLANE_PHASE === "noview-denied" ? "paste" : "copy" };
exports.loadPreferences = async () => {
  const payload = JSON.parse(await exports.request("preferences.read", ""));
  preferenceDefinitions = payload.preferenceDefinitions;
  preferences = resolvePreferenceValues(payload.preferences ?? (preferenceDefinitions === undefined ? payload : undefined),
    preferenceDefinitions);
  localStorageAllowed = payload.localStorageAllowed === true;
  interactiveToast = payload.interactiveToast === true;
  clipboardReadAllowed = payload.clipboardReadAllowed === true;
  configureEnvironment(payload.environment);
  configureCache(await exports.readCache(payload));
};
exports.updateCommandMetadata = require("./command-metadata.cjs").makeUpdateCommandMetadata((subtitle) =>
  exports.request("command.updateMetadata", JSON.stringify({ subtitle })));
exports.openExtensionPreferences = async () => { await exports.request("preferences.open", "extension"); };
exports.openCommandPreferences = async () => { await exports.request("preferences.open", "command"); };
exports.showInFinder = require("./finder-reveal.cjs").makeShowInFinder(({ paths: [path] }) => {
  if (visibleToast?.interaction) visibleToast = { ...visibleToast, interaction: undefined };
  return exports.request("files.reveal", path);
});
const { makeOpen, requestOpen } = require("./open-api.cjs");
exports.open = makeOpen((effect) => {
  if (visibleToast?.interaction) visibleToast = { ...visibleToast, interaction: undefined };
  return requestOpen(exports.request, effect);
});
exports.trash = require("./trash-action.cjs").makeTrash(async ({ paths }) => {
  if (visibleToast?.interaction) visibleToast = { ...visibleToast, interaction: undefined };
  const result = await exports.request("files.trash", JSON.stringify(paths));
  if (result === "cancelled") throw new Error("Moving files to Trash was cancelled");
  if (result !== "moved") throw new Error("Unable to move all files to Trash");
});
exports.getPreferenceValues = () => ({ ...preferences });
exports.preferences = makePreferences(() => preferences, () => preferenceDefinitions);
exports.specialKeys = specialKeys;
exports.useId = () => viewID();
exports.randomId = randomId;
exports.Cache = Cache;
const { clipboardWritePayload } = require("./clipboard-write.cjs");
const { makeClipboardReaders } = require("./clipboard-read.cjs");
const canReadClipboard = () => clipboardReadAllowed && clipboardCommandScope.getStore()?.active === true;
const clipboardReaders = makeClipboardReaders((capability, selector) => {
  if (selector.includes(":") && visibleToast?.interaction) visibleToast = { ...visibleToast, interaction: undefined };
  return exports.request(capability, selector);
}, canReadClipboard);
exports.Clipboard = {
  ...clipboardReaders,
  async clear() {
    if (visibleToast?.interaction) visibleToast = { ...visibleToast, interaction: undefined };
    const reply = await exports.request("clipboard.clear", "");
    if (reply === "cancelled") throw new Error("Clearing the clipboard was cancelled");
    if (reply === "changed") throw new Error("The clipboard changed before confirmation");
    if (reply !== "cleared") throw new Error("Unable to clear the clipboard");
  },
  async copy(content, options) {
    if (typeof content === "string" && options === undefined) {
      await exports.request("clipboard.copy", content);
    } else {
      await exports.request("clipboard.write", clipboardWritePayload(content, options));
    }
  },
  paste: async (text) => { await exports.request("clipboard.paste", text); },
};
for (const api of [exports.Clipboard, exports.Clipboard.read, exports.Clipboard.readText]) {
  registerEnvironmentCapability(api, canReadClipboard);
}
const { Color, Icon, Image, ImageMask, Keyboard } = require("./presentation-values.cjs");
Object.assign(exports, { Color, Icon, Image, ImageMask, Keyboard }, require("./storage-compat.cjs").clipboardAliases(exports.Clipboard));
const { makeNavigation, PopToRootType, requestNavigation } = require("./navigation-api.cjs");
exports.PopToRootType = PopToRootType;
const noViewNavigation = makeNavigation(async (effect) => {
  if (visibleToast?.interaction) visibleToast = { ...visibleToast, interaction: undefined };
  await requestNavigation(exports.request, effect);
});
exports.showHUD = noViewNavigation.showHUD;
exports.closeMainWindow = noViewNavigation.closeMainWindow;
exports.popToRoot = noViewNavigation.popToRoot;
exports.clearSearchBar = noViewNavigation.clearSearchBar;
const { makeToastAdapter, toastInteraction, runWithToastActions } = require("./toast.cjs");
exports.confirmAlert = require("./alert-api.cjs").makeConfirmAlert((payload) =>
  exports.request("feedback.confirmAlert", payload));
exports.Alert = Alert;
exports.AlertActionStyle = AlertActionStyle;
let toastSequence = 0;
let visibleToast;
async function displayToast(toast, options, operation, callbacks) {
  const id = operation === "show" ? ++toastSequence : visibleToast.id;
  const { style, title, message, feedbackAction, secondaryFeedbackAction } = options;
  const interaction = interactiveToast && callbacks ? toastInteraction(options) : undefined;
  await exports.request("feedback.toast", JSON.stringify({
    operation, id, style, title, message, feedbackAction, secondaryFeedbackAction, interaction,
  }));
  visibleToast = { toast, id, options, callbacks, interaction };
}

const { Toast, ToastStyle, showToast, flushToastUpdates } = makeToastAdapter({
  show: (toast, options, callbacks) => displayToast(toast, options, "show", callbacks),
  update(toast, options, callbacks) {
    if (visibleToast?.toast === toast) return displayToast(toast, options, "update", callbacks);
  },
  async hide(toast) {
    if (visibleToast?.toast !== toast) return;
    const current = visibleToast;
    await exports.request("feedback.toast", JSON.stringify({ operation: "hide", id: current.id }));
    if (visibleToast === current) visibleToast = undefined;
  },
});
Object.assign(exports, { Toast, ToastStyle, showToast, flushToastUpdates });

exports.runNoViewCommand = async (command) => {
  const run = async () => {
    await command();
    await flushToastUpdates();
  };
  const clipboardScope = { active: true };
  await clipboardCommandScope.run(clipboardScope, async () => {
    try {
      if (!interactiveToast) await run();
      else await runWithToastActions(run, {
        currentToast: () => visibleToast,
        hasResult: () => false,
        select: (token, polling) => exports.request("feedback.toastAction", polling ? token + ":poll" : token),
        redisplay: (current, callbacks) => displayToast(current.toast, current.options, "update", callbacks),
        flush: flushToastUpdates,
      });
    } finally {
      clipboardScope.active = false;
    }
  });
  const cache = takeCacheSnapshot({ flushPending: true });
  if (cache !== undefined) await exports.commitCache(cache, { legacy: true });
};
