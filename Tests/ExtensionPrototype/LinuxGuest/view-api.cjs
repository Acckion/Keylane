const { describeImage } = require("./image-api.cjs");
const { clipboardEffect } = require("./clipboard-write.cjs");
// Compatibility surface for the reviewed views and UUID commands.
const { environment, LaunchType, registerEnvironmentCapability } = require("./environment.cjs");
const { makeToastAdapter } = require("./toast.cjs");
const { menuBarComponents, describeMenu } = require("./menu-bar.cjs");
const { gridComponents, gridNodes, describeGrid } = require("./grid-api.cjs");
const { formComponents, describeForm, hasPasswordField, submitForm, checkedFormEvents, replayFormEvent, mountFormRefs, rememberDropdownOptions } = require("./form-api.cjs");
const { listNodes, listText } = require("./list-api.cjs");
const {
  ActionStyle, actionPanelComponents, describeActions, findAction, actionPanelTitle,
  checkedMenuRoute, replayActionMenu, submenuOptions, effectReceipt,
} = require("./action-api.cjs");
const { dropdownComponent, describeDropdown, applyDropdownSelection, dropdownSearchHandler, restoredDropdownValue } = require("./dropdown-api.cjs");
const { AsyncLocalStorage } = require("node:async_hooks");
const { makeOpen, openActionComponents, openActionEffect, webURL } = require("./open-api.cjs");
const { finderRevealComponent, finderRevealEffect, makeShowInFinder } = require("./finder-reveal.cjs");
const { trashComponent, trashEffect, makeTrash } = require("./trash-action.cjs");
const { makeClipboardReaders } = require("./clipboard-read.cjs");
const { makeWindowManagement } = require("./window-management.cjs");
const { quickLookComponent, quickLookEffect } = require("./quick-look-action.cjs");
const { openWithComponent, openWithEffect, makeClearClipboard } = require("./open-with-clipboard.cjs");
const { makeNavigation, PopToRootType } = require("./navigation-api.cjs");
const { creationActionComponents, creationActionEffect, makeOpenExtensionPreferences } = require("./create-actions.cjs");
const { pickDateComponent, describePickDate, submitPickDate } = require("./date-action.cjs");
const { listMetadataComponents, describeListMetadata, metadataTagCallback } = require("./list-metadata.cjs");
const { describeUtilityIcon } = require("./utilities-visual-feedback.cjs");
const { captureException, captureMemorySnapshot } = require("./diagnostics-api.cjs");

const { Alert, AlertActionStyle, makePreferences, randomId, viewID, specialKeys } = require("./foundation-api.cjs");
const { Cache, configureCache, setCacheWritesAllowed, takeCacheSnapshot, withCacheWritesBlocked, withCurrentViewInput, withCacheWriteLifetime } = require("./cache-api.cjs");
const { makePushNavigation, pushActionComponent, checkedViewRoute, lifecycleReceipt } = require("./push-navigation.cjs");

const { makeApplicationQueries } = require("./applications-api.cjs");
const applicationQueries = makeApplicationQueries((capability, text) => require("./raycast-api.cjs").request(capability, text));

const userViewAction = new AsyncLocalStorage();
const routeReplay = new AsyncLocalStorage();
const actionPanelUpdates = new AsyncLocalStorage();
const { Color, Icon, Image, ImageMask, Keyboard, iconTint } = require("./presentation-values.cjs");
const { makeBrokerLocalStorage } = require("./broker-local-storage.cjs");
const { localStorageAliases, clipboardAliases } = require("./storage-compat.cjs");

let actionResult;
let feedback;
let visibleToast;
let preferenceValues;
let preferenceDefinitions;
let preparedInput;
let storage;
let storageChanged;
let localStorageAllowed;
let confirmed;
let state;
let stateIndex;
let effects;
let replayingViewInput;
let capturesActionQuery;
let clipboardReadAllowed;
let windowReadAllowed;

function prepareInput(input) {
  preparedInput = input;
  preferenceValues = input.preferences ?? {};
  preferenceDefinitions = input.preferenceDefinitions;
  configureCache(input.sensitiveFormSubmission ? undefined : input.cache);
}

function configure(input) {
  if (preparedInput !== input) prepareInput(input);
  preparedInput = undefined;
  actionResult = undefined;
  feedback = undefined;
  visibleToast = undefined;
  storage = input.storage === undefined || input.sensitiveFormSubmission ? undefined : Object.assign(Object.create(null), input.storage);
  localStorageAllowed = input.localStorageAllowed === true && !input.sensitiveFormSubmission;
  storageChanged = false;
  confirmed = input.confirmed === true;
  clipboardReadAllowed = input.clipboardReadAllowed === true && input.sensitiveFormSubmission !== true;
  windowReadAllowed = input.windowReadAllowed === true && input.sensitiveFormSubmission !== true;
  state = [];
  stateIndex = 0;
  effects = [];
  replayingViewInput = false;
  capturesActionQuery = false;
}

function jsx(type, props, key) {
  const element = typeof type === "function" ? type(props) : { type, props };
  return key !== undefined && element?.props ? { ...element, key: String(key) } : element;
}

function useState(initial) {
  const index = stateIndex++;
  const frameState = state;
  if (!(index in frameState)) frameState[index] = typeof initial === "function" ? initial() : initial;
  return [frameState[index], (value) => {
    const next = typeof value === "function" ? value(frameState[index]) : value;
    frameState[index] = next;
    if (!routeReplay.getStore() && frameState === state && capturesActionQuery && (!actionResult || actionResult.kind === "query") && typeof next === "string") actionResult = { kind: "query", text: next };
  }];
}

function useRef(initial) {
  return useState(() => ({ current: initial }))[0];
}

function useEffect(effect, dependencies) {
  const [slot] = useState(() => ({ ran: false, dependencies: undefined }));
  if (!effects || (routeReplay.getStore() && !replayingViewInput)) return;
  if (slot.ran && (dependencies === undefined ||
      (slot.dependencies?.length === dependencies.length &&
       dependencies.every((value, index) => Object.is(value, slot.dependencies[index]))))) return;
  effects.push(() => {
    slot.ran = true;
    slot.dependencies = dependencies;
    return effect();
  });
}

function component(name) {
  return (props) => jsx(name, props);
}

const Label = component("label");
const Metadata = Object.assign(component("metadata"), {
  Label, Separator: component("separator"), ...listMetadataComponents(component),
});
const Detail = Object.assign(component("detail"), { Metadata });
const Item = Object.assign(component("item"), { Detail: Object.assign(component("itemDetail"), { Metadata }) });
const Dropdown = dropdownComponent(component);
const List = Object.assign(component("list"), {
  Item, Section: component("section"), EmptyView: component("listEmpty"), Dropdown,
});
const Form = formComponents(component);
Object.assign(Form, {
  DropdownItem: Form.Dropdown.Item,
  DropdownSection: Form.Dropdown.Section,
  TagPickerItem: Form.TagPicker.Item,
});
const ActionPanel = actionPanelComponents(component);

const pasteComponent = component("paste");
const copyComponent = component("copy");
const submitFormComponent = component("submitForm");
const OpenWithAction = openWithComponent(component);
const Action = Object.assign(component("callback"), {
  ...openActionComponents(component),
  ...creationActionComponents(component),
  CopyToClipboard: (props) => copyComponent({ ...props, title: props?.title ?? "Copy to Clipboard", icon: props?.icon ?? Icon.Clipboard }),
  ShowInFinder: finderRevealComponent(component),
  OpenWith: OpenWithAction,
  ToggleQuickLook: quickLookComponent(component),
  Trash: trashComponent(component),
  Paste: (props) => pasteComponent({ title: "Paste in Active App", ...props }),
  PickDate: pickDateComponent(component),
  Push: pushActionComponent(component),
  SubmitForm: (props) => submitFormComponent({ ...props, title: props?.title ?? "Submit Form" }),
  Style: ActionStyle,
});
ActionPanel.Item = Action;
const MenuBarExtra = menuBarComponents(component);
const Grid = Object.assign(gridComponents(component), { Dropdown });

function children(node) {
  return [node?.props.children].flat(Infinity).filter(Boolean);
}

function clipboardResult(kind, content, options) {
  if (routeReplay.getStore() || replayingViewInput || actionResult) throw new Error("Clipboard action unavailable");
  const grant = userViewAction.getStore();
  if (grant !== undefined) {
    if (!grant.active || !grant.allowsFileEffects) throw new Error("Clipboard action unavailable");
    actionResult = clipboardEffect(kind, content, options);
    return;
  }
  // The reviewed UUID commands have a separate host contract and still emit plain text.
  if (storage === undefined || typeof content !== "string" || options !== undefined) throw new Error("Clipboard action unavailable");
  actionResult = { kind, text: content };
}

function storageScope() {
  if (storage === undefined) throw new Error("LocalStorage unavailable");
  return storage;
}

function checkStorageWrite() {
  if (routeReplay.getStore() || replayingViewInput) throw new Error("LocalStorage writes are unavailable while reconstructing view inputs");
  const grant = userViewAction.getStore();
  if (grant?.lifecycle && !grant.active) throw new Error("Navigation callback has ended");
}

const brokerStorage = makeBrokerLocalStorage((capability, text) => require("./raycast-api.cjs").request(capability, text));

async function brokerStorageWrite(operation, ...args) {
  const result = await brokerStorage[operation](...args);
  const grant = userViewAction.getStore();
  if (grant?.active) grant.didWriteStorage = true;
  return result;
}

const LocalStorage = {
  getItem: async (key) => localStorageAllowed ? brokerStorage.getItem(key) : storageScope()[key],
  setItem: async (key, value) => {
    checkStorageWrite();
    if (localStorageAllowed) return brokerStorageWrite("setItem", key, value);
    if (typeof key !== "string" || key.length > 128 ||
        !["string", "boolean", "number"].includes(typeof value)) throw new Error("Invalid LocalStorage item");
    storageScope()[key] = value;
    storageChanged = true;
  },
  removeItem: async (key) => {
    checkStorageWrite();
    if (localStorageAllowed) return brokerStorageWrite("removeItem", key);
    delete storageScope()[key];
    storageChanged = true;
  },
  allItems: async () => localStorageAllowed ? brokerStorage.allItems() : ({ ...storageScope() }),
  clear: async () => {
    checkStorageWrite();
    if (localStorageAllowed) return brokerStorageWrite("clear");
    storageScope();
    storage = Object.create(null);
    storageChanged = true;
  },
};

function finish(result) {
  return storageChanged ? { ...result, storage } : result;
}

function useActionPanel() {
  const scope = actionPanelUpdates.getStore();
  if (!scope?.active) throw new Error("useActionPanel requires a view render");
  return {
    update(panel) {
      if (!scope.active) throw new Error("Action panel updates require an active view render");
      if (panel != null && panel !== false && panel.type !== "actions") {
        throw new TypeError("Expected an ActionPanel");
      }
      scope.panel = panel || null;
    },
  };
}

function resolvedPanel(override, panel) {
  return override === undefined ? panel : override;
}

function actionDescriptions(panel) {
  return describeActions(panel, children);
}

function detailDescription({ markdown, navigationTitle, isLoading, metadata, actions: panel }, override) {
  const actions = resolvedPanel(override, panel);
  const title = actionPanelTitle(actions);
  return {
    markdown, navigationTitle, isLoading,
    metadata: describeListMetadata(metadata, children, webURL, { includeLabelsOnly: true }),
    ...(title !== undefined && { actionPanelTitle: title }),
    actions: actionDescriptions(actions),
  };
}

function recordUserAction(effect, name) {
  const grant = userViewAction.getStore();
  if (!grant?.active || grant.lifecycle || actionResult) throw new Error(`${name} requires a selected view action`);
  actionResult = effect;
}

const open = makeOpen((effect) => {
  if (!userViewAction.getStore()?.allowsOpen) throw new Error("Open requires a selected view action");
  recordUserAction(effect, "Open");
});
function recordFileEffect(effect) {
  if (!userViewAction.getStore()?.allowsFileEffects) throw new Error("File and clipboard changes require a selected view action");
  recordUserAction(effect, effect.kind);
}

const showInFinder = makeShowInFinder(recordFileEffect);
const trash = makeTrash(recordFileEffect);
const viewNavigation = makePushNavigation((effect, name) => {
  if (!userViewAction.getStore()?.allowsPushNavigation) throw new Error(`${name} requires a selected view action`);
  recordUserAction(effect, name);
});
const navigation = makeNavigation((effect) => recordUserAction(effect, effect.kind));
const openExtensionPreferences = makeOpenExtensionPreferences((effect) => recordUserAction(effect, effect.kind));

async function invokeViewAction(panel, id, allowEmptyResult, input, form, quickLook) {
  const selected = findAction(panel, id, children);
  const isPickDate = selected?.type === "pickDate";
  const hasPickedDate = Object.hasOwn(input, "pickedDate");
  if ((input.dateReceipt !== undefined || hasPickedDate) && !isPickDate) throw new Error("Invalid date selection receipt");
  if (input.copyReceipt !== undefined && selected?.type !== "copy") throw new Error("Invalid clipboard completion receipt");
  const revealsFile = selected?.type === "showInFinder";
  const trashesFiles = selected?.type === "trashFiles";
  const opensWithApplication = selected?.type === "openWith";
  let completedFileAction;
  const hasFileAction = revealsFile || trashesFiles || opensWithApplication;
  if (input.fileReceipt !== undefined && !hasFileAction) {
    throw new Error("Invalid file completion receipt");
  }
  if (hasFileAction) {
    const { props } = selected;
    const target = trashesFiles ? props.paths : props.path;
    const effect = trashesFiles ? trashEffect(target)
      : revealsFile ? finderRevealEffect(target) : openWithEffect(target);
    const callback = trashesFiles ? props.onTrash : revealsFile ? props.onShow : props.onOpen;
    const receipt = `${selected.type}:${effectReceipt([effect, target], props)}`;
    if (input.fileReceipt === undefined) {
      return typeof callback === "function" ? { ...effect, fileReceipt: receipt } : effect;
    }
    if (typeof callback !== "function" || input.fileReceipt !== receipt) {
      throw new Error("Invalid file completion receipt");
    }
    completedFileAction = () => callback(target);
  }
  const opens = selected?.type === "open" || selected?.type === "openInBrowser";
  let completedOpen;
  if (input.openReceipt !== undefined && !opens) throw new Error("Invalid open completion receipt");
  if (opens) {
    const { props } = selected;
    const effect = openActionEffect(selected);
    const callback = props.onOpen;
    const target = selected.type === "openInBrowser" ? props.url : props.target;
    const receipt = effectReceipt([selected.type, effect, target], props);
    if (input.openReceipt === undefined) {
      return typeof callback === "function" ? { ...effect, openReceipt: receipt } : effect;
    }
    if (typeof callback !== "function" || input.openReceipt !== receipt) {
      throw new Error("Invalid open completion receipt");
    }
    completedOpen = () => callback(target);
  }
  if (selected?.type === "toggleQuickLook") return quickLookEffect(quickLook);
  if (selected?.type === "push") return viewNavigation.begin(selected);
  if (selected?.type === "createQuicklink" || selected?.type === "createSnippet") {
    return creationActionEffect(selected);
  }
  if (selected?.type === "paste") {
    return clipboardEffect("paste", selected.props.content);
  }
  const isCopyCallback = selected?.type === "copy" && input.copyReceipt !== undefined;
  if (selected?.type === "copy") {
    const { content, concealed, transient, onCopy } = selected.props;
    const effect = clipboardEffect("copy", content, { concealed: concealed ?? transient });
    const receipt = effectReceipt([effect, content], selected.props);
    if (!isCopyCallback) {
      return typeof onCopy === "function" ? { ...effect, copyReceipt: receipt } : effect;
    }
    if (typeof onCopy !== "function" || input.copyReceipt !== receipt) {
      throw new Error("Invalid clipboard completion receipt");
    }
  }
  if (isPickDate) {
    const effect = describePickDate(selected);
    const receipt = effectReceipt(effect, selected.props);
    if (!hasPickedDate && input.dateReceipt === undefined) return { ...effect, dateReceipt: receipt };
    if (!hasPickedDate || input.dateReceipt !== receipt) throw new Error("Invalid date selection receipt");
  }
  const isSubmit = selected?.type === "submitForm" && form;
  const isCallback = selected?.type === "callback" || isCopyCallback || Boolean(completedOpen || completedFileAction);
  if (!isSubmit && !isCallback && !isPickDate) throw new Error("Unknown action");
  if (isSubmit && hasPasswordField(form.root, children)) {
    // Passwords travel only into the selected callback. No effects or extension error text leave it.
    replayingViewInput = true;
    setCacheWritesAllowed(false);
    try {
      const accepted = await submitForm(form.root, children, selected, form.values, input.formEvents, form.dropdownContext);
      await flushToastUpdates();
      if (feedback?.kind === "error") return { kind: "error" };
      return { kind: accepted === false ? "formRejected" : "action" };
    } catch {
      return { kind: "error" };
    } finally {
      replayingViewInput = false;
    }
  }
  const grant = {
    active: true,
    allowsOpen: (isCallback && !completedFileAction) || isPickDate,
    allowsPushNavigation: isCallback && !isCopyCallback && !completedOpen && !completedFileAction && input.metadataTagReceipt === undefined,
    allowsFileEffects: isCallback && !completedFileAction,
  };
  capturesActionQuery = isCallback && input.metadataTagReceipt === undefined;
  let accepted;
  try {
    await userViewAction.run(grant, async () => {
      if (isPickDate) await submitPickDate(selected, input.pickedDate);
      else if (isCopyCallback) await selected.props.onCopy(selected.props.content);
      else if (completedOpen) await completedOpen();
      else if (completedFileAction) await completedFileAction();
      else if (isCallback) {
        if (typeof selected.props.onAction === "function") await selected.props.onAction();
      } else accepted = await submitForm(form.root, children, selected, form.values, input.formEvents, form.dropdownContext);
      await flushToastUpdates();
    });
  } finally {
    grant.active = false;
  }
  await new Promise(setImmediate);
  capturesActionQuery = false;
  if (feedback?.kind === "error") return feedback;
  if (accepted === false) return { kind: "formRejected" };
  if (actionResult) return finish(actionResult);
  if (storageChanged) return finish({ kind: "storage" });
  if (visibleToast?.grant === grant && visibleToast.result) return visibleToast.result;
  if (allowEmptyResult || isCallback || isPickDate || grant.didReadClipboard || grant.didReadWindow || grant.didWriteStorage || grant.didUseToast ||
      takeCacheSnapshot() !== undefined) return { kind: "action" };
  throw new Error("Unknown action");
}

async function reconstructView(renderPage, input) {
  const scope = { active: true, panel: undefined };
  try {
    const snapshot = await actionPanelUpdates.run(scope, () => renderView(renderPage, input, scope));
    return {
      ...snapshot, actionPanel: scope.panel,
      refresh() {
        scope.active = true;
        try {
          return actionPanelUpdates.run(scope, () => ({ ...snapshot.refresh(), actionPanel: scope.panel }));
        } finally {
          scope.active = false;
        }
      },
    };
  } finally {
    scope.active = false;
  }
}

async function renderView(renderPage, input, scope) {
  const { query, action } = input;
  const formEvents = checkedFormEvents(input.formEvents);
  const menuRoute = checkedMenuRoute(input.actionMenuRoute);
  const menuRow = action?.row ?? input.actionMenuRow;
  if (menuRoute.length && (!Number.isSafeInteger(menuRow) || menuRow < -1)) throw new Error("Invalid action submenu target");
  state = [];
  effects = [];
  const formCommands = {};
  const mountedFormRefs = new WeakMap();
  const dropdownContext = formEvents.some(({ kind }) => kind === "search") ? {
    options: new Map(), searches: new Map(), values: input.formDropdownValues,
  } : undefined;
  const renderRoot = () => {
    stateIndex = 0;
    const page = renderPage(query);
    if (dropdownContext) rememberDropdownOptions(page, children, dropdownContext);
    if (!input.sensitiveFormSubmission) mountFormRefs(page, children, formCommands, mountedFormRefs, dropdownContext);
    return page;
  };
  let root = renderRoot();
  const hasSearchBar = root?.type === "list" || root?.type === "grid";
  const searchChange = hasSearchBar && typeof query === "string" && typeof root.props.onSearchTextChange === "function";
  const dropdownChange = hasSearchBar && (input.dropdownValue !== undefined ||
    (root.props.searchBarAccessory?.props?.value === undefined && input.dropdownPreferences?.length > 0));
  const menuSearch = hasSearchBar && typeof input.dropdownQuery === "string";
  const previousReplay = replayingViewInput;
  replayingViewInput = previousReplay || searchChange || dropdownChange || menuSearch;
  let selectedItem;
  let appliedQuery;
  let actionMenu;
  let selectedRow;
  async function searchDropdown(text) {
    const handler = dropdownSearchHandler(root);
    if (!handler || typeof text !== "string" || Buffer.byteLength(text) > 256) return;
    await routeReplay.run(true, () => withCurrentViewInput(() => handler(text)));
    appliedQuery = text;
    effects = [];
    root = renderRoot();
  }
  async function settleEffects() {
    let effectPasses = 0;
    try {
      while (effects?.length) {
        if (effectPasses++ === 8) throw new Error("View effects did not settle");
        const pending = effects;
        effects = undefined;
        for (const effect of pending) await effect();
        await new Promise(setImmediate);
        effects = [];
        root = renderRoot();
      }
    } finally {
      effects = undefined;
    }
  }
  try {
    if (dropdownChange) {
      await routeReplay.run(true, () => withCurrentViewInput(async () => {
        await settleEffects();
        const initialDropdown = describeDropdown(root, children);
        const selectedValue = input.dropdownValue ?? (root.props.searchBarAccessory?.props?.value === undefined
          ? restoredDropdownValue(initialDropdown, input.dropdownPreferences) : undefined);
        if (selectedValue === undefined) return;
        await searchDropdown(input.dropdownSelectionQuery);
        await settleEffects();
        const options = describeDropdown(root, children);
        const candidate = options?.sections.flatMap(({ items }) => items).find(({ value }) => value === selectedValue);
        if (await applyDropdownSelection(root, children, selectedValue, {
          strict: Boolean(action || input.dropdownSelectionEvent),
          previousValue: initialDropdown?.selected,
        })) {
          selectedItem = candidate;
          effects = [];
          root = renderRoot();
        }
      }));
    }
    if (searchChange && typeof root.props.onSearchTextChange === "function") {
      await root.props.onSearchTextChange(query);
      effects = [];
      root = renderRoot();
    }
    if (menuSearch && input.dropdownQuery !== appliedQuery) await searchDropdown(input.dropdownQuery);
    if (replayingViewInput) {
      await routeReplay.run(true, () => withCurrentViewInput(settleEffects));
    } else {
      await settleEffects();
    }
    if (formEvents.length) {
      replayingViewInput = true;
      for (const event of formEvents) {
        await routeReplay.run(true, () => withCurrentViewInput(async () => {
          await replayFormEvent(root, children, event, dropdownContext);
          effects = [];
          root = renderRoot();
          await settleEffects();
        }));
      }
    }
    if (root?.type === "list" || root?.type === "grid") {
      const items = () => root.type === "list"
        ? listNodes(root, query, children).nodes
        : gridNodes(root, query, children).groups.flatMap(({ items }) => items);
      const pick = (visible, requested, preferRequested = false) => {
        const controlled = visible.findIndex(({ itemID }) => itemID !== undefined && itemID === root.props.selectedItemId);
        const previous = visible.findIndex(({ itemID }) => itemID !== undefined && itemID === requested);
        if (preferRequested && previous >= 0) return previous;
        return controlled >= 0 ? controlled : previous >= 0 ? previous : visible.length ? 0 : undefined;
      };
      const requested = input.selectedItemId;
      if (requested !== undefined && (typeof requested !== "string" || Buffer.byteLength(requested) > 256)) {
        throw new Error("Invalid selected item ID");
      }
      let visible = items();
      selectedRow = pick(visible, requested, input.selectionEvent === true || Boolean(action) || input.actionMenuRow !== undefined);
      const selected = visible[selectedRow]?.itemID;
      const handler = root.props.onSelectionChange;
      if (typeof handler === "function") {
        replayingViewInput = true;
        await routeReplay.run(true, () => withCurrentViewInput(async () => {
          if (typeof selected === "string") await handler(selected);
          else if (!visible.length) await handler(null);
          await new Promise(setImmediate);
          effects = [];
          root = renderRoot();
          await settleEffects();
        }));
        if (root?.type === "list" || root?.type === "grid") {
          visible = items();
          selectedRow = pick(visible, selected);
        }
      }
      if (requested === undefined && root?.props.selectedItemId === undefined && typeof handler !== "function") {
        selectedRow = undefined;
      }
    }
    if (menuRoute.length) {
      replayingViewInput = true;
      actionMenu = await replayActionMenu(menuRoute, () => panelForRoute(root, query, menuRow, scope.panel), children,
        async (callback, ...args) => {
          await routeReplay.run(true, () => withCurrentViewInput(async () => {
            await callback(...args);
            await new Promise(setImmediate);
            effects = [];
            root = renderRoot();
            await settleEffects();
          }));
        });
    }
  } finally {
    if (replayingViewInput) {
      actionResult = undefined;
      feedback = undefined;
    }
    replayingViewInput = previousReplay;
  }
  const dropdownFor = (root) => root?.type === "list" || root?.type === "grid"
    ? describeDropdown(root, children, selectedItem?.value, selectedItem) : undefined;
  return {
    root, dropdown: dropdownFor(root), actionMenu, formCommands, dropdownContext, selectedRow,
    refresh() {
      const updated = renderRoot();
      return { root: updated, dropdown: dropdownFor(updated), formCommands, dropdownContext, selectedRow };
    },
  };
}

function panelForRoute(root, query, row, override) {
  switch (root?.type) {
    case "form":
    case "detail":
      return row === 0 ? resolvedPanel(override, root.props.actions) : undefined;
    case "grid": {
      const { groups, empty } = gridNodes(root, query, children);
      if (row === -1 && empty) return resolvedPanel(override, empty.panel);
      const target = groups.flatMap((group) => group.items).find(({ id }) => id === row);
      return target ? resolvedPanel(override, target.item.props.actions) : undefined;
    }
    case "list": {
      const { nodes, empty } = listNodes(root, query, children);
      if (row === -1 && empty) return resolvedPanel(override, empty.panel);
      return nodes[row] ? resolvedPanel(override, nodes[row].item.props.actions) : undefined;
    }
    default:
      return undefined;
  }
}

async function render(command, input) {
  configure(input);
  let renderPage = (query) => command({ arguments: { input: query } });
  const route = checkedViewRoute(input.viewRoute);
  const popped = input.poppedFrame === undefined ? undefined : checkedViewRoute([input.poppedFrame])[0];
  const notifyPush = input.notifyPush === true;
  if ((notifyPush || popped) && (input.action !== undefined || input.sensitiveFormSubmission ||
      (notifyPush && (popped || !route.at(-1)?.lifecycleReceipt)) ||
      (popped && (route.length >= 4 || !popped.lifecycleReceipt || input.query !== popped.query)))) {
    throw new Error("Invalid navigation transition");
  }
  let entering;
  if (route.length) {
    await replayRoute(async () => {
      for (const frame of route) {
        const { selected } = await reconstructFrame(renderPage, frame, input);
        entering = selected;
        const target = await viewNavigation.replay(selected, frame.mode);
        renderPage = () => target;
      }
    });
  }
  let result;
  let lifecycleFailed = false;
  if (popped) {
    const { selected, snapshot } = await replayRoute(() => reconstructFrame(renderPage, popped, input));
    lifecycleFailed = await notifyNavigation(selected.props.onPop);
    result = await describeView(snapshot.refresh(), { query: input.query });
  } else {
    result = await renderSnapshot(renderPage, input);
    if (notifyPush) lifecycleFailed = await notifyNavigation(entering.props.onPush);
  }
  if (lifecycleFailed) result = { ...result, lifecycleFailed: true };
  if (notifyPush || popped) result = finish(result);
  const cache = takeCacheSnapshot();
  return cache === undefined || result.kind === "error" ? result : { ...result, cache };
}

function replayRoute(reconstruct) {
  return routeReplay.run(true, () => withCacheWritesBlocked(async () => {
    replayingViewInput = true;
    try { return await reconstruct(); }
    finally { replayingViewInput = false; }
  }));
}

async function reconstructFrame(renderPage, frame, input) {
  const snapshot = await reconstructView(renderPage, {
    ...frame, actionMenuRow: frame.row, dropdownPreferences: input.dropdownPreferences,
  });
  const { root, actionPanel, actionMenu } = snapshot;
  const panel = actionMenu ?? panelForRoute(root, frame.query, frame.row, actionPanel);
  const selected = findAction(panel, frame.id, children);
  if (frame.lifecycleReceipt && frame.lifecycleReceipt !== lifecycleReceipt(selected)) {
    throw new Error("Invalid navigation lifecycle receipt");
  }
  return { selected, snapshot };
}

async function notifyNavigation(callback) {
  if (typeof callback !== "function") return false;
  const grant = { active: true, lifecycle: true };
  try {
    await userViewAction.run(grant, () => withCacheWriteLifetime(grant, callback));
    return false;
  } catch {
    return true;
  } finally {
    grant.active = false;
  }
}

async function renderSnapshot(renderPage, input) {
  const snapshot = await reconstructView(renderPage, input);
  if (input.metadataTagReceipt !== undefined) {
    const reply = await invokeMetadataTag(snapshot.root, input);
    if (reply.kind === "action" || reply.kind === "storage") {
      return finish(await describeView(snapshot.refresh(), { query: input.query }));
    }
    return reply;
  }
  const reply = await describeView(snapshot, input);
  if (input.dateReceipt !== undefined && reply.kind === "action") {
    return describeView(snapshot.refresh(), { query: input.query });
  }
  if (reply.kind === "formRejected" && !input.sensitiveFormSubmission && !hasPasswordField(snapshot.root, children)) {
    const updated = await describeView(snapshot.refresh(), { query: input.query });
    if (updated.kind === "form") return { ...updated, ...reply };
  }
  return reply;
}

async function invokeMetadataTag(root, input) {
  const { action, metadataTagReceipt, query } = input;
  if (typeof metadataTagReceipt !== "string" || !/^[a-f0-9]{64}$/.test(metadataTagReceipt) ||
      action?.id !== 0 || input.actionMenuRoute !== undefined || input.sensitiveFormSubmission) {
    throw new Error("Invalid metadata tag action");
  }
  let panel;
  let scope;
  if (root?.type === "detail" && action.row === 0) {
    panel = root.props.metadata;
  } else if (root?.type === "list" && Number.isSafeInteger(action.row) && action.row >= 0) {
    const { nodes } = listNodes(root, query, children);
    const item = nodes[action.row]?.item;
    panel = item?.props.detail?.props.metadata;
    if (item) scope = [item.props.id, listText(item.props.title)];
  }
  const callback = metadataTagCallback(panel, metadataTagReceipt, children, scope);
  if (typeof callback !== "function") throw new Error("Invalid metadata tag action");
  return invokeViewAction(ActionPanel({ children: Action({ onAction: callback }) }), 0, true, input);
}

async function describeView(snapshot, input) {
  const { query, action } = input;
  const { root, dropdown, actionPanel, actionMenu, formCommands, dropdownContext, selectedRow } = snapshot;
  if (input.actionMenuRow !== undefined && !action) {
    if (!actionMenu) throw new Error("Missing action submenu route");
    return { kind: "actionMenu", actions: actionDescriptions(actionMenu), submenu: submenuOptions(actionMenu) };
  }
  if (input.dropdownQuery !== undefined && !action && !input.dropdownSelectionEvent) {
    return { kind: "dropdown", dropdown };
  }
  const panelFor = (panel) => actionMenu ?? resolvedPanel(actionPanel, panel);
  if (root?.type === "form") {
    const panel = panelFor(root.props.actions);
    const withFormCommands = (reply) => Object.keys(formCommands).length && !input.sensitiveFormSubmission && reply.kind !== "error"
      ? { ...reply, formCommands } : reply;
    if (!action) return withFormCommands({
      kind: "form", form: describeForm(root, children, false, dropdownContext), formActions: actionDescriptions(panel), formActionPanelTitle: actionPanelTitle(panel),
    });
    if (action.row !== 0) throw new Error("Unknown form");
    return withFormCommands(await invokeViewAction(panel, action.id, true, input, { root, values: input.formValues, dropdownContext }));
  }
  if (root?.type === "detail") {
    if (!action) return { kind: "detail", detail: detailDescription(root.props, actionPanel) };
    if (action.row !== 0) throw new Error("Unknown detail");
    return invokeViewAction(panelFor(root.props.actions), action.id, true, input);
  }
  const selection = {
    ...(selectedRow !== undefined && { selectedRow }),
    ...(typeof root?.props.onSelectionChange === "function" && { observesSelection: true }),
  };
  if (root?.type === "grid") {
    const { groups, empty } = gridNodes(root, query, children);
    if (!action) return { kind: "grid", ...selection, grid: describeGrid(root, groups, empty, (panel) => actionDescriptions(panelFor(panel)), (panel) => actionPanelTitle(panelFor(panel))), ...(dropdown && { dropdown }) };
    if (action.row === -1 && empty) return invokeViewAction(panelFor(empty.panel), action.id, true, input);
    const target = groups.flatMap((group) => group.items).find(({ id }) => id === action.row);
    if (!target) throw new Error("Unknown grid item");
    return invokeViewAction(panelFor(target.item.props.actions), action.id, true, input, undefined, target.item.props.quickLook);
  }
  if (root?.type !== "list") throw new Error("Expected List, Detail, Grid or Form");
  const { nodes, empty } = listNodes(root, query, children);
  if (action) {
    if (action.row === -1 && empty) return invokeViewAction(panelFor(empty.panel), action.id, true, input);
    const target = nodes[action.row];
    if (!target) throw new Error("Unknown action");
    return invokeViewAction(panelFor(target.item.props.actions), action.id, false, input, undefined, target.item.props.quickLook);
  }
  return {
    kind: "view",
    ...selection,
    ...(dropdown && { dropdown }),
    isLoading: root.props.isLoading,
    empty: empty && { title: empty.title, description: empty.description, icon: empty.icon, ...(empty.imageDescriptor && { imageDescriptor: empty.imageDescriptor }), actionPanelTitle: actionPanelTitle(panelFor(empty.panel)), actions: actionDescriptions(panelFor(empty.panel)) },
    rows: nodes.map(({ item, itemID, section, sectionSubtitle, sectionID }, index) => {
      if (item.type !== "item") throw new Error("Expected List.Item");
      const { title, subtitle, icon, detail, actions: panel, accessories } = item.props;
      const accessoryText = accessories?.map(({ tag, date }) => tag ?? date?.toISOString()).filter(Boolean).join(" · ");
      const source = icon?.source ?? icon;
      const utilityIcon = describeUtilityIcon(source);
      const imageDescriptor = utilityIcon ? undefined : describeImage(icon);
      return {
        id: index, ...(itemID !== undefined && { itemID }), section, sectionSubtitle, sectionID, title: listText(title), subtitle: listText(subtitle) ?? accessoryText,
        icon: !utilityIcon && typeof source === "string" ? source : undefined,
        ...iconTint(source, icon?.tintColor),
        utilityIcon,
        ...(imageDescriptor && { imageDescriptor }),
        markdown: detail?.props.markdown,
        detailLoading: detail?.props.isLoading === true || undefined,
        richMetadata: describeListMetadata(detail?.props.metadata, children, webURL, { scope: [item.props.id, listText(title)] }),
        metadata: children(detail?.props.metadata).filter((node) => node.type === "label")
          .map(({ props }) => ({ title: listText(props.title) ?? "", text: listText(props.text) ?? "" })),
        actionPanelTitle: actionPanelTitle(panelFor(panel)),
        actions: actionDescriptions(panelFor(panel)),
      };
    }),
  };
}

// The pinned command uses local calendar fields for a single workday.
async function runMenuBar(command, input) {
  configure(input);
  const wallTime = input.wallTime;
  if (!Number.isFinite(wallTime)) throw new Error("Missing host clock");
  const RealDate = Date;
  process.env.TZ = "UTC";
  global.Date = class extends RealDate {
    constructor(...args) { super(...(args.length ? args : [wallTime])); }
    static now() { return wallTime; }
  };
  try {
    const root = command();
    if (root == null) return { kind: "menuBar", visible: false, subtitle: feedback?.text };
    if (root.type !== "menuBar") throw new Error("Expected MenuBarExtra");
    const { items, callbacks } = describeMenu(root, children);
    if (input.menuAction !== undefined) {
      const callback = callbacks[input.menuAction];
      if (typeof callback !== "function") throw new Error("Unknown menu action");
      await callback({ type: "left-click" });
      if (actionResult && actionResult.kind !== "openPreferences") throw new Error("Unsupported menu action");
      return actionResult ?? { kind: "menuAction" };
    }
    return {
      kind: "menuBar",
      visible: true,
      title: root.props.title,
      subtitle: feedback?.text,
      tooltip: root.props.tooltip,
      icon: root.props.icon?.source ?? root.props.icon,
      tint: root.props.icon?.tintColor,
      items,
    };
  } finally {
    global.Date = RealDate;
  }
}

async function runCommand(command, input) {
  if (typeof command !== "function") throw new Error("Unknown command");
  configure(input);
  const args = { ...input.arguments };
  if (input.mode === "generate" && input.count !== undefined && args.numberOfUUIDsToGenerate === undefined) {
    args.numberOfUUIDsToGenerate = String(input.count);
  }
  const count = args.numberOfUUIDsToGenerate || args.numberOfULIDsToGenerate;
  if (count && (!/^\d+$/.test(count) || Number(count) < 1 || Number(count) > 20)) {
    return { kind: "error", text: "Enter a count from 1 to 20." };
  }

  await command({ arguments: args });
  await flushToastUpdates();
  if (feedback?.kind === "error") return feedback;
  if (actionResult) return finish(actionResult);
  return feedback ?? { kind: "error", text: "The command produced no result." };
}

function displayToast(toast, { style, title, message }) {
  const grant = userViewAction.getStore();
  if (routeReplay.getStore() || (grant && !grant.active)) return;
  const text = [title, message].filter(Boolean).join(" ");
  if (visibleToast?.error && feedback === visibleToast.error) feedback = undefined;
  if (style === ToastStyle.Failure) {
    feedback = { kind: "error", text };
    visibleToast = { toast, grant, error: feedback };
  } else {
    visibleToast = { toast, grant, result: { kind: "toast", text, toastStyle: style } };
  }
  if (grant) grant.didUseToast = true;
}

const { Toast, ToastStyle, showToast, flushToastUpdates } = makeToastAdapter({
  show: displayToast,
  update(toast, options) {
    if (visibleToast?.toast === toast) displayToast(toast, options);
  },
  hide(toast) {
    const grant = userViewAction.getStore();
    if (routeReplay.getStore() || (grant && !grant.active) || visibleToast?.toast !== toast) return;
    if (visibleToast.error && feedback === visibleToast.error) feedback = undefined;
    visibleToast = undefined;
  },
});

function canReadClipboard() {
  const grant = userViewAction.getStore();
  return clipboardReadAllowed && grant?.active === true && grant.allowsFileEffects;
}

const clipboardReaders = makeClipboardReaders(async (capability, text) => {
  const value = await require("./raycast-api.cjs").request(capability, text);
  const grant = userViewAction.getStore();
  if (grant?.active) grant.didReadClipboard = true;
  return value;
}, canReadClipboard);

const Clipboard = {
  ...clipboardReaders,
  clear: makeClearClipboard(recordFileEffect),
  copy: async (content, options) => clipboardResult("copy", content, options),
  paste: async (content, options) => clipboardResult("paste", content, options),
};

function canReadWindows() {
  const grant = userViewAction.getStore();
  return windowReadAllowed && grant?.active === true && grant.allowsFileEffects;
}

const WindowManagement = makeWindowManagement(async (capability, text) => {
  const value = await require("./raycast-api.cjs").request(capability, text);
  const grant = userViewAction.getStore();
  if (grant?.active) grant.didReadWindow = true;
  return value;
}, canReadWindows);

for (const api of [WindowManagement, WindowManagement.getActiveWindow, WindowManagement.getWindowsOnActiveDesktop]) {
  registerEnvironmentCapability(api, canReadWindows);
}

for (const api of [Clipboard, Clipboard.read, Clipboard.readText]) {
  registerEnvironmentCapability(api, canReadClipboard);
}

module.exports = {
  ...applicationQueries,
  WindowManagement,
  environment, LaunchType, Action, ActionPanel, Color, Detail, Form, Grid, Icon, Image, ImageMask, Keyboard, List, MenuBarExtra, LocalStorage, useState, useEffect, useRef, render, runCommand, runMenuBar,
  updateCommandMetadata: async ({ subtitle }) => {
    if (!routeReplay.getStore()) feedback = { kind: "metadata", text: subtitle };
  },
  open,
  ...navigation,
  PopToRootType,
  openExtensionPreferences,
  openCommandPreferences: async () => {
    if (routeReplay.getStore()) throw new Error("Command preferences require a selected action");
    actionResult = { kind: "openPreferences" };
  },
  getPreferenceValues: () => ({ ...preferenceValues }),
  preferences: makePreferences(() => preferenceValues, () => preferenceDefinitions),
  prepareInput, Cache, specialKeys,
  useId: () => viewID(stateIndex++),
  randomId,
  ListItem: List.Item,
  ListSection: List.Section,
  useNavigation: viewNavigation.useNavigation,
  PushAction: Action.Push,
  Clipboard,
  clearClipboard: Clipboard.clear,
  showInFinder, trash,
  ShowInFinderAction: Action.ShowInFinder,
  TrashAction: Action.Trash,
  OpenWithAction,
  SubmitFormAction: Action.SubmitForm,
  PasteAction: Action.Paste,
  CopyToClipboardAction: Action.CopyToClipboard,
  OpenAction: Action.Open,
  OpenInBrowserAction: Action.OpenInBrowser,
  ActionPanelItem: Action,
  ActionPanelSection: ActionPanel.Section,
  ActionPanelSubmenu: ActionPanel.Submenu,
  useActionPanel, captureException, captureMemorySnapshot,
  FormCheckbox: Form.Checkbox,
  FormDatePicker: Form.DatePicker,
  FormDropdown: Form.Dropdown,
  FormDropdownItem: Form.Dropdown.Item,
  FormDropdownSection: Form.Dropdown.Section,
  FormSeparator: Form.Separator,
  FormTagPicker: Form.TagPicker,
  FormTagPickerItem: Form.TagPicker.Item,
  FormTextArea: Form.TextArea,
  FormTextField: Form.TextField,
  ...localStorageAliases(LocalStorage),
  ...clipboardAliases(Clipboard),
  Toast,
  ToastStyle,
  showHUD: async (text) => {
    if (!routeReplay.getStore() && !feedback && typeof text === "string") feedback = { kind: "hud", text };
  },
  showToast,
  Alert,
  AlertActionStyle,
  confirmAlert: async ({ primaryAction }) => {
    if (routeReplay.getStore()) return false;
    if (confirmed) await primaryAction?.onAction?.();
    return confirmed;
  },
  jsxRuntime: { jsx, jsxs: jsx },
};
