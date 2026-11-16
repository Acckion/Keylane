const { environment } = require("./environment.cjs");

function raycastURL(path) {
  return `${process.env.RAYCAST_SCHEME || "raycast"}://${path}`;
}

function createScriptCommandDeeplink({ command, arguments: args }) {
  const url = raycastURL(`script-commands/${command}`);
  if (!args) return url;

  // Script commands take repeated arguments in the same order as the inputs.
  return `${url}?${args.map((arg) => `arguments=${encodeURIComponent(arg)}`).join("&")}`;
}

function createExtensionDeeplink(options) {
  const external = "ownerOrAuthorName" in options && "extensionName" in options;
  const identity = external ? options : environment;
  const { ownerOrAuthorName, extensionName } = identity;
  if (!ownerOrAuthorName || !extensionName) {
    throw new Error("The extension owner and name are unavailable for this deeplink.");
  }

  const { command, launchType, arguments: args, context, fallbackText } = options;
  const url = raycastURL(`extensions/${ownerOrAuthorName}/${extensionName}/${command}`);
  const entries = [
    ["launchType", launchType],
    ["arguments", args && JSON.stringify(args)],
    ["context", context && JSON.stringify(context)],
    ["fallbackText", fallbackText],
  ];
  const query = entries.filter(([, value]) => value)
    .map(([name, value]) => `${name}=${encodeURIComponent(value)}`).join("&");
  return query ? `${url}?${query}` : url;
}

function createDeeplink(options) {
  return options.type === "script-command"
    ? createScriptCommandDeeplink(options)
    : createExtensionDeeplink(options);
}

module.exports = { createDeeplink, createExtensionDeeplink, createScriptCommandDeeplink };
