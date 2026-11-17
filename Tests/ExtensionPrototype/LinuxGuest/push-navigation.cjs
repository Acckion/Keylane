const { checkedViewIDs } = require("./foundation-api.cjs");
const { checkedFormEvents } = require("./form-api.cjs");
const { checkedMenuRoute, effectReceipt } = require("./action-api.cjs");
const { AsyncLocalStorage } = require("node:async_hooks");

const maximumViewDepth = 4;
const routeModes = new Set(["action", "callback", "effect"]);
const viewTypes = new Set(["list", "detail", "grid", "form"]);

function validSearchInput(value) {
  return value === undefined || (typeof value === "string" && Buffer.byteLength(value) <= 256);
}

function checkedViewRoute(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > maximumViewDepth) throw new Error("Invalid view route depth");
  return value.map((frame) => {
    if (!frame || typeof frame !== "object" || Array.isArray(frame)) throw new Error("Invalid view route frame");
    const { query, dropdownValue, dropdownSelectionQuery, selectedItemId, pageCount, row, id, mode, lifecycleReceipt } = frame;
    if (!validSearchInput(query) || !validSearchInput(dropdownValue) || !validSearchInput(dropdownSelectionQuery) || !validSearchInput(selectedItemId) || !Number.isSafeInteger(row) || row < -1 ||
        (pageCount !== undefined && (!Number.isInteger(pageCount) || pageCount < 0 || pageCount > 8)) ||
        !Number.isInteger(id) || id < 0 || id >= 12 || !routeModes.has(mode)) {
      throw new Error("Invalid view route frame");
    }
    if (lifecycleReceipt !== undefined && (typeof lifecycleReceipt !== "string" || !/^[a-f0-9]{64}$/.test(lifecycleReceipt))) {
      throw new Error("Invalid navigation lifecycle receipt");
    }
    if (mode === "effect" && (row !== -1 || lifecycleReceipt === undefined ||
        frame.actionMenuRoute !== undefined || frame.formEvents !== undefined)) {
      throw new Error("Invalid effect navigation route");
    }
    const actionMenuRoute = checkedMenuRoute(frame.actionMenuRoute);
    const formEvents = checkedFormEvents(frame.formEvents);
    const viewIDs = checkedViewIDs(frame.viewIDs);
    return {
      query, dropdownValue, row, id, mode,
      ...(viewIDs.size && { viewIDs: [...viewIDs] }),
      ...(pageCount !== undefined && { pageCount }),
      ...(selectedItemId !== undefined && { selectedItemId }),
      ...(dropdownSelectionQuery !== undefined && { dropdownSelectionQuery }),
      ...(actionMenuRoute.length && { actionMenuRoute }),
      ...(formEvents.length && { formEvents }),
      ...(lifecycleReceipt !== undefined && { lifecycleReceipt }),
    };
  });
}

function checkedTarget(target) {
  if (!viewTypes.has(target?.type) || !target.props || typeof target.props !== "object") {
    throw new Error("Expected List, Detail, Grid or Form navigation target");
  }
  return target;
}

function pushActionComponent(component) {
  return component("push");
}

function lifecycleReceipt(selected) {
  if (selected?.type !== "push") return undefined;
  const { props } = selected;
  const onPush = typeof props.onPush === "function";
  const onPop = typeof props.onPop === "function";
  if (!onPush && !onPop) return undefined;
  const target = checkedTarget(props.target);
  return effectReceipt([target.type, target.props.navigationTitle, onPush, onPop], props);
}

function callbackReceipt(target, onPop) {
  if (onPop) return effectReceipt(["callback", target.type, target.props.navigationTitle], {});
}

function makePushNavigation(recordUserAction, resolveTarget = (target) => target) {
  const replayGrant = new AsyncLocalStorage();
  const effectScope = new AsyncLocalStorage();

  const navigation = Object.freeze({
    push(target, onPop) {
      target = checkedTarget(resolveTarget(target));
      if (onPop !== undefined && typeof onPop !== "function") throw new TypeError("Expected an onPop callback");
      const effect = effectScope.getStore();
      if (effect) {
        if (!effect.active) throw new Error("Navigation effect has ended");
        if (effect.enabled) {
          if (effect.page) throw new Error("Expected one navigation per view effect");
          effect.page = {
            target, onPop,
            receipt: effectReceipt(["effect", target.type, target.props.navigationTitle, Boolean(onPop)], {}),
          };
        }
        return;
      }
      const grant = replayGrant.getStore();
      if (grant) {
        if (!grant.active || grant.target) throw new Error("Expected one push while reconstructing a view route");
        grant.target = target;
        grant.onPop = onPop;
        return;
      }
      const receipt = callbackReceipt(target, onPop);
      recordUserAction({ kind: "pushView", routeMode: "callback", ...(receipt && { lifecycleReceipt: receipt }) }, "Navigation.push");
    },
    pop() {
      if (replayGrant.getStore()) throw new Error("Cannot pop while reconstructing a view route");
      recordUserAction({ kind: "popView" }, "Navigation.pop");
    },
  });

  return {
    useNavigation: () => navigation,
    async runEffect(effect, enabled) {
      const scope = { active: true, enabled, page: undefined };
      try {
        await effectScope.run(scope, effect);
        return scope.page;
      } finally {
        scope.active = false;
      }
    },
    begin(selected) {
      checkedTarget(selected.props.target);
      const receipt = lifecycleReceipt(selected);
      return { kind: "pushView", routeMode: "action", ...(receipt && { lifecycleReceipt: receipt }) };
    },
    async replay(selected, { mode, lifecycleReceipt: expectedReceipt }) {
      if (mode === "action" && selected?.type === "push") {
        if (expectedReceipt !== lifecycleReceipt(selected)) {
          throw new Error("Invalid navigation lifecycle receipt");
        }
        return { target: checkedTarget(selected.props.target), onPush: selected.props.onPush, onPop: selected.props.onPop };
      }
      if (mode !== "callback" || selected?.type !== "callback" || typeof selected.props.onAction !== "function") {
        throw new Error("Unknown view route action");
      }
      // The replay context grants only target capture. Host actions retain their separate selected-action grant.
      const grant = { active: true, target: undefined };
      try {
        await replayGrant.run(grant, () => selected.props.onAction());
        const target = checkedTarget(grant.target);
        if (expectedReceipt !== callbackReceipt(target, grant.onPop)) {
          throw new Error("Invalid navigation lifecycle receipt");
        }
        return { target, onPop: grant.onPop };
      } finally {
        grant.active = false;
      }
    },
  };
}

module.exports = { checkedViewRoute, lifecycleReceipt, makePushNavigation, maximumViewDepth, pushActionComponent };
