const { checkedFormEvents } = require("./form-api.cjs");
const { checkedMenuRoute, effectReceipt } = require("./action-api.cjs");
const { AsyncLocalStorage } = require("node:async_hooks");

const maximumViewDepth = 4;
const routeModes = new Set(["action", "callback"]);
const viewTypes = new Set(["list", "detail", "grid", "form"]);

function validSearchInput(value) {
  return value === undefined || (typeof value === "string" && Buffer.byteLength(value) <= 256);
}

function checkedViewRoute(value) {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > maximumViewDepth) throw new Error("Invalid view route depth");
  return value.map((frame) => {
    if (!frame || typeof frame !== "object" || Array.isArray(frame)) throw new Error("Invalid view route frame");
    const { query, dropdownValue, dropdownSelectionQuery, selectedItemId, row, id, mode, lifecycleReceipt } = frame;
    if (!validSearchInput(query) || !validSearchInput(dropdownValue) || !validSearchInput(dropdownSelectionQuery) || !validSearchInput(selectedItemId) || !Number.isSafeInteger(row) || row < -1 ||
        !Number.isInteger(id) || id < 0 || id >= 12 || !routeModes.has(mode)) {
      throw new Error("Invalid view route frame");
    }
    if (lifecycleReceipt !== undefined && (mode !== "action" ||
        typeof lifecycleReceipt !== "string" || !/^[a-f0-9]{64}$/.test(lifecycleReceipt))) {
      throw new Error("Invalid navigation lifecycle receipt");
    }
    const actionMenuRoute = checkedMenuRoute(frame.actionMenuRoute);
    const formEvents = checkedFormEvents(frame.formEvents);
    return {
      query, dropdownValue, row, id, mode,
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

function makePushNavigation(recordUserAction) {
  const replayGrant = new AsyncLocalStorage();

  const navigation = Object.freeze({
    push(target) {
      target = checkedTarget(target);
      const grant = replayGrant.getStore();
      if (grant) {
        if (!grant.active || grant.target) throw new Error("Expected one push while reconstructing a view route");
        grant.target = target;
        return;
      }
      recordUserAction({ kind: "pushView", routeMode: "callback" }, "Navigation.push");
    },
    pop() {
      if (replayGrant.getStore()) throw new Error("Cannot pop while reconstructing a view route");
      recordUserAction({ kind: "popView" }, "Navigation.pop");
    },
  });

  return {
    useNavigation: () => navigation,
    begin(selected) {
      checkedTarget(selected.props.target);
      const receipt = lifecycleReceipt(selected);
      return { kind: "pushView", routeMode: "action", ...(receipt && { lifecycleReceipt: receipt }) };
    },
    async replay(selected, mode) {
      if (mode === "action" && selected?.type === "push") return checkedTarget(selected.props.target);
      if (mode !== "callback" || selected?.type !== "callback" || typeof selected.props.onAction !== "function") {
        throw new Error("Unknown view route action");
      }
      // The replay context grants only target capture. Host actions retain their separate selected-action grant.
      const grant = { active: true, target: undefined };
      try {
        await replayGrant.run(grant, () => selected.props.onAction());
        return checkedTarget(grant.target);
      } finally {
        grant.active = false;
      }
    },
  };
}

module.exports = { checkedViewRoute, lifecycleReceipt, makePushNavigation, maximumViewDepth, pushActionComponent };
