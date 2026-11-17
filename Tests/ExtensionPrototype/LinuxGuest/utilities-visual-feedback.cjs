const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { registerNativeToastAction } = require("./toast.cjs");
const { environment } = require("./environment.cjs");
const { Color } = require("./presentation-values.cjs");

const palette = ["#965575", "#9a473d", "#9a682c", "#537a40", "#217c73", "#416da2", "#655cab", "#8353a1"];
const standardColors = new Map([
  ["raycast-blue", "#4387f5"], ["raycast-green", "#43ad65"], ["raycast-magenta", "#d84fc5"],
  ["raycast-orange", "#f28a32"], ["raycast-purple", "#9661dc"], ["raycast-red", "#ff6363"],
  ["raycast-yellow", "#f4bc36"], ["black", "#000000"], ["white", "#ffffff"],
]);

const imagePrefix = "data:image/svg+xml,";
const isHexColor = (value) => typeof value === "string"
  && (value.length === 7 || value.length === 9) && /^#[a-f0-9]{6}(?:[a-f0-9]{2})?$/.test(value);
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const isFraction = (value) => Number.isFinite(value) && value >= 0 && value <= 1;

function utilityAsset(descriptor) {
  const payload = Buffer.from(JSON.stringify(descriptor)).toString("base64url");
  const body = descriptor.kind === "avatar" ? avatarMarkup(descriptor) : progressMarkup(descriptor);
  return imagePrefix + encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100" data-keylane-icon="${payload}">${body}</svg>`,
  );
}

function describeUtilityIcon(source) {
  if (typeof source !== "string" || source.length > 4096 || !source.startsWith(imagePrefix)) return;
  try {
    // Read only our small typed payload. Never forward or render guest-supplied SVG.
    const svg = decodeURIComponent(source.slice(imagePrefix.length));
    const payload = /^<svg [^>]* data-keylane-icon="([a-zA-Z0-9_-]{1,512})">/.exec(svg)?.[1];
    if (!payload) return;
    const { kind, initials, startColor, endColor, fraction, foreground, background, opacity } =
      JSON.parse(Buffer.from(payload, "base64url").toString("utf8"));
    let descriptor;
    if (kind === "avatar" && typeof initials === "string" && initials.isWellFormed() &&
        Buffer.byteLength(initials) <= 32 && !/[\p{Cc}]/u.test(initials) &&
        [startColor, endColor].every(isHexColor)) {
      descriptor = { kind, initials, startColor, endColor };
    } else if (kind === "progress" && isFraction(fraction) && isFraction(opacity) &&
        [foreground, background].every(isHexColor)) {
      descriptor = { kind, fraction, foreground, background, opacity };
    }
    if (descriptor && utilityAsset(descriptor) === source) return descriptor;
  } catch {
    return undefined;
  }
}

function resolveColor(value, fallback) {
  const dark = environment.appearance !== "light";
  if (value === Color.Brown) return (dark ? Color.Brown.dark : Color.Brown.light).toLowerCase();
  if (typeof value !== "string") return fallback;
  const color = value.trim().toLowerCase();
  if (color === Color.PrimaryText) return dark ? "#ffffff" : "#000000";
  if (color === Color.SecondaryText) return dark ? "#a8a8ae" : "#606069";
  if (standardColors.has(color)) return standardColors.get(color);
  const digits = color.match(/^#?([a-f0-9]{3,4}|[a-f0-9]{6}|[a-f0-9]{8})$/)?.[1];
  if (!digits) return fallback;
  return "#" + (digits.length <= 4 ? [...digits].map((digit) => digit.repeat(2)).join("") : digits);
}

function mixedColor(color, target, amount) {
  const channels = [1, 3, 5].map((index) => parseInt(color.slice(index, index + 2), 16));
  const rgb = channels.map((channel) => Math.round(channel + (target - channel) * amount).toString(16).padStart(2, "0")).join("");
  return "#" + rgb + color.slice(7);
}

function firstCharacter(word) {
  const first = graphemes.segment(word)[Symbol.iterator]().next().value?.segment ?? "";
  const initial = first.toUpperCase().replace(/\p{Cc}/gu, "");
  // Keep the complete initial within the native descriptor's two-initial budget.
  return Buffer.byteLength(initial) <= 16 ? initial : ([...initial][0] ?? "");
}

function initialsFor(name) {
  const words = name.toWellFormed().trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) return "";
  const first = firstCharacter(words[0]);
  const last = words.length === 1 ? "" : firstCharacter(words[words.length - 1]);
  return first + last;
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
  return utilityAsset({ kind: "avatar", initials, startColor: light, endColor: dark });
}

function avatarMarkup({ initials, startColor: light, endColor: dark }) {
  const fill = light === dark ? light : "url(#avatar)";
  const gradient = light === dark ? "" : `<defs><linearGradient id="avatar" x2="0%" y2="100%"><stop stop-color="${light}"/><stop offset="100%" stop-color="${dark}"/></linearGradient></defs>`;
  const text = initials ? `<text x="50" y="50" dominant-baseline="central" text-anchor="middle" font-size="42" font-family="sans-serif" fill="#ffffff">${escapeText(initials)}</text>` : "";
  return `${gradient}<circle cx="50" cy="50" r="50" fill="${fill}"/>${text}`;
}

function clampedFraction(value, fallback) {
  return typeof value === "number" && Number.isFinite(value) ? Math.min(1, Math.max(0, value)) : fallback;
}

function getProgressIcon(progress, color, options = {}) {
  const fraction = clampedFraction(progress, 0);
  const foreground = resolveColor(color, "#ff6363");
  const background = resolveColor(options?.background, environment.appearance === "light" ? "#000000" : "#ffffff");
  const opacity = clampedFraction(options?.backgroundOpacity, 0.1);
  return utilityAsset({ kind: "progress", fraction, foreground, background, opacity });
}

function progressMarkup({ fraction, foreground, background, opacity }) {
  const ring = `<circle cx="50" cy="50" r="40" fill="none" stroke-width="10"`;
  const track = fraction === 1 ? "" : `${ring} stroke="${background}" opacity="${opacity}"/>`;
  const completion = fraction === 0 ? "" : fraction === 1 ? `${ring} stroke="${foreground}"/>`
    : `${ring} stroke="${foreground}" pathLength="1" stroke-dasharray="${fraction} 1" transform="rotate(-90 50 50)"/>`;
  return track + completion;
}

function boundedText(text, maximumBytes) {
  const bytes = Buffer.from(text.toWellFormed().replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/g, ""));
  if (bytes.length <= maximumBytes) return bytes.toString();
  return bytes.subarray(0, maximumBytes).toString().replace(/\uFFFD$/, "");
}

function failureToastAction(api, error) {
  const stack = boundedText(error instanceof Error ? error.stack || error.message || "" : String(error), 1024);
  let feedback = { kind: "copyLogs", value: stack };
  if (!api.environment?.isDevelopment && typeof api.environment?.assetsPath === "string") {
    try {
      const manifest = JSON.parse(readFileSync(join(api.environment.assetsPath, "..", "package.json"), "utf8"));
      const owner = manifest.owner || manifest.author;
      const slug = /^[a-zA-Z0-9_.-]{1,128}$/;
      if ((!manifest.owner || manifest.access === "public") &&
          typeof owner === "string" && slug.test(owner) && typeof manifest.name === "string" && slug.test(manifest.name)) {
        const url = new URL("https://github.com/raycast/extensions/issues/new");
        url.searchParams.set("labels", "extension,bug");
        url.searchParams.set("template", "extension_bug_report.yml");
        const title = typeof manifest.title === "string" ? boundedText(manifest.title, 128) : "Extension Name";
        url.searchParams.set("title", `[${title}]...`);
        url.searchParams.set("extension-url", `https://raycast.com/${owner}/${manifest.name}`);
        url.searchParams.set("description", `#### Error:\n\`\`\`\n${stack}\n\`\`\`\n`);
        feedback = { kind: "reportError", value: url.href };
      }
    } catch {
      // Private or unavailable metadata uses the local clipboard action.
    }
  }
  return registerNativeToastAction({
    title: feedback.kind === "copyLogs" ? "Copy Logs" : "Report Error",
    async onAction(toast) {
      await toast.hide();
      if (feedback.kind === "copyLogs") await api.Clipboard.copy(feedback.value);
      else await api.open(feedback.value);
    },
  }, feedback);
}

function makeShowFailureToast(apiProvider) {
  return (error, options) => {
    const api = apiProvider();
    const message = error instanceof Error ? error.message : String(error);
    const title = options?.title ?? "Something went wrong";
    const action = failureToastAction(api, error);
    return api.showToast({
      style: api.Toast.Style.Failure,
      title,
      message: options?.message ?? boundedText(message, Math.max(0, 2048 - Buffer.byteLength(title))),
      primaryAction: options?.primaryAction ?? action,
      secondaryAction: options?.primaryAction ? action : undefined,
    });
  };
}

module.exports = { getAvatarIcon, getProgressIcon, describeUtilityIcon, makeShowFailureToast };
