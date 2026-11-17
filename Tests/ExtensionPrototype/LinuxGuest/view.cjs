const broker = require("/raycast-api.cjs");
const api = require("/view-api.cjs");
const { configureExceptionReporting, configureMemoryReporting, recordMemorySample } = require("./diagnostics-api.cjs");
const { limitImagePayloads } = require("./image-api.cjs");

const uuidCommands = new Set([
  "generate", "generateV5", "generateV7", "generateUlid", "generateTypeID", "parseTypeID", "packTypeID",
]);

async function readViewSnapshot(bytes, maximum, capability) {
  if (!Number.isSafeInteger(bytes) || bytes < 1 || bytes > maximum) {
    throw new Error("Invalid view snapshot transfer size");
  }
  const data = Buffer.alloc(bytes);
  for (let offset = 0; offset < bytes; offset += 8192) {
    const encoded = await broker.request(capability, String(offset));
    const chunk = Buffer.from(encoded, "base64");
    if (chunk.length !== Math.min(8192, bytes - offset) || chunk.toString("base64") !== encoded) {
      throw new Error("Invalid view snapshot chunk");
    }
    chunk.copy(data, offset);
  }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data));
}

async function restoreViewPreferences(input) {
  if (input.viewPreferencesSnapshotBytes === undefined) return;
  const snapshot = await readViewSnapshot(input.viewPreferencesSnapshotBytes, 16384, "view.readPreferences");
  if (!snapshot || typeof snapshot !== "object" || Array.isArray(snapshot) ||
      Object.keys(snapshot).some((key) => !["preferences", "preferenceDefinitions"].includes(key) || Object.hasOwn(input, key))) {
    throw new Error("Invalid view preference snapshot");
  }
  Object.assign(input, snapshot);
}

async function restoreViewIDs(input) {
  if (input.viewIDSnapshotBytes === undefined) return;
  const snapshots = await readViewSnapshot(input.viewIDSnapshotBytes, (6144 + 1) * 6 + 32, "view.readIDs");
  const frames = [input, input.poppedFrame, ...(input.viewRoute ?? [])];
  if (!Array.isArray(snapshots) || snapshots.length !== frames.length) throw new Error("Invalid view ID transfer");
  for (let index = 0; index < frames.length; index++) {
    const ids = snapshots[index];
    if (ids === null) continue;
    if (!frames[index] || frames[index].viewIDs !== undefined) throw new Error("Conflicting view ID snapshot");
    frames[index].viewIDs = ids;
  }
}

async function main() {
  broker.connect();
  const input = JSON.parse(await broker.request("view.input", ""));
  require("./environment.cjs").configureEnvironment(input.environment);
  input.cache = await broker.readCache(input);
  await restoreViewIDs(input);
  await restoreViewPreferences(input);
  api.prepareInput(input);
  if (!input.sensitiveFormSubmission) {
    configureExceptionReporting((category) => broker.request("diagnostics.exception", category));
  }
  if (input.memoryReporting === true && input.mode === undefined && !input.sensitiveFormSubmission) {
    configureMemoryReporting((sample) => broker.request("view.memorySample", JSON.stringify(sample)));
    recordMemorySample(null);
    setInterval(() => recordMemorySample(null), 750).unref();
  }
  const commands = require("/sample.cjs");
  let result;
  if (input.mode === "menuBar") {
    result = await api.runMenuBar(commands.default, input);
  } else if (input.catalogNoView === true) {
    const name = input.viewEntryPoint;
    if (!Object.hasOwn(commands, name)) throw new Error("Missing reviewed command entry point");
    result = await api.runCommand(commands[name], input);
  } else if (uuidCommands.has(input.mode)) {
    result = await api.runCommand(commands[input.mode], input);
  } else {
    let previousProgress;
    let progressBudget = 32 * 1024;
    const renderProgress = input.progressUpdates === true && input.mode === undefined ? {
      // This guest handles exactly one invocation. Once the event loop empties,
      // send the final snapshot including state changes from detached timers and I/O.
      drain: () => new Promise((resolve) => process.once("beforeExit", resolve)),
      async publish(preview) {
        const serialized = JSON.stringify(limitImagePayloads(preview));
        const wireBytes = Buffer.byteLength(JSON.stringify(serialized)) + 256;
        if (serialized === previousProgress || Buffer.byteLength(serialized) > 10_240 ||
            wireBytes > progressBudget) return false;
        previousProgress = serialized;
        progressBudget -= wireBytes;
        try {
          await broker.request("view.progress", serialized);
          return true;
        } catch {
          // Progress is optional. A rejected preview must not suppress the final view.
          return false;
        }
      },
    } : undefined;
    let command = input.mode === "history" ? commands.history : commands.default;
    if (input.viewEntryPoint !== undefined) {
      if (typeof input.viewEntryPoint !== "string" || !Object.hasOwn(commands, input.viewEntryPoint)) {
        throw new Error("Missing reviewed view entry point");
      }
      command = commands[input.viewEntryPoint];
      if (typeof command !== "function") throw new Error("Invalid reviewed view entry point");
    }
    result = await api.render(command, input, renderProgress);
  }
  const { cache, ...view } = limitImagePayloads(result);
  if ((input.mode === undefined || input.mode === "menuBar") && view.viewIDs !== undefined && !input.sensitiveFormSubmission) {
    await broker.request("view.writeIDs", JSON.stringify(view.viewIDs));
    delete view.viewIDs;
  }
  const inline = JSON.stringify(cache === undefined ? view : { ...view, cache });
  if (cache !== undefined && Buffer.byteLength(inline) > 8192) {
    await broker.commitCache(cache);
    await broker.request("view.result", JSON.stringify(view));
  } else {
    await broker.request("view.result", inline);
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
