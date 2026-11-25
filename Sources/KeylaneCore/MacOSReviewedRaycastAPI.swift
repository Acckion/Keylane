import Foundation

/// App-owned import adapter for reviewed no-view Raycast commands.
/// Every effect still goes through the signed runner and its capability ticket.
package enum MacOSReviewedRaycastAPI {
    package static let files: [RaycastStoreBuildProject.File] = [
        .init(path: "node_modules/@raycast/api/package.json",
              body: Data(#"{"name":"@raycast/api","type":"module","main":"index.js"}"#.utf8)),
        .init(path: "node_modules/@raycast/api/index.js", body: Data(source.utf8))
    ]

    private static let source = #"""
    export const ToastStyle = Object.freeze({ Success: "SUCCESS", Failure: "FAILURE", Animated: "ANIMATED" });

    const LaunchType = Object.freeze({ UserInitiated: "userInitiated" });
    const PopToRootType = Object.freeze({ Default: "default", Immediate: "immediate", Suspended: "suspended" });

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
