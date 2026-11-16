// Each guest runs one invocation. Populate this before evaluating the extension module.
const LaunchType = Object.freeze({ UserInitiated: "userInitiated", Background: "background" });
const maximumLaunchContextBytes = 2048;
const fields = [
  "ownerOrAuthorName", "extensionName", "entryPointType", "entryPointName", "entryPointMode",
  "isDevelopment", "appearance", "textSize", "launchType", "launchContext",
];
let snapshot;
const apiCapabilities = new WeakMap();

function registerEnvironmentCapability(api, isAllowed) {
  apiCapabilities.set(api, isAllowed);
}

function normalizedLaunchContext(input) {
  if (input == null || typeof input !== "object" || Array.isArray(input)) return undefined;
  try {
    const serialized = JSON.stringify(input);
    if (serialized === undefined || Buffer.byteLength(serialized) > maximumLaunchContextBytes) return undefined;
    const context = JSON.parse(serialized, (_key, value) =>
      value !== null && typeof value === "object" ? Object.freeze(value) : value);
    return context !== null && typeof context === "object" && !Array.isArray(context) ? context : undefined;
  } catch {
    return undefined;
  }
}

function configureEnvironment(input) {
  snapshot = input === undefined ? undefined : Object.freeze({
    ...input,
    launchContext: normalizedLaunchContext(input?.launchContext),
  });
}

const environment = {
  assetsPath: "/assets",
  supportPath: "/support",
  canAccess(api) {
    return apiCapabilities.get(api)?.() === true;
  },
};
for (const field of fields) {
  Object.defineProperty(environment, field, { enumerable: true, get: () => snapshot?.[field] });
}
for (const [alias, field] of Object.entries({
  commandName: "entryPointName", commandMode: "entryPointMode", theme: "appearance",
})) {
  Object.defineProperty(environment, alias, { enumerable: true, get: () => environment[field] });
}

module.exports = { environment: Object.freeze(environment), LaunchType, configureEnvironment, registerEnvironmentCapability };
