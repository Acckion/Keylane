// Narrow no-view adapter for the reviewed UUID Generator formatUuid command.
const fs = require("node:fs");
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

const { environment, LaunchType, configureEnvironment } = require("./environment.cjs");
exports.environment = environment;
exports.LaunchType = LaunchType;

const { Alert, AlertActionStyle, makePreferences, randomId, specialKeys, viewID } = require("./foundation-api.cjs");
const { makeBrokerLocalStorage } = require("./broker-local-storage.cjs");
const { localStorageAliases } = require("./storage-compat.cjs");
let localStorageAllowed = false;
const LocalStorage = makeBrokerLocalStorage((capability, text) => {
  if (!localStorageAllowed) throw new Error("LocalStorage unavailable");
  return exports.request(capability, text);
});
Object.assign(exports, { LocalStorage }, localStorageAliases(LocalStorage));

let preferenceDefinitions;
let preferences = { defaultAction: process.env.KEYLANE_PHASE === "noview-denied" ? "paste" : "copy" };
exports.loadPreferences = async () => {
  const payload = JSON.parse(await exports.request("preferences.read", ""));
  preferences = payload.preferences ?? payload;
  preferenceDefinitions = payload.preferenceDefinitions;
  localStorageAllowed = payload.localStorageAllowed === true;
  configureEnvironment(payload.environment);
};
exports.getPreferenceValues = () => ({ ...preferences });
exports.preferences = makePreferences(() => preferences, () => preferenceDefinitions);
exports.specialKeys = specialKeys;
exports.useId = () => viewID();
exports.randomId = randomId;
exports.Cache = require("./cache-api.cjs").Cache;
exports.Clipboard = {
  copy: async (text) => { await exports.request("clipboard.copy", text); },
  paste: async (text) => { await exports.request("clipboard.paste", text); },
};
const { Color, Icon, Image, ImageMask, Keyboard } = require("./presentation-values.cjs");
Object.assign(exports, { Color, Icon, Image, ImageMask, Keyboard }, require("./storage-compat.cjs").clipboardAliases(exports.Clipboard));
exports.showHUD = async (text) => { await exports.request("feedback.hud", text); };
const { makeToastAdapter } = require("./toast.cjs");
exports.Alert = Alert;
exports.AlertActionStyle = AlertActionStyle;
const { Toast, ToastStyle, showToast } = makeToastAdapter({
  show: async (_toast, { title, message }) => {
    await exports.request("feedback.toast", [title, message].filter(Boolean).join(": "));
  },
  hide: () => {}, // This headless broker records show events without a displayed toast.
});
Object.assign(exports, { Toast, ToastStyle, showToast });
