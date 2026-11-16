const { environment } = require("./environment.cjs");

const palette = ["#965575", "#9a473d", "#9a682c", "#537a40", "#217c73", "#416da2", "#655cab", "#8353a1"];
const standardColors = new Map([
  ["raycast-blue", "#4387f5"], ["raycast-green", "#43ad65"], ["raycast-magenta", "#d84fc5"],
  ["raycast-orange", "#f28a32"], ["raycast-purple", "#9661dc"], ["raycast-red", "#ff6363"],
  ["raycast-yellow", "#f4bc36"], ["black", "#000000"], ["white", "#ffffff"],
]);

// One signed guest handles one invocation. Keep module-initialized assets available to the renderer.
const assets = new Map();
const maxAssets = 256;

function asAsset(svg, descriptor) {
  const source = `data:image/svg+xml,${encodeURIComponent(svg)}`;
  if (!assets.has(source) && assets.size === maxAssets) assets.delete(assets.keys().next().value);
  assets.set(source, Object.freeze(descriptor));
  return source;
}

function describeUtilityIcon(source) {
  return typeof source === "string" ? assets.get(source) : undefined;
}

function resolveColor(value, fallback) {
  if (typeof value !== "string") return fallback;
  const color = value.trim().toLowerCase();
  const dark = environment.appearance !== "light";
  if (color === "raycast-primary-text") return dark ? "#ffffff" : "#000000";
  if (color === "raycast-secondary-text") return dark ? "#a8a8ae" : "#606069";
  if (standardColors.has(color)) return standardColors.get(color);
  const digits = color.match(/^#?([a-f0-9]{3}|[a-f0-9]{6})$/)?.[1];
  if (!digits) return fallback;
  return "#" + (digits.length === 3 ? [...digits].map((digit) => digit + digit).join("") : digits);
}

function mixedColor(color, target, amount) {
  const channels = [1, 3, 5].map((index) => parseInt(color.slice(index, index + 2), 16));
  return "#" + channels.map((channel) => Math.round(channel + (target - channel) * amount).toString(16).padStart(2, "0")).join("");
}

function firstCharacter(word) {
  return word.match(/^\P{Mark}\p{Mark}{0,2}/u)?.[0] ?? [...word][0] ?? "";
}

function initialsFor(name) {
  const words = name.toWellFormed().trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return "";
  const first = firstCharacter(words[0]);
  const last = words.length === 1 ? "" : firstCharacter(words[words.length - 1]);
  return (first + last).toUpperCase().replace(/[\u0000-\u001f\u007f-\u009f]/g, "");
}

function avatarColor(initials) {
  let hash = 0;
  for (const char of initials) hash = (Math.imul(hash, 31) + char.codePointAt(0)) >>> 0;
  return palette[hash % palette.length];
}

function escapeText(text) {
  return text.replace(/[&<>]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[character]);
}

function getAvatarIcon(name, options = {}) {
  const initials = initialsFor(name);
  const background = resolveColor(options?.background, avatarColor(initials));
  const light = options?.gradient === false ? background : mixedColor(background, 255, 0.2);
  const dark = options?.gradient === false ? background : mixedColor(background, 0, 0.18);
  const fill = light === dark ? background : "url(#avatar)";
  const gradient = light === dark ? "" : `<defs><linearGradient id="avatar" x2="0%" y2="100%"><stop stop-color="${light}"/><stop offset="100%" stop-color="${dark}"/></linearGradient></defs>`;
  const text = initials ? `<text x="50" y="50" dominant-baseline="central" text-anchor="middle" font-size="42" font-family="sans-serif" fill="#ffffff">${escapeText(initials)}</text>` : "";
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">${gradient}<circle cx="50" cy="50" r="50" fill="${fill}"/>${text}</svg>`;
  return asAsset(svg, { kind: "avatar", initials, startColor: light, endColor: dark });
}

function clampedFraction(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : fallback;
}

function getProgressIcon(progress, color, options = {}) {
  const fraction = clampedFraction(progress, 0);
  const foreground = resolveColor(color, "#ff6363");
  const background = resolveColor(options?.background, environment.appearance === "light" ? "#000000" : "#ffffff");
  const opacity = clampedFraction(options?.backgroundOpacity, 0.1);
  const ring = `<circle cx="50" cy="50" r="40" fill="none" stroke-width="10"`;
  const track = fraction === 1 ? "" : `${ring} stroke="${background}" opacity="${opacity}"/>`;
  const completion = fraction === 0 ? "" : fraction === 1 ? `${ring} stroke="${foreground}"/>`
    : `${ring} stroke="${foreground}" pathLength="1" stroke-dasharray="${fraction} 1" transform="rotate(-90 50 50)"/>`;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100">${track}${completion}</svg>`;
  return asAsset(svg, { kind: "progress", fraction, foreground, background, opacity });
}

function makeShowFailureToast(apiProvider) {
  return (error, options) => {
    const { showToast, Toast } = apiProvider();
    return showToast({
      style: Toast.Style.Failure,
      title: options?.title ?? "Something went wrong",
      message: options?.message ?? (error instanceof Error ? error.message : String(error)),
      primaryAction: options?.primaryAction,
    });
  };
}

module.exports = { getAvatarIcon, getProgressIcon, describeUtilityIcon, makeShowFailureToast };
