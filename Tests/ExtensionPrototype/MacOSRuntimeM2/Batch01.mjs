import * as api from "@raycast/api";
import * as utils from "@raycast/utils";
import expected from "./batch-01-expected.json";

const exportsByPackage = { "@raycast/api": api, "@raycast/utils": utils };
const verify = (condition, name) => {
  if (!condition) throw new Error(name);
};
const same = (actual, value, name) =>
  verify(JSON.stringify(actual) === JSON.stringify(value), name);

export default function batch01({ arguments: { grants } }) {
  for (const [pack, path] of expected.rows) {
    let value = exportsByPackage[pack];
    for (const name of path.split(".")) {
      verify(value != null && Object.hasOwn(value, name), path);
      value = value[name];
    }
    verify(value !== undefined, path);
  }
  for (const [name, value] of Object.entries(expected.api)) {
    same(name === "ToastStyle" ? api.Toast.Style : api[name], value, name);
  }
  same(api.Icon, expected.sdkIcons, "SDK icon values");
  same(utils.FormValidation, expected.formValidation, "FormValidation");
  same(utils.DeeplinkType, expected.deeplinkType, "DeeplinkType");
  verify(api.Image.Mask === api.ImageMask, "ImageMask alias");
  verify(api.Toast.Style === api.ToastStyle, "ToastStyle alias");
  verify(api.Alert.ActionStyle === api.AlertActionStyle, "AlertActionStyle alias");
  for (const value of [api.Icon, api.Color, api.Color.Brown, api.Image.Mask, api.Keyboard.Shortcut.Common,
    api.Keyboard.Shortcut.Common.Copy.macOS.modifiers, api.specialKeys, api.LaunchType, api.PopToRootType,
    api.Alert, api.Toast.Style, api.environment, utils.FormValidation, utils.DeeplinkType]) {
    verify(Object.isFrozen(value), "Immutable public values");
  }
  same({
    ownerOrAuthorName: api.environment.ownerOrAuthorName,
    extensionName: api.environment.extensionName,
    entryPointName: api.environment.entryPointName,
    commandName: api.environment.commandName,
    entryPointMode: api.environment.entryPointMode,
    commandMode: api.environment.commandMode,
    appearance: api.environment.appearance,
    theme: api.environment.theme,
    textSize: api.environment.textSize,
    isDevelopment: api.environment.isDevelopment,
    raycastVersion: api.environment.raycastVersion,
  }, {
    ownerOrAuthorName: "fixture", extensionName: "batch-01", entryPointName: "main", commandName: "main",
    entryPointMode: "no-view", commandMode: "no-view", appearance: "light", theme: "light", textSize: "large",
    isDevelopment: false, raycastVersion: "9.8.7",
  }, "Environment from signed host");
  for (const capability of [api.Clipboard.copy, api.copyTextToClipboard, api.Toast, api.showToast, api.showHUD,
    api.closeMainWindow, api.clearSearchBar, api.popToRoot]) {
    verify(api.environment.canAccess(capability) === (grants === "on"), "Current invocation grants");
  }
  for (const capability of [api.Clipboard.paste, api.LocalStorage, api.Cache, {}, null, undefined]) {
    verify(api.environment.canAccess(capability) === false, "Unavailable grants");
  }
  for (const n of [undefined, 0, 1, 21, 65_536]) {
    const id = api.randomId(n);
    verify(id.length === (n ?? 21) && /^[A-Za-z0-9_-]*$/.test(id), "Random ID");
  }
  for (const n of [-1, 1.25, Infinity, "21", 65_537]) {
    let rejected = false;
    try { api.randomId(n); } catch (error) { rejected = error instanceof RangeError; }
    verify(rejected, "Invalid random ID length");
  }
  verify(api.randomId() !== api.randomId(), "Fresh random IDs");
  for (const [name, options, value] of expected.avatars) {
    const background = typeof options.background === "object" ? api.Color.Brown : options.background;
    same(utils.getAvatarIcon(name, { ...options, background }), value, "Avatar");
  }
  for (const [fraction, color, options, value] of expected.progress) {
    const foreground = typeof color === "object" ? api.Color.Brown : color;
    same(utils.getProgressIcon(fraction, foreground, options), value, "Progress");
  }
  for (const [method, options, value] of expected.deeplinks) {
    same(utils[method](options), value, method);
  }
}
