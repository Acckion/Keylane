import Foundation

/// App-owned import adapter for reviewed no-view Raycast commands.
/// Every effect still goes through the signed runner and its capability ticket.
package enum MacOSReviewedRaycastAPI {
    package static let files: [RaycastStoreBuildProject.File] = [
        .init(path: "node_modules/@raycast/api/package.json",
              body: Data(#"{"name":"@raycast/api","type":"module","main":"index.js"}"#.utf8)),
        .init(path: "node_modules/@raycast/api/index.js", body: Data(([MacOSReviewedRaycastValues.source, source].joined(separator: "\n")).utf8)),
        .init(path: "node_modules/@raycast/utils/package.json",
              body: Data(#"{"name":"@raycast/utils","type":"module","main":"index.js"}"#.utf8)),
        .init(path: "node_modules/@raycast/utils/index.js", body: Data(utilsSource.utf8))
    ]

    private static let utilsSource = #"""
    import { Color, environment, showToast, ToastStyle } from "@raycast/api";

    export const FormValidation = Object.freeze({ Required: "required" });

    function base64URL(bytes) {
      const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
      let encoded = "";
      for (let index = 0; index < bytes.length; index += 3) {
        const first = bytes[index], second = bytes[index + 1] ?? 0, third = bytes[index + 2] ?? 0;
        encoded += alphabet[first >> 2] + alphabet[((first & 3) << 4) | (second >> 4)];
        if (index + 1 < bytes.length) encoded += alphabet[((second & 15) << 2) | (third >> 6)];
        if (index + 2 < bytes.length) encoded += alphabet[third & 63];
      }
      return encoded;
    }

    const palette = ["#965575", "#9a473d", "#9a682c", "#537a40", "#217c73", "#416da2", "#655cab", "#8353a1"];
    const standardColors = new Map([
      ["raycast-blue", "#4387f5"], ["raycast-green", "#43ad65"], ["raycast-magenta", "#d84fc5"],
      ["raycast-orange", "#f28a32"], ["raycast-purple", "#9661dc"], ["raycast-red", "#ff6363"],
      ["raycast-yellow", "#f4bc36"], ["black", "#000000"], ["white", "#ffffff"],
    ]);

    const imagePrefix = "data:image/svg+xml,";
    const graphemes = typeof Intl.Segmenter === "function"
      ? new Intl.Segmenter(undefined, { granularity: "grapheme" }) : undefined;

    function utilityAsset(descriptor) {
      const payload = base64URL(new TextEncoder().encode(JSON.stringify(descriptor)));
      const body = descriptor.kind === "avatar" ? avatarMarkup(descriptor) : progressMarkup(descriptor);
      return imagePrefix + encodeURIComponent(
        `<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100" viewBox="0 0 100 100" data-keylane-icon="${payload}">${body}</svg>`,
      );
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
      const first = graphemes?.segment(word)[Symbol.iterator]().next().value?.segment ?? ([...word][0] ?? "");
      const initial = first.toUpperCase().replace(/\p{Cc}/gu, "");
      // Keep the complete initial within the native descriptor's two-initial budget.
      return new TextEncoder().encode(initial).length <= 16 ? initial : ([...initial][0] ?? "");
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

    export function getAvatarIcon(name, options = {}) {
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

    export function getProgressIcon(progress, color, options = {}) {
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

    export function showFailureToast(error, options) {
      const title = options?.title ?? "Something went wrong";
      let message = options?.message;
      if (message === undefined && typeof title === "string") {
        const encoder = new TextEncoder();
        let remainingBytes = 2048 - encoder.encode(title).length;
        message = "";
        for (const character of error instanceof Error ? error.message : String(error)) {
          remainingBytes -= encoder.encode(character).length;
          if (remainingBytes < 0) break;
          message += character;
        }
      }
      return showToast({ title, message, style: ToastStyle.Failure, primaryAction: options?.primaryAction });
    }

    export const DeeplinkType = Object.freeze({ ScriptCommand: "script-command", Extension: "extension" });

    function raycastURL(path) {
      return `raycast://${path}`;
    }

    export function createScriptCommandDeeplink({ command, arguments: args }) {
      const url = raycastURL(`script-commands/${command}`);
      if (!args) return url;

      // Script commands take repeated arguments in the same order as the inputs.
      return `${url}?${args.map((arg) => `arguments=${encodeURIComponent(arg)}`).join("&")}`;
    }

    export function createExtensionDeeplink(options) {
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

    export function createDeeplink(options) {
      return options.type === "script-command"
        ? createScriptCommandDeeplink(options)
        : createExtensionDeeplink(options);
    }
    """#

    private static let source = #"""
    export const ToastStyle = Object.freeze({ Success: "SUCCESS", Failure: "FAILURE", Animated: "ANIMATED" });

    const invocation = globalThis.keylane.environment;
    export const environment = Object.freeze({
      ownerOrAuthorName: invocation.ownerOrAuthorName,
      extensionName: invocation.extensionName,
      entryPointName: invocation.entryPointName,
      entryPointType: "command",
      entryPointMode: "no-view",
      commandName: invocation.entryPointName,
      commandMode: "no-view",
      appearance: invocation.appearance,
      theme: invocation.appearance,
      textSize: invocation.textSize,
      launchType: LaunchType.UserInitiated,
      isDevelopment: false,
      // This field describes the running host, independently of the SDK version.
      raycastVersion: invocation.raycastVersion ?? "0.0.0",
      canAccess(api) {
        if (api === Clipboard.copy || api === copyTextToClipboard) return typeof globalThis.keylane.copy === "function";
        if (api === showHUD || api === showToast || api === Toast) return typeof globalThis.keylane.toast === "function";
        if (api === clearSearchBar) return typeof globalThis.keylane.clearSearch === "function";
        if (api === popToRoot) return typeof globalThis.keylane.popToRoot === "function";
        if (api === closeMainWindow) return typeof globalThis.keylane.closeWindow === "function";
        return false;
      },
    });

    let nextToastID = 1;
    let visibleToast;

    export function getPreferenceValues() {
      return globalThis.keylane.preferences;
    }

    export const Clipboard = Object.freeze({
      async copy(text, options) {
        if (typeof text !== "string" || options !== undefined || !globalThis.keylane.copy?.(text)) {
          throw new Error("Clipboard copy is unavailable");
        }
      },
      async paste() {
        throw new Error("Clipboard paste is unavailable");
      }
    });

    export const copyTextToClipboard = Clipboard.copy;

    export async function getSelectedText() {
      throw new Error("Reading text from other apps is unavailable");
    }

    function toastOptions(options) {
      const { title, message, style = ToastStyle.Success, primaryAction, secondaryAction } = options ?? {};
      if (primaryAction !== undefined || secondaryAction !== undefined) {
        throw new TypeError("Toast actions are unavailable");
      }
      if (typeof title !== "string" || (message !== undefined && typeof message !== "string")
          || !Object.values(ToastStyle).includes(style)) {
        throw new TypeError("Invalid toast options");
      }
      if (new TextEncoder().encode(title).length + new TextEncoder().encode(message ?? "").length > 2048) {
        throw new RangeError("Toast text exceeds the feedback limit");
      }
      return { title, message, style };
    }

    function emitToast(event) {
      if (!globalThis.keylane.toast?.(JSON.stringify(event))) throw new Error("Toast is unavailable");
    }

    export class Toast {
      #id;
      #options;

      static get Style() { return ToastStyle; }

      constructor(options) {
        this.#options = toastOptions(options);
      }

      get title() { return this.#options.title; }
      set title(value) { this.#set("title", value); }

      get message() { return this.#options.message; }
      set message(value) { this.#set("message", value); }

      get style() { return this.#options.style; }
      set style(value) { this.#set("style", value); }

      #set(key, value) {
        if (this.#options[key] === value) return;
        const options = toastOptions({ ...this.#options, [key]: value });
        if (visibleToast === this) emitToast({ operation: "update", id: this.#id, ...options });
        this.#options = options;
      }

      async show() {
        const id = nextToastID++;
        emitToast({ operation: "show", id, ...this.#options });
        this.#id = id;
        visibleToast = this;
      }

      async hide() {
        if (visibleToast !== this) return;
        emitToast({ operation: "hide", id: this.#id });
        visibleToast = undefined;
      }
    }

    export async function showToast(options, legacyTitle, legacyMessage) {
      const toast = new Toast(typeof options === "string"
        ? { style: options, title: legacyTitle, message: legacyMessage } : options);
      await toast.show();
      return toast;
    }

    function closeOptions(options) {
      if (options !== undefined && (options === null || typeof options !== "object" || Array.isArray(options))) {
        throw new Error("Invalid closeMainWindow options");
      }
      const fields = options ?? {};
      const { clearRootSearch = false, popToRootType = PopToRootType.Default } = fields;
      if (Object.keys(fields).some(key => key !== "clearRootSearch" && key !== "popToRootType")
          || typeof clearRootSearch !== "boolean" || !Object.values(PopToRootType).includes(popToRootType)) {
        throw new Error("Unsupported closeMainWindow options");
      }
      return { clearRootSearch, popToRootType };
    }

    export async function closeMainWindow(options) {
      const { clearRootSearch, popToRootType } = closeOptions(options);
      // Keep the version-one boolean representation for default behavior.
      const payload = popToRootType === PopToRootType.Default
        ? String(clearRootSearch) : popToRootType + ":" + clearRootSearch;
      if (!globalThis.keylane.closeWindow?.(payload)) {
        throw new Error("Closing the main window is unavailable");
      }
    }

    function navigationFlag(options, field, fallback) {
      if (options === undefined) return fallback;
      if (options === null || typeof options !== "object" || Array.isArray(options)
          || Object.keys(options).some(key => key !== field)
          || (options[field] !== undefined && typeof options[field] !== "boolean")) {
        throw new TypeError("Invalid navigation options");
      }
      return options[field] ?? fallback;
    }

    export async function clearSearchBar(options) {
      const scroll = navigationFlag(options, "forceScrollToTop", true);
      if (!globalThis.keylane.clearSearch?.(String(scroll))) throw new Error("Clearing search is unavailable");
    }

    export async function popToRoot(options) {
      const clear = navigationFlag(options, "clearSearchBar", false);
      if (!globalThis.keylane.popToRoot?.(String(clear))) throw new Error("Returning to root is unavailable");
    }

    export async function showHUD(title, options) {
      const clearRootSearch = navigationFlag(options, "clearRootSearch", false);
      const presentation = toastOptions({ title });
      if (clearRootSearch) {
        if (!environment.canAccess(showHUD) || !environment.canAccess(closeMainWindow)) {
          throw new Error("HUD cannot clear the root search");
        }
        await closeMainWindow({ clearRootSearch });
      }
      await showToast(presentation);
    }
    """#
}
