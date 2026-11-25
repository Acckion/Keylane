// First-party, deterministic probe for a mounted React renderer in JavaScriptCore.
const queued = new Map();
let timerID = 0;
globalThis.setTimeout = callback => {
  if (queued.size >= 128) throw new Error("Fixture timer budget exceeded");
  queued.set(++timerID, callback);
  return timerID;
};
globalThis.clearTimeout = id => queued.delete(id);

const React = require("react");
const reconcile = require("react-reconciler");
const { DiscreteEventPriority } = require("react-reconciler/constants");

const noop = () => {};
const context = Object.freeze({});
const create = (type, props) => ({ type, props, children: [] });
const remove = (parent, child) => {
  const index = parent.children.indexOf(child);
  if (index !== -1) parent.children.splice(index, 1);
};
const append = (parent, child) => {
  remove(parent, child);
  parent.children.push(child);
};
const insert = (parent, child, before) => {
  remove(parent, child);
  parent.children.splice(parent.children.indexOf(before), 0, child);
};
let priority = DiscreteEventPriority;
const renderer = reconcile({
  supportsMutation: true,
  supportsPersistence: false,
  supportsHydration: false,
  isPrimaryRenderer: true,
  getRootHostContext: () => context,
  getChildHostContext: () => context,
  getPublicInstance: node => node,
  prepareForCommit: () => null,
  resetAfterCommit: noop,
  preparePortalMount: noop,
  createInstance: create,
  createTextInstance: text => create("text", { text }),
  appendInitialChild: append,
  finalizeInitialChildren: () => false,
  shouldSetTextContent: () => false,
  scheduleTimeout: globalThis.setTimeout,
  cancelTimeout: globalThis.clearTimeout,
  noTimeout: -1,
  appendChild: append,
  appendChildToContainer: append,
  insertBefore: insert,
  insertInContainerBefore: insert,
  removeChild: remove,
  removeChildFromContainer: remove,
  clearContainer: target => { target.children.length = 0; },
  commitUpdate: (node, _type, _oldProps, props) => { node.props = props; },
  commitTextUpdate: (node, _oldText, text) => { node.props.text = text; },
  detachDeletedInstance: noop,
  setCurrentUpdatePriority: level => { priority = level; },
  getCurrentUpdatePriority: () => priority,
  resolveUpdatePriority: () => priority || DiscreteEventPriority,
  trackSchedulerEvent: noop,
  resolveEventType: () => null,
  resolveEventTimeStamp: () => Date.now(),
  shouldAttemptEagerTransition: () => false,
  maySuspendCommit: () => false,
});
const tree = create("root", {});
const report = error => { throw error; };
const root = renderer.createContainer(tree, 1, null, false, null, "keylane-fixture", report, report, report, noop);
const h = React.createElement;

let capturedID;
function Command() {
  const [count, setCount] = React.useState(0);
  const id = React.useId();
  if (capturedID !== undefined && capturedID !== id) throw new Error("React remounted the component");
  capturedID = id;
  return h("detail", { markdown: "count:" + count },
    h("submenu", { id: "counter", title: "Counter", style: "regular" },
      h("action", { id: "increment", title: "Increment", style: "regular", onAction: () => setCount(n => n + 1) })));
}

function describeAction({ type, props: { id, title, style }, children }) {
  return { id, title, style, children: type === "submenu" ? children.map(describeAction) : undefined };
}

function snapshot() {
  const page = tree.children[0];
  return { markdown: page.props.markdown, actions: page.children.map(describeAction) };
}

exports.default = () => {
  renderer.updateContainerSync(h(Command), root, null);
  renderer.flushSyncWork();
  return snapshot();
};
exports.onEvent = async event => {
  await Promise.resolve();
  const submenu = tree.children[0].children.find(node => node.type === "submenu");
  const action = submenu?.children.find(node => node.props.id === event.actionID);
  if (event.kind !== "action" || !action) throw new Error("Invalid React fixture event");
  renderer.flushSyncFromReconciler(action.props.onAction);
  return snapshot();
};
