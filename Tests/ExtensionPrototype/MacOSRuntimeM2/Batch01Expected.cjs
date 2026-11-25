// Legacy adapter is an oracle for stable values and compatibility helpers.
const path = require("node:path");
const legacy = (file) => require(path.join(__dirname, "../LinuxGuest", file));
const { Icon, Color, Keyboard, Image, ImageMask } = legacy("presentation-values.cjs");
const { Alert, AlertActionStyle, specialKeys } = legacy("foundation-api.cjs");
const { LaunchType, configureEnvironment } = legacy("environment.cjs");
const { PopToRootType } = legacy("navigation-api.cjs");
const { ToastStyle } = legacy("toast.cjs").makeToastAdapter(() => {});
const { getAvatarIcon, getProgressIcon } = legacy("utilities-visual-feedback.cjs");
const { utilitiesRuntimeHooksFor } = legacy("utilities-runtime-hooks.cjs");
const links = legacy("utilities-deeplinks.cjs");
const { DeeplinkType } = utilitiesRuntimeHooksFor();
const { FormValidation } = legacy("raycast-utils.cjs");

delete process.env.RAYCAST_SCHEME;
configureEnvironment({ appearance: "light", ownerOrAuthorName: "fixture", extensionName: "batch-01" });
const ext = { command: "demo", arguments: { name: "你好 &" }, context: { url: "https://example.test/a?b=1" },
  launchType: LaunchType.Background, fallbackText: "搜索 + test" };
const script = { command: "demo", arguments: ["first & second", "中文 🐈"] };
const deeplinks = [
  ["createExtensionDeeplink", ext],
  ["createExtensionDeeplink", { ...ext, ownerOrAuthorName: "demo", extensionName: "external" }],
  ["createScriptCommandDeeplink", script],
  ["createScriptCommandDeeplink", { command: "bare" }],
  ["createDeeplink", { ...script, type: DeeplinkType.ScriptCommand }],
  ["createDeeplink", { ...ext, type: DeeplinkType.Extension }],
].map(([method, opts]) => [method, opts, links[method](opts)]);
const avatars = [
  ["王 小明", {}],
  ["👩🏽‍💻 Lee", { background: Color.Brown, gradient: false }],
  ["", { background: "#123456" }],
].map(([name, options]) => [name, options, getAvatarIcon(name, options)]);
const progress = [
  [0, Color.Blue, {}],
  [0.37, Color.Brown, { backgroundOpacity: 0.5 }],
  [1, "#ff33aa", { background: "#123456" }],
].map(([fraction, color, options]) => [fraction, color, options, getProgressIcon(fraction, color, options)]);
console.log(JSON.stringify({ api: { Icon, Color, Keyboard, Image, ImageMask, Alert, AlertActionStyle,
  specialKeys, LaunchType, PopToRootType, ToastStyle }, deeplinkType: DeeplinkType,
  formValidation: FormValidation, avatars, progress, deeplinks }));
