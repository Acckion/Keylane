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

function makeNavigation(emit) {
  return {
    async closeMainWindow(options) {
      options = checkedOptions(options);
      const clearRootSearch = flag(options, "clearRootSearch", false);
      const type = options.popToRootType;
      const popToRootType = type === undefined ? PopToRootType.Default : type;
      if (!popToRootTypes.has(popToRootType)) throw new TypeError("Invalid popToRootType");
      await emit({ kind: "closeMainWindow", clearRootSearch, popToRootType });
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

module.exports = { makeNavigation, PopToRootType };
