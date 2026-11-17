const PopToRootType = Object.freeze({
  Default: "default",
  Immediate: "immediate",
  Suspended: "suspended",
});

const popToRootTypes = new Set(Object.values(PopToRootType));

function checkedOptions(options) {
  if (options === undefined) return {};
  if (options === null || typeof options !== "object" || Array.isArray(options)) {
    throw new TypeError("Expected navigation options");
  }
  return options;
}

function flag(options, name, fallback) {
  const value = options[name];
  if (value === undefined) return fallback;
  if (typeof value !== "boolean") throw new TypeError(`${name} must be a boolean`);
  return value;
}

function checkedCloseOptions(options) {
  options = checkedOptions(options);
  const clearRootSearch = flag(options, "clearRootSearch", false);
  const { popToRootType = PopToRootType.Default } = options;
  if (!popToRootTypes.has(popToRootType)) throw new TypeError("Invalid popToRootType");
  return { clearRootSearch, popToRootType };
}

function makeNavigation(emit) {
  return {
    async closeMainWindow(options) {
      await emit({ kind: "closeMainWindow", ...checkedCloseOptions(options) });
    },

    async showHUD(text, options) {
      if (typeof text !== "string") throw new TypeError("Expected a HUD title");
      if (Buffer.byteLength(text) > 2048) throw new RangeError("HUD title exceeds the feedback limit");
      await emit({ kind: "hud", text, ...checkedCloseOptions(options) });
    },

    async clearSearchBar(options) {
      options = checkedOptions(options);
      const forceScrollToTop = flag(options, "forceScrollToTop", true);
      await emit({ kind: "clearSearchBar", forceScrollToTop });
    },

    async popToRoot(options) {
      options = checkedOptions(options);
      const clearSearchBar = flag(options, "clearSearchBar", false);
      await emit({ kind: "popToRoot", clearSearchBar });
    },
  };
}

const navigationCapabilities = Object.freeze({
  closeMainWindow: "navigation.closeWindow",
  popToRoot: "navigation.popToRoot",
  clearSearchBar: "navigation.clearSearch",
  hud: "feedback.hud",
});

function requestNavigation(request, { kind, ...options }) {
  return request(navigationCapabilities[kind], JSON.stringify(options));
}

module.exports = { makeNavigation, PopToRootType, requestNavigation };
