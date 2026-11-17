const { createHash } = require("node:crypto");
const { describeImage } = require("./image-api.cjs");
const { clipboardEffect, clipboardWritePayload } = require("./clipboard-write.cjs");
// Compatibility surface for the reviewed views and UUID commands.
const { environment, LaunchType, registerEnvironmentCapability } = require("./environment.cjs");
const { makeToastAdapter, toastInteraction, runWithToastActions } = require("./toast.cjs");
const { menuBarComponents, describeMenu, describeMenuIcon } = require("./menu-bar.cjs");
const { gridComponents, gridNodes, describeGrid } = require("./grid-api.cjs");
const { formComponents, describeForm, hasPasswordField, submitForm, checkedFormEvents, replayFormEvent, mountFormRefs, rememberDropdownOptions } = require("./form-api.cjs");
const { listNodes, listText, describeListAccessories } = require("./list-api.cjs");
const {
  ActionStyle, actionPanelComponents, describeActions, findAction, actionPanelTitle,
  checkedMenuRoute, replayActionMenu, submenuOptions, effectReceipt,
} = require("./action-api.cjs");
const { dropdownComponent, describeDropdown, applyDropdownSelection, dropdownSearchHandler, restoredDropdownValue } = require("./dropdown-api.cjs");
const { AsyncLocalStorage } = require("node:async_hooks");
const { makeOpen, requestOpen, openActionComponents, openActionEffect, metadataLinkURL } = require("./open-api.cjs");
const { finderRevealComponent, finderRevealEffect, makeShowInFinder } = require("./finder-reveal.cjs");
const { trashComponent, trashEffect } = require("./trash-action.cjs");
const { makeClipboardReaders } = require("./clipboard-read.cjs");
const { makeWindowManagement } = require("./window-management.cjs");
const { quickLookComponent, quickLookEffect } = require("./quick-look-action.cjs");
const { openWithComponent, openWithEffect, makeClearClipboard } = require("./open-with-clipboard.cjs");
const { makeNavigation, PopToRootType, requestNavigation } = require("./navigation-api.cjs");
const { creationActionComponents, creationActionEffect, makeOpenExtensionPreferences } = require("./create-actions.cjs");
const { pickDateComponent, describePickDate, submitPickDate } = require("./date-action.cjs");
const { listMetadataComponents, describeListMetadata, metadataTagCallback } = require("./list-metadata.cjs");
const { captureException, captureMemorySnapshot } = require("./diagnostics-api.cjs");

const { Alert, AlertActionStyle, makePreferences, resolvePreferenceValues, randomId, viewID, viewIDSeedSlot, fitsViewIDs, checkedViewIDs, specialKeys } = require("./foundation-api.cjs");
const { Cache, configureCache, setCacheWritesAllowed, takeCacheSnapshot, hasCacheChanges, cacheStateRevision, withCacheWritesBlocked, withCacheWriteLifetime } = require("./cache-api.cjs");
const { makePushNavigation, pushActionComponent, checkedViewRoute } = require("./push-navigation.cjs");

const { makeApplicationQueries } = require("./applications-api.cjs");
let applicationQueryFiles = [];
let applicationQueryPreferenceCount = 0;
let applicationQueryEvents = new Map();
const applicationQuerySelection = new AsyncLocalStorage();
const applicationQueries = makeApplicationQueries(
  (capability, text) => require("./raycast-api.cjs").request(capability, text),
  (path) => {
    const granted = applicationQueryFiles.indexOf(path);
    if (!routeReplay.getStore() || (granted !== -1 && granted < applicationQueryPreferenceCount)) return granted;
    const selection = applicationQuerySelection.getStore();
    if (!selection?.active) return -1;
    const index = selection.paths.indexOf(path);
    return index === -1 ? -1 : selection.offset + index;
  },
);

const userViewAction = new AsyncLocalStorage();
const initialViewEffects = new AsyncLocalStorage();
const viewSearchClear = new AsyncLocalStorage();
const userMenuAction = new AsyncLocalStorage();
const userNoViewCommand = new AsyncLocalStorage();
const routeReplay = new AsyncLocalStorage();
const actionPanelUpdates = new AsyncLocalStorage();
const { Color, Icon, Image, ImageMask, Keyboard, iconTint } = require("./presentation-values.cjs");
const { makeBrokerLocalStorage } = require("./broker-local-storage.cjs");
const { localStorageAliases, clipboardAliases } = require("./storage-compat.cjs");

let actionResult;
let feedback;
let runningCommand;
let visibleToast;
let preferenceValues;
let preferenceDefinitions;
let preparedInput;
let storage;
let storageChanged;
let localStorageAllowed;
let state;
let stateVersion = 0;
let stateIndex;
let effectIndex;
let rootEffectSlots;
let componentFrames;
let componentFrame;
let viewIDs;
let viewIDSeed;
let effects;
let replayingViewInput;
let capturesActionQuery;
let clipboardReadAllowed;
let windowReadAllowed;
let commandMetadataAllowed;
let suitePreferencesAllowed;
let suiteFinderRevealAllowed;
let suiteOpenAllowed;

function prepareInput(input) {
  preparedInput = input;
  const canQueryHostFiles = input.sensitiveFormSubmission !== true;
  applicationQueryFiles = canQueryHostFiles && Array.isArray(input.applicationQueryPreferenceFields)
    ? input.applicationQueryPreferenceFields.map((name) => input.preferences[name])
    : [];
  applicationQueryPreferenceCount = applicationQueryFiles.length;
  if (canQueryHostFiles && Array.isArray(input.applicationQueryFormFields)) {
    applicationQueryFiles.push(...input.applicationQueryFormFields.flatMap((id) => input.formValues[id]));
  }
  applicationQueryEvents = new Map();
  if (canQueryHostFiles && Array.isArray(input.applicationQueryFormEvents)) {
    let offset = applicationQueryFiles.length;
    for (const index of input.applicationQueryFormEvents) {
      const event = input.formEvents?.[index];
      if (event?.kind !== "change" || !Array.isArray(event.value)) continue;
      applicationQueryEvents.set(event, { offset, paths: event.value });
      offset += event.value.length;
    }
  }
  commandMetadataAllowed = input.commandMetadataAllowed === true && input.sensitiveFormSubmission !== true;
  suitePreferencesAllowed = input.suitePreferencesAllowed === true && input.sensitiveFormSubmission !== true;
  suiteFinderRevealAllowed = suitePreferencesAllowed && input.finderRevealAllowed === true;
  suiteOpenAllowed = suitePreferencesAllowed && input.openTargetAllowed === true;
  preferenceDefinitions = input.preferenceDefinitions;
  preferenceValues = resolvePreferenceValues(input.preferences, preferenceDefinitions);
  configureCache(input.sensitiveFormSubmission ? undefined : input.cache);
}

function configure(input) {
  if (preparedInput !== input) prepareInput(input);
  preparedInput = undefined;
  actionResult = undefined;
  feedback = undefined;
  runningCommand = false;
  visibleToast = undefined;
  storage = input.storage === undefined || input.sensitiveFormSubmission ? undefined : Object.assign(Object.create(null), input.storage);
  localStorageAllowed = input.localStorageAllowed === true && !input.sensitiveFormSubmission;
  storageChanged = false;
  clipboardReadAllowed = input.clipboardReadAllowed === true && input.sensitiveFormSubmission !== true;
  windowReadAllowed = input.windowReadAllowed === true && input.sensitiveFormSubmission !== true;
  state = [];
  rootEffectSlots = [];
  viewIDs = undefined;
  viewIDSeed = undefined;
  stateIndex = 0;
  componentFrames = new Map();
  componentFrame = undefined;
  effects = [];
  replayingViewInput = false;
  capturesActionQuery = false;
}

const Fragment = Symbol("Fragment");
const nativeComponents = new WeakSet();
const elementSlots = ["children", "actions", "detail", "metadata", "searchBarAccessory", "target"];

function jsx(type, props, key) {
  const element = nativeComponents.has(type) ? type(props ?? {}) : { type, props: props ?? {} };
  return key === undefined ? element : { ...element, key: String(key) };
}

function renderComponentTree(render) {
  const next = new Map();
  function resolve(value, path, depth = 0) {
    if (depth > 128) throw new Error("Component tree exceeds supported depth");
    if (Array.isArray(value)) return value.map((node, index) =>
      resolve(node, [...path, node?.key === undefined ? index : node.key], depth + 1));
    if (typeof value !== "object" || value === null || !value.props) return value;
    const { type, props, key } = value;
    if (type === Fragment) return resolve(props.children, [...path, "fragment", key ?? null], depth + 1);
    if (typeof type === "function") {
      const identity = JSON.stringify([...path, key ?? null]);
      const prior = componentFrames.get(identity);
      const frame = prior?.type === type ? prior : {
        type, identity: createHash("sha256").update(identity).update(Function.prototype.toString.call(type)).digest("hex"),
        hooks: [], effectSlots: [], idSlots: new Map(),
      };
      next.set(identity, frame);
      const previousFrame = componentFrame;
      const previousIndex = stateIndex;
      const previousEffectIndex = effectIndex;
      let rendered;
      try {
        componentFrame = frame;
        stateIndex = 0;
        effectIndex = 0;
        rendered = type(props);
      } finally {
        stateIndex = previousIndex;
        effectIndex = previousEffectIndex;
        componentFrame = previousFrame;
      }
      const resolved = resolve(rendered, [...path, frame.identity], depth + 1);
      return key !== undefined && resolved?.props ? { ...resolved, key } : resolved;
    }
    const result = { ...props };
    for (const slot of elementSlots) {
      if (Object.hasOwn(props, slot)) result[slot] = resolve(props[slot], [...path, type, slot], depth + 1);
    }
    return { ...value, props: result };
  }
  const root = resolve(render(), []);
  for (const [path, frame] of componentFrames) {
    if (next.get(path) === frame) continue;
    for (const [slot, automatic] of frame.idSlots) {
      viewIDs?.delete(slot);
      // Persist the replacement ID so the next isolated render sees the same remount.
      if (automatic && viewIDSeed !== undefined) rememberViewID(slot, viewID(slot, randomId(12)));
    }
  }
  componentFrames = next;
  return root;
}

function resolveDetachedTree(element) {
  const savedFrames = componentFrames;
  const savedEffects = effects;
  const savedIDs = viewIDs;
  const savedSeed = viewIDSeed;
  try {
    componentFrames = new Map();
    effects = undefined;
    viewIDs = undefined;
    viewIDSeed = undefined;
    return renderComponentTree(() => element);
  } finally {
    componentFrames = savedFrames;
    effects = savedEffects;
    viewIDs = savedIDs;
    viewIDSeed = savedSeed;
  }
}

function useState(initial) {
  const index = stateIndex++;
  const frameState = componentFrame?.hooks ?? state;
  const ownerState = state;
  if (!(index in frameState)) frameState[index] = typeof initial === "function" ? initial() : initial;
  return [frameState[index], (value) => {
    const previous = frameState[index];
    const next = typeof value === "function" ? value(previous) : value;
    frameState[index] = next;
    if (ownerState === state && !Object.is(previous, next)) stateVersion++;
    if (!routeReplay.getStore() && ownerState === state && capturesActionQuery && (!actionResult || actionResult.kind === "query") && typeof next === "string") actionResult = { kind: "query", text: next };
  }];
}

function rememberViewID(index, value) {
  if (!viewIDs || typeof value !== "string" || Buffer.byteLength(value) > 256) return;
  const candidate = [...viewIDs, [index, value]];
  if (fitsViewIDs(candidate)) viewIDs.set(index, value);
}

function useId(defaultId, generateId) {
  // Keep native snapshots compatible with existing numeric root hook slots.
  const index = componentFrame
    ? createHash("sha256").update(JSON.stringify([componentFrame.identity, stateIndex])).digest().readUIntBE(0, 6) + 256
    : stateIndex;
  const automatic = defaultId == null && generateId === undefined;
  componentFrame?.idSlots.set(index, automatic);
  const [id] = useState(() => {
    if (viewIDs?.has(index)) return viewIDs.get(index);
    if (automatic) {
      if (!viewIDs) return viewID(index);
      if (viewIDSeed === undefined) {
        viewIDSeed = randomId(12);
        rememberViewID(viewIDSeedSlot, viewIDSeed);
      }
      return viewID(index, viewIDSeed);
    }
    const value = defaultId ?? generateId();
    rememberViewID(index, value);
    return value;
  });
  return id;
}

function useRef(initial) {
  return useState(() => ({ current: initial }))[0];
}

function useEffect(effect, dependencies = []) {
  const index = effectIndex++;
  if (!effects || (routeReplay.getStore() && !replayingViewInput)) return;

  const slots = componentFrame?.effectSlots ?? rootEffectSlots;
  const previous = slots[index];
  if (previous && previous.length === dependencies.length &&
      previous.every((value, offset) => Object.is(value, dependencies[offset]))) return;

  effects.push(() => {
    slots[index] = [...dependencies];
    return effect();
  });
}

function component(name) {
  const native = (props) => jsx(name, props);
  nativeComponents.add(native);
  return native;
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

const refreshAfterStorageWrite = Symbol();
const brokerStorage = makeBrokerLocalStorage((capability, text) => require("./raycast-api.cjs").request(capability, text));

async function brokerStorageWrite(operation, ...args) {
  const result = await brokerStorage[operation](...args);
  const grant = userViewAction.getStore() ?? userMenuAction.getStore();
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
      if (panel) panel = resolveDetachedTree(panel);
      if (panel != null && panel !== false && panel.type !== "actions") {
        throw new TypeError("Expected an ActionPanel");
      }
      const next = panel || null;
      if (scope.panel !== next) {
        scope.panel = next;
        stateVersion++;
      }
    },
  };
}

function resolvedPanel(override, panel) {
  return override === undefined ? panel : override;
}

function actionDescriptions(panel) {
  return describeActions(panel, children);
}

// Keep code spans and fenced code literal. Generated sources end in the
// percent-encoded SVG closing tag, even when they contain unescaped parentheses.
const markdownImage = /(```[\s\S]*?```|~~~[\s\S]*?~~~|`+[^\x60]*`+)|(?<!\\)(!\[(?:\\.|[^\]\\\n])*\]\()(?:<([^<>\n]{1,4096})>(?=[) \t])|(data:image\/svg\+xml,[^\s<>]{1,4075}?%3C%2Fsvg%3E(?:\?[^\s<>()]{1,512})?|[^\s<>()]{1,4096})(?=[) \t]))/g;

const markdownReferenceDefinition = /^[ \t]*(?:>[ \t]*)*(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)?\[(?:\\.|[^\[\]\\\r\n]){1,999}\]:[ \t]*(?:\r?\n[ \t]*(?:>[ \t]*)*)?(?:<([^<>\r\n]{1,4096})>|((?:\\.|[^\s<>]){1,4096}))/gm;

function referenceDestination(source) {
  const entities = { amp: "&", quot: '"', apos: "'", lt: "<", gt: ">" };
  return source.replace(/\\([!-/:-@\[-`{-~])|&(#x[0-9a-f]{1,6}|#[0-9]{1,7}|amp|quot|apos|lt|gt);/gi, (match, escaped, entity) => {
    if (escaped) return escaped;
    if (!entity.startsWith("#")) return entities[entity] ?? match;
    const hex = entity[1].toLowerCase() === "x";
    const value = Number.parseInt(entity.slice(hex ? 2 : 1), hex ? 16 : 10);
    return value === 0 || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff) ? "\uFFFD" : String.fromCodePoint(value);
  });
}

function describeMarkdown(markdown) {
  if (typeof markdown !== "string") return { markdown };
  const sources = new Map();
  const markdownImages = [];
  function register(source) {
    const remote = /^https:\/\//i.test(source);
    const resource = remote ? source.split("#", 1)[0] : source;
    const queryStart = resource.indexOf("?");
    const asset = queryStart < 0 ? resource : resource.slice(0, queryStart);
    const query = queryStart < 0 ? "" : resource.slice(queryStart + 1);
    const options = new URLSearchParams(query);
    const displayKeys = ["raycast-width", "raycast-height", "raycast-tint-color", "raycast-tintColor"];
    const remoteQuery = remote ? query.split("&").filter((pair) =>
      !displayKeys.includes(new URLSearchParams(pair).keys().next().value)).join("&") : "";
    const resourceURL = remoteQuery ? asset + "?" + remoteQuery : asset;
    const tint = options.get("raycast-tint-color") ?? options.get("raycast-tintColor") ?? undefined;
    const key = JSON.stringify([resourceURL, tint]);
    let index = sources.get(key);
    if (index === undefined) {
      if (markdownImages.length >= 8) return undefined;
      let destination = resourceURL;
      if (!remote && !asset.startsWith("data:")) {
        try {
          destination = decodeURIComponent(asset);
        } catch {
          return undefined;
        }
      }
      const image = describeImage({ source: destination, tintColor: tint }, true, remote);
      if (!image) return undefined;
      index = markdownImages.length;
      sources.set(key, index);
      markdownImages.push(image);
    }
    const dimensions = new URLSearchParams();
    for (const axis of ["width", "height"]) {
      const raw = options.get(`raycast-${axis}`);
      if (raw && /^[0-9]+(?:\.[0-9]{1,3})?$/.test(raw) && Number(raw) >= 1 && Number(raw) <= 1024) {
        dimensions.set(axis, String(Number(raw)));
      }
    }
    return `keylane-image://icon/${index}` + (dimensions.size ? `?${dimensions}` : "");
  }

  const text = markdown.replace(markdownImage, (match, code, opening, angleSource, plainSource) => {
    if (code) return match;
    const reference = register(angleSource ?? plainSource);
    if (!reference) return match;
    return opening + (angleSource === undefined ? reference : `<${reference}>`);
  });

  const markdownImageReferences = Object.create(null);
  // Only collect image candidates here. Foundation resolves labels and distinguishes
  // real image references from links, code and definitions that do not take effect.
  const candidates = markdown.replace(markdownImage, (match) => match.replace(/[^\r\n]/g, " "));
  if (candidates.includes("![")) {
    let count = 0;
    for (const match of candidates.matchAll(markdownReferenceDefinition)) {
      if (count === 16) break;
      const source = referenceDestination(match[1] ?? match[2]);
      let canonical;
      try { canonical = /^https:\/\//i.test(source) ? new URL(source).href : decodeURIComponent(source); } catch { continue; }
      const key = createHash("sha256").update(canonical).digest("hex");
      if (markdownImageReferences[key]) continue;
      const reference = register(source);
      if (!reference) continue;
      markdownImageReferences[key] = reference;
      count++;
    }
    if (count) return { markdown: text, markdownImages, markdownImageReferences };
  }
  return { markdown: text, ...(markdownImages.length > 0 && { markdownImages }) };
}

function detailDescription({ markdown, navigationTitle, isLoading, metadata, actions: panel }, override) {
  const actions = resolvedPanel(override, panel);
  const title = actionPanelTitle(actions);
  return {
    ...describeMarkdown(markdown), navigationTitle, isLoading,
    metadata: describeListMetadata(metadata, children, metadataLinkURL, { includeLabelsOnly: true }),
    ...(title !== undefined && { actionPanelTitle: title }),
    actions: actionDescriptions(actions),
  };
}

function recordUserAction(effect, name) {
  const grant = userViewAction.getStore();
  if (!grant?.active || grant.lifecycle || actionResult) throw new Error(`${name} requires a selected view action`);
  actionResult = effect;
}

function recordMenuAction(grant, effect) {
  if (!grant.active || grant.effect) throw new Error("Requires one active menu action");
  grant.effect = effect;
}

const open = makeOpen(async (effect) => {
  const menu = userMenuAction.getStore();
  const view = userViewAction.getStore();
  if (menu) {
    if (!menu.openTargetAllowed && effect.kind !== "openURL") throw new Error("Menu actions can only open URLs");
    if (!menu.active || menu.effect) throw new Error("Requires one active menu action");
    if (!menu.openTargetAllowed) return recordMenuAction(menu, effect);
    menu.effect = { kind: "menuAction" };
  } else if (!(suiteOpenAllowed && runningCommand && !actionResult)) {
    if (!view?.active || !view.allowsOpen || view.lifecycle || actionResult) {
      throw new Error("Open requires a selected view action");
    }
    if (!view.openTargetAllowed) return recordUserAction(effect, "Open");
  }
  if (visibleToast) visibleToast.interaction = undefined;
  await requestOpen(require("./raycast-api.cjs").request, effect);
});
function recordFileEffect(effect) {
  if (!userViewAction.getStore()?.allowsFileEffects) throw new Error("File and clipboard changes require a selected view action");
  recordUserAction(effect, effect.kind);
}

const legacyClearClipboard = makeClearClipboard(recordFileEffect);
async function clearClipboard() {
  const grant = userViewAction.getStore();
  const menu = userMenuAction.getStore();
  const viewAllowed = grant?.active && grant.finderRevealAllowed && grant.allowsFileEffects && !grant.lifecycle && !actionResult;
  const menuAllowed = menu?.active && menu.finderRevealAllowed && !menu.effect;
  if (!viewAllowed && !menuAllowed && !(suiteFinderRevealAllowed && runningCommand && !actionResult)) {
    if (grant?.liveToast || menu) throw new Error("Clearing the clipboard requires an authorized action");
    return legacyClearClipboard();
  }
  if (visibleToast) visibleToast.interaction = undefined;
  await require("./raycast-api.cjs").Clipboard.clear();
}

const showInFinder = makeShowInFinder(async ({ paths: [path] }) => {
  const grant = userViewAction.getStore();
  const menu = userMenuAction.getStore();
  const viewAllowed = grant?.active && grant.allowsFileEffects && grant.finderRevealAllowed && !grant.lifecycle && !actionResult;
  const menuAllowed = menu?.active && menu.finderRevealAllowed && !menu.effect;
  if (!viewAllowed && !menuAllowed && !(suiteFinderRevealAllowed && runningCommand && !actionResult)) {
    throw new Error("Finder changes require a selected view action, menu action, or no-view command");
  }
  if (visibleToast) visibleToast.interaction = undefined;
  await require("./raycast-api.cjs").request("files.reveal", path);
});
async function trash(path) {
  const grant = userViewAction.getStore();
  const menu = userMenuAction.getStore();
  const viewAllowed = grant?.active && (grant.liveToast || suiteFinderRevealAllowed) && grant.finderRevealAllowed &&
    grant.allowsFileEffects && !grant.lifecycle && !actionResult;
  const menuAllowed = menu?.active && menu.finderRevealAllowed && !menu.effect;
  if (!viewAllowed && !menuAllowed && !(suiteFinderRevealAllowed && runningCommand && !actionResult)) {
    throw new Error("Moving files to Trash requires an authorized view action, menu action, or no-view command");
  }
  if (visibleToast) visibleToast.interaction = undefined;
  await require("./raycast-api.cjs").trash(path);
}
const viewNavigation = makePushNavigation((effect, name) => {
  if (!userViewAction.getStore()?.allowsPushNavigation) throw new Error(`${name} requires a selected view action`);
  recordUserAction(effect, name);
}, resolveDetachedTree);
const navigation = makeNavigation(async (effect) => {
  const command = userNoViewCommand.getStore();
  if (command?.catalog) {
    if (!command.active) throw new Error("The no-view command has ended");
    await requestNavigation(require("./raycast-api.cjs").request, effect);
    return;
  }
  const grant = userViewAction.getStore();
  const menu = userMenuAction.getStore();
  if (effect.kind === "popToRoot" && !actionResult) {
    const fromView = grant?.active && !grant.lifecycle && grant.liveNavigation;
    const fromInitialEffect = initialViewEffects.getStore()?.active && !routeReplay.getStore();
    const fromSuite = suitePreferencesAllowed && (runningCommand || grant?.active && !grant.lifecycle);
    if (menu || fromView || fromInitialEffect || fromSuite) {
      if ((menu && (!menu.active || !menu.alertAllowed || menu.effect)) || (fromView && !grant.navigationCloseAllowed)) {
        throw new Error("Host root navigation unavailable");
      }
      await require("./raycast-api.cjs").request("navigation.popToRoot", JSON.stringify({ clearSearchBar: effect.clearSearchBar }));
      return;
    }
  }
  if (effect.kind === "clearSearchBar" && !actionResult) {
    const fromView = grant?.active && !grant.lifecycle && grant.liveNavigation;
    const fromSearch = viewSearchClear.getStore()?.active && !routeReplay.getStore();
    const fromSuite = suitePreferencesAllowed && (runningCommand || grant?.active && !grant.lifecycle);
    if (menu || fromView || fromSearch || fromSuite) {
      if ((menu && (!menu.active || !menu.alertAllowed || menu.effect)) || (fromView && !grant.navigationCloseAllowed)) {
        throw new Error("Host search bar unavailable");
      }
      await require("./raycast-api.cjs").request("navigation.clearSearch", JSON.stringify({ forceScrollToTop: effect.forceScrollToTop }));
      return;
    }
  }
  if (effect.kind === "closeMainWindow" || effect.kind === "hud") {
    const fromView = grant?.active && !grant.lifecycle && grant.liveNavigation;
    const initial = initialViewEffects.getStore();
    const fromInitialEffect = initial?.active && initial.windowEffectsAllowed && !routeReplay.getStore();
    const fromSuite = suitePreferencesAllowed && (runningCommand || grant?.active && !grant.lifecycle) &&
      (!actionResult || actionResult.kind === "copy" || actionResult.kind === "paste");
    if (fromSuite || (!actionResult && (menu || fromView || fromInitialEffect))) {
      if ((menu && (!menu.active || !menu.alertAllowed || menu.effect)) || (fromView && !grant.navigationCloseAllowed)) {
        throw new Error("Host window closure unavailable");
      }
      if (visibleToast) visibleToast.interaction = undefined;
      const { kind, ...options } = effect;
      const capability = kind === "hud" ? "feedback.hud" : "navigation.closeWindow";
      await require("./raycast-api.cjs").request(capability, JSON.stringify(options));
      if (fromSuite && runningCommand && !feedback) feedback = { kind: "action" };
      return;
    }
  }
  if (runningCommand && effect.kind === "hud") {
    if (!feedback) feedback = effect;
    return;
  }
  recordUserAction(effect, effect.kind);
});
const confirmAlert = require("./alert-api.cjs").makeConfirmAlert((payload) => {
  const grant = userViewAction.getStore();
  const menu = userMenuAction.getStore();
  const viewAllowed = grant?.active && !grant.lifecycle && grant.navigationCloseAllowed && !actionResult;
  const menuAllowed = menu?.active && menu.alertAllowed && !menu.effect;
  if (!viewAllowed && !menuAllowed) throw new Error("Alert requires an authorized view action or menu action");
  if (visibleToast) visibleToast.interaction = undefined;
  return require("./raycast-api.cjs").request("feedback.confirmAlert", payload);
});
async function openPreferences(target) {
  const view = userViewAction.getStore();
  const menu = userMenuAction.getStore();
  const viewAllowed = view?.active && !view.lifecycle && (view.navigationCloseAllowed || suitePreferencesAllowed) && !actionResult;
  const menuAllowed = menu?.active && menu.alertAllowed && !menu.effect;
  const initialAllowed = initialViewEffects.getStore()?.active === true && !routeReplay.getStore() && !actionResult;
  if (viewAllowed || menuAllowed || initialAllowed || (suitePreferencesAllowed && runningCommand && !actionResult)) {
    if (visibleToast) visibleToast.interaction = undefined;
    await require("./raycast-api.cjs").request("preferences.open", target);
  } else if (menu) {
    recordMenuAction(menu, { kind: target === "command" ? "openPreferences" : "openExtensionPreferences" });
  } else {
    const kind = target === "command" ? "openPreferences" : "openExtensionPreferences";
    recordUserAction({ kind }, kind);
  }
}

const openExtensionPreferences = makeOpenExtensionPreferences(() => openPreferences("extension"));

async function invokeViewAction(panel, id, allowEmptyResult, input, form, quickLook) {
  const selected = findAction(panel, id, children);
  const isPickDate = selected?.type === "pickDate";
  const hasPickedDate = Object.hasOwn(input, "pickedDate");
  if ((input.dateReceipt !== undefined || hasPickedDate) && !isPickDate) throw new Error("Invalid date selection receipt");
  if ((input.copyReceipt !== undefined && selected?.type !== "copy") ||
      (input.pasteReceipt !== undefined && selected?.type !== "paste")) {
    throw new Error("Invalid clipboard completion receipt");
  }
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
  let clipboardCompletion;
  const isCopy = selected?.type === "copy";
  const isPaste = selected?.type === "paste";
  if (isCopy || isPaste) {
    const { content, concealed, transient, onCopy, onPaste } = selected.props;
    const callback = isCopy ? onCopy : onPaste;
    const key = isCopy ? "copyReceipt" : "pasteReceipt";
    const effect = isCopy ? clipboardEffect("copy", content, { concealed: concealed ?? transient })
      : clipboardEffect("paste", content);
    const receipt = effectReceipt([effect, content], selected.props);
    if (input[key] === undefined) {
      return typeof callback === "function" ? { ...effect, [key]: receipt } : effect;
    }
    if (typeof callback !== "function" || input[key] !== receipt) {
      throw new Error("Invalid clipboard completion receipt");
    }
    clipboardCompletion = () => callback(content);
  }
  if (isPickDate) {
    const effect = describePickDate(selected);
    const receipt = effectReceipt(effect, selected.props);
    if (!hasPickedDate && input.dateReceipt === undefined) return { ...effect, dateReceipt: receipt };
    if (!hasPickedDate || input.dateReceipt !== receipt) throw new Error("Invalid date selection receipt");
  }
  const isSubmit = selected?.type === "submitForm" && form;
  const isCallback = selected?.type === "callback" || Boolean(clipboardCompletion || completedOpen || completedFileAction);
  if (!isSubmit && !isCallback && !isPickDate) throw new Error("Unknown action");
  if (isSubmit && hasPasswordField(form.root, children)) {
    // Passwords travel only into the selected callback. No effects or extension error text leave it.
    replayingViewInput = true;
    setCacheWritesAllowed(false);
    try {
      const accepted = await submitForm(form.root, children, selected, form.values, input.formEvents, form.dropdownContext);
      await flushToastUpdates();
      if (feedback?.kind === "error" || visibleToast?.result.toastStyle === ToastStyle.Failure) return { kind: "error" };
      return { kind: accepted === false ? "formRejected" : "action" };
    } catch {
      return { kind: "error" };
    } finally {
      replayingViewInput = false;
    }
  }
  const liveToast = !input.sensitiveFormSubmission &&
    (isSubmit ? input.liveFormToast === true && input.interactiveToast === true : input.liveToast === true);
  const grant = {
    active: true,
    liveNavigation: input.liveNavigation === true && !input.sensitiveFormSubmission,
    navigationCloseAllowed: input.navigationCloseAllowed === true,
    openTargetAllowed: input.openTargetAllowed === true,
    finderRevealAllowed: input.finderRevealAllowed === true,
    liveToast,
    interactiveToast: liveToast && input.interactiveToast === true && Boolean(isSubmit || isCallback),
    allowsOpen: (isCallback && !completedFileAction) || isPickDate,
    allowsPushNavigation: isCallback && !clipboardCompletion && !completedOpen && !completedFileAction && input.metadataTagReceipt === undefined,
    allowsFileEffects: isCallback && !completedFileAction,
  };
  capturesActionQuery = isCallback && input.metadataTagReceipt === undefined;
  let accepted;
  try {
    await userViewAction.run(grant, async () => {
      await withInteractiveToast(grant, async () => {
        if (isPickDate) await submitPickDate(selected, input.pickedDate);
        else if (clipboardCompletion) await clipboardCompletion();
        else if (completedOpen) await completedOpen();
        else if (completedFileAction) await completedFileAction();
        else if (isCallback) {
          if (typeof selected.props.onAction === "function") await selected.props.onAction();
        } else accepted = await submitForm(form.root, children, selected, form.values, input.formEvents, form.dropdownContext);
        await flushToastUpdates();
      });
    });
  } finally {
    grant.active = false;
  }
  await new Promise(setImmediate);
  capturesActionQuery = false;
  if (feedback?.kind === "error") return feedback;
  if (accepted === false) {
    const notice = visibleToast?.grant === grant && visibleToast.result.toastStyle === ToastStyle.Failure
      ? visibleToast.result : {};
    return { ...notice, kind: "formRejected" };
  }
  if (actionResult) return finish(actionResult);
  if (storageChanged) return finish({ kind: "storage" });
  if (!grant.liveToast && visibleToast?.grant === grant && visibleToast.result) return visibleToast.result;
  if ((grant.didWriteStorage || hasCacheChanges()) && !input.sensitiveFormSubmission &&
      !clipboardCompletion && !completedOpen && !completedFileAction) {
    return { kind: "action", [refreshAfterStorageWrite]: true };
  }
  if (allowEmptyResult || isCallback || isPickDate || grant.didReadClipboard || grant.didReadWindow || grant.didWriteStorage || grant.didUseToast ||
      hasCacheChanges()) return { kind: "action" };
  throw new Error("Unknown action");
}

async function reconstructView(renderPage, input, effectFrame, renderProgress) {
  const scope = { active: true, panel: undefined };
  try {
    const snapshot = await actionPanelUpdates.run(scope, () => renderView(renderPage, input, scope, effectFrame, renderProgress));
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

function viewPagination(root) {
  const pagination = root?.props.pagination;
  if (typeof pagination?.onLoadMore !== "function" || !Number.isSafeInteger(pagination.pageSize) || pagination.pageSize <= 0) return;
  return pagination;
}

async function renderView(renderPage, input, scope, effectFrame, renderProgress) {
  const { query, action } = input;
  const formEvents = checkedFormEvents(input.formEvents);
  const menuRoute = checkedMenuRoute(input.actionMenuRoute);
  const menuRow = action?.row ?? input.actionMenuRow;
  if (menuRoute.length && (!Number.isSafeInteger(menuRow) || menuRow < -1)) throw new Error("Invalid action submenu target");
  state = [];
  rootEffectSlots = [];
  componentFrames = new Map();
  effects = [];
  const formCommands = {};
  const mountedFormRefs = new WeakMap();
  const dropdownContext = formEvents.some(({ kind }) => kind === "search") ? {
    options: new Map(), searches: new Map(), values: input.formDropdownValues,
  } : undefined;
  const renderRoot = () => {
    stateIndex = 0;
    effectIndex = 0;
    const page = renderComponentTree(() => renderPage(query));
    if (dropdownContext) rememberDropdownOptions(page, children, dropdownContext);
    if (!input.sensitiveFormSubmission) mountFormRefs(page, children, formCommands, mountedFormRefs, dropdownContext);
    return page;
  };
  viewIDs = checkedViewIDs(input.viewIDs);
  viewIDSeed = viewIDs.get(viewIDSeedSlot);
  let root = renderRoot();
  const hasSearchBar = root?.type === "list" || root?.type === "grid";
  const searchChange = hasSearchBar && typeof query === "string" && typeof root.props.onSearchTextChange === "function";
  const allowsSearchClear = hasSearchBar && input.searchClearAllowed === true &&
    !action && !input.sensitiveFormSubmission && !routeReplay.getStore();
  async function withSearchClear(callback) {
    if (!allowsSearchClear) return callback();
    const grant = { active: true };
    try {
      return await viewSearchClear.run(grant, callback);
    } finally {
      grant.active = false;
    }
  }
  const initialDropdown = hasSearchBar ? describeDropdown(root, children) : undefined;
  const selectedValue = input.dropdownValue ?? (root?.props?.searchBarAccessory?.props?.value === undefined
    ? restoredDropdownValue(initialDropdown, input.dropdownPreferences) : undefined);
  const dropdownChange = hasSearchBar && selectedValue !== undefined;
  const menuSearch = hasSearchBar && typeof input.dropdownQuery === "string";
  const previousReplay = replayingViewInput;
  replayingViewInput = previousReplay || searchChange || dropdownChange || menuSearch;
  let selectedItem;
  let appliedQuery;
  let actionMenu;
  let effectNavigation;
  let selectedRow;
  let pageCount = 0;
  async function searchDropdown(text) {
    const handler = dropdownSearchHandler(root);
    if (!handler || typeof text !== "string" || Buffer.byteLength(text) > 256) return;
    await routeReplay.run(true, () => withCacheWritesBlocked(() => handler(text)));
    appliedQuery = text;
    effects = [];
    root = renderRoot();
  }
  try {
    if (dropdownChange) {
      await searchDropdown(input.dropdownSelectionQuery);
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
    }
    if (searchChange && typeof root.props.onSearchTextChange === "function") {
      await withSearchClear(() => root.props.onSearchTextChange(query));
      effects = [];
      root = renderRoot();
    }
    if (menuSearch && input.dropdownQuery !== appliedQuery) await searchDropdown(input.dropdownQuery);
    if (effects.length) {
      let pendingEffects = effects;
      effects = undefined;
      const runEffects = async (firstPass) => {
        for (const [index, effect] of pendingEffects.entries()) {
          const capture = firstPass && (effectFrame ? index === effectFrame.id :
            input.mountNavigation === true && !action && !input.sensitiveFormSubmission &&
            !routeReplay.getStore() && !effectNavigation && index < 12);
          const page = await viewNavigation.runEffect(effect, capture);
          if (page) effectNavigation = { ...page, index };
        }
      };
      const canPublish = renderProgress && !action && !input.sensitiveFormSubmission && !routeReplay.getStore();
      const drain = canPublish ? renderProgress.drain : undefined;
      const run = async (firstPass) => {
        await runEffects(firstPass);
        if (drain) await drain();
      };
      const performEffects = async () => {
        if (input.initialPreferencesAllowed === true && !action && !input.sensitiveFormSubmission && !routeReplay.getStore()) {
          const initialMount = query === "" && input.mountNavigation === true && input.viewRoute === undefined;
          const grant = { active: true, clipboardReadAllowed: initialMount, windowEffectsAllowed: initialMount };
          try {
            await initialViewEffects.run(grant, () => withSearchClear(() => run(true)));
          } finally {
            grant.active = false;
          }
        } else {
          await withSearchClear(() => run(true));
        }
      };
      const settleEffects = async () => {
        for (let pass = 0; pendingEffects.length; pass++) {
          if (pass === 8) throw new Error("View effects did not settle");
          if (pass === 0) await performEffects();
          else await run(false);
          await new Promise(setImmediate);
          effects = [];
          root = renderRoot();
          pendingEffects = effects;
          effects = undefined;
          if (effectNavigation) break;
        }
      };
      const pending = settleEffects();
      if (canPublish) {
        const finished = pending.then(() => true);
        let lastVersion;
        let published = 0;
        while (published < 4) {
          let timer;
          try {
            const settled = await Promise.race([
              finished,
              new Promise((resolve) => {
                timer = setTimeout(() => resolve(false), 120);
                // The preview timer must not keep an otherwise idle guest alive.
                if (drain) timer.unref();
              }),
            ]);
            if (settled) break;
          } finally {
            clearTimeout(timer);
          }
          const version = stateVersion + cacheStateRevision();
          if (lastVersion === version || !["detail", "list", "grid"].includes(root?.type)) continue;
          lastVersion = version;
          const previewRoot = renderRoot();
          const preview = await describeView({ root: previewRoot, pageCount: 0, actionPanel: scope.panel ?? null }, { query });
          if (drain || preview.isLoading === true || preview.detail?.isLoading === true || preview.grid?.isLoading === true ||
              preview.rows?.some((row) => row.detailLoading === true)) {
            if (await renderProgress.publish(preview) !== false) published++;
          }
        }
      }
      await pending;
    }
    if (formEvents.length) {
      replayingViewInput = true;
      for (const event of formEvents) {
        const selection = { ...applicationQueryEvents.get(event), active: applicationQueryEvents.has(event) };
        try {
          await applicationQuerySelection.run(selection, () =>
            routeReplay.run(true, () => withCacheWritesBlocked(() => replayFormEvent(root, children, event, dropdownContext))));
        } finally {
          selection.active = false;
        }
        root = renderRoot();
      }
    }
    const pages = input.pageCount ?? 0;
    if (!Number.isInteger(pages) || pages < 0 || pages > 8) throw new Error("Invalid pagination count");
    while (pageCount < pages && (root?.type === "list" || root?.type === "grid")) {
      const pagination = viewPagination(root);
      if (pagination?.hasMore !== true) break;
      replayingViewInput = true;
      await routeReplay.run(true, () => withCacheWritesBlocked(async () => {
        await pagination.onLoadMore();
        await new Promise(setImmediate);
      }));
      pageCount++;
      root = renderRoot();
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
        await routeReplay.run(true, () => withCacheWritesBlocked(async () => {
          if (typeof selected === "string") await handler(selected);
          else if (!visible.length) await handler(null);
          await new Promise(setImmediate);
        }));
        root = renderRoot();
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
          await routeReplay.run(true, () => withCacheWritesBlocked(async () => {
            await callback(...args);
            await new Promise(setImmediate);
          }));
          root = renderRoot();
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
    root, dropdown: dropdownFor(root), actionMenu, formCommands, dropdownContext, selectedRow, pageCount, effectNavigation,
    refresh() {
      const updated = renderRoot();
      return { root: updated, dropdown: dropdownFor(updated), formCommands, dropdownContext, selectedRow, pageCount };
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

async function render(command, input, renderProgress) {
  configure(input);
  let renderPage = (query) => command({ arguments: { input: query } });
  const route = checkedViewRoute(input.viewRoute);
  const popped = input.poppedFrame === undefined ? undefined : checkedViewRoute([input.poppedFrame])[0];
  const notifyPush = input.notifyPush === true;
  if ((notifyPush || popped) && (input.action !== undefined || input.sensitiveFormSubmission ||
      (notifyPush && (popped || route.at(-1)?.mode !== "action" || !route.at(-1)?.lifecycleReceipt)) ||
      (popped && (route.length >= 4 || !popped.lifecycleReceipt || input.query !== popped.query)))) {
    throw new Error("Invalid navigation transition");
  }
  let entering;
  if (route.length) {
    await replayRoute(async () => {
      for (const frame of route) {
        const { page } = await reconstructFrame(renderPage, frame, input);
        entering = page.onPush;
        renderPage = () => page.target;
      }
    });
  }
  let result;
  let lifecycleFailed = false;
  if (popped) {
    const { snapshot, page } = await replayRoute(() => reconstructFrame(renderPage, popped, input));
    lifecycleFailed = await notifyNavigation(page.onPop);
    result = await describeView(snapshot.refresh(), { query: input.query });
  } else {
    result = await renderSnapshot(renderPage, input, renderProgress);
    if (notifyPush) lifecycleFailed = await notifyNavigation(entering);
  }
  if (lifecycleFailed) result = { ...result, lifecycleFailed: true };
  if (notifyPush || popped) result = finish(result);
  if (!input.sensitiveFormSubmission && result.kind !== "error" && viewIDs && (viewIDs.size || input.viewIDs !== undefined)) {
    result = { ...result, viewIDs: [...viewIDs] };
  }
  const cache = takeCacheSnapshot({ flushPending: true });
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
  const effectFrame = frame.mode === "effect" ? frame : undefined;
  const snapshot = await reconstructView(renderPage, {
    ...frame, actionMenuRow: frame.row, dropdownPreferences: input.dropdownPreferences,
  }, effectFrame);
  if (effectFrame) {
    const page = snapshot.effectNavigation;
    if (page?.receipt !== frame.lifecycleReceipt) throw new Error("Invalid effect navigation receipt");
    return { page, snapshot };
  }
  const { root, actionPanel, actionMenu } = snapshot;
  const panel = actionMenu ?? panelForRoute(root, frame.query, frame.row, actionPanel);
  const selected = findAction(panel, frame.id, children);
  return { page: await viewNavigation.replay(selected, frame), snapshot };
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

async function renderSnapshot(renderPage, input, renderProgress) {
  const snapshot = await reconstructView(renderPage, input, undefined, renderProgress);
  if (snapshot.effectNavigation) {
    const { index, receipt } = snapshot.effectNavigation;
    return finish({ kind: "pushView", routeMode: "effect", effectIndex: index, lifecycleReceipt: receipt });
  }
  if (input.metadataTagReceipt !== undefined) {
    const reply = await invokeMetadataTag(snapshot.root, input);
    if (reply.kind === "action" || reply.kind === "storage") {
      return finish(await describeView(snapshot.refresh(), { query: input.query }));
    }
    return reply;
  }
  const reply = await describeView(snapshot, input);
  if (reply[refreshAfterStorageWrite]) {
    const updated = await describeView(snapshot.refresh(), { query: input.query });
    return { ...updated, storageUpdated: true };
  }
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
  } else if (root?.type === "list" && root.props.isShowingDetail === true && Number.isSafeInteger(action.row) && action.row >= 0) {
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
  const { root, dropdown, actionPanel, actionMenu, formCommands, dropdownContext, selectedRow, pageCount } = snapshot;
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
  const pagination = viewPagination(root);
  const paging = pagination ? { pagination: { pageCount, hasMore: pageCount < 8 && pagination.hasMore === true } } : {};
  const selection = {
    ...(selectedRow !== undefined && { selectedRow }),
    ...(typeof root?.props.onSelectionChange === "function" && { observesSelection: true }),
  };
  if (root?.type === "grid") {
    const { groups, empty } = gridNodes(root, query, children);
    if (!action) return { kind: "grid", ...selection, ...paging, grid: describeGrid(root, groups, empty, (panel) => actionDescriptions(panelFor(panel)), (panel) => actionPanelTitle(panelFor(panel))), ...(dropdown && { dropdown }) };
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
    ...paging,
    ...(dropdown && { dropdown }),
    isLoading: root.props.isLoading,
    ...(root.props.isShowingDetail === true && { isShowingDetail: true }),
    empty: empty && { title: empty.title, description: empty.description, icon: empty.icon, ...(empty.imageDescriptor && { imageDescriptor: empty.imageDescriptor }), actionPanelTitle: actionPanelTitle(panelFor(empty.panel)), actions: actionDescriptions(panelFor(empty.panel)) },
    rows: nodes.map(({ item, itemID, section, sectionSubtitle, sectionID }, index) => {
      if (item.type !== "item") throw new Error("Expected List.Item");
      const { title, subtitle, icon, actions: panel, accessories } = item.props;
      const detail = root.props.isShowingDetail === true ? item.props.detail : undefined;
      const iconValue = icon && typeof icon === "object" && Object.hasOwn(icon, "value") ? icon.value : icon;
      const source = iconValue?.source ?? iconValue;
      const imageDescriptor = describeImage(iconValue, false, true);
      return {
        id: index, ...(itemID !== undefined && { itemID }), section, sectionSubtitle, sectionID, title: listText(title), subtitle: listText(subtitle),
        titleTooltip: listText(title?.tooltip),
        subtitleTooltip: listText(subtitle?.tooltip),
        iconTooltip: listText(icon?.tooltip),
        accessories: describeListAccessories(accessories),
        icon: typeof source === "string" && /^[a-z0-9-]{1,128}$/i.test(source) ? source : undefined,
        ...iconTint(source, iconValue?.tintColor),
        ...(imageDescriptor && { imageDescriptor }),
        ...describeMarkdown(detail?.props.markdown),
        detailLoading: detail?.props.isLoading === true || undefined,
        richMetadata: describeListMetadata(detail?.props.metadata, children, metadataLinkURL, { scope: [item.props.id, listText(title)] }),
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
  const result = await renderMenuBar(command, input);
  const cache = takeCacheSnapshot({ flushPending: true });
  return cache === undefined ? result : { ...result, cache };
}

async function renderMenuBar(command, input) {
  configure(input);
  if (!input.sensitiveFormSubmission) {
    viewIDs = checkedViewIDs(input.viewIDs);
    viewIDSeed = viewIDs.get(viewIDSeedSlot);
  }
  const wallTime = input.wallTime;
  if (!Number.isFinite(wallTime)) throw new Error("Missing host clock");
  const RealDate = Date;
  process.env.TZ = "UTC";
  global.Date = class Date extends RealDate {
    constructor(...args) { super(...(args.length ? args : [wallTime])); }
    static now() { return wallTime; }
    static [Symbol.hasInstance](value) {
      return this === Date ? value instanceof RealDate : super[Symbol.hasInstance](value);
    }
  };
  try {
    const requestedType = input.menuActionType;
    if (requestedType !== undefined &&
        (input.menuAction === undefined || (requestedType !== "left-click" && requestedType !== "right-click"))) {
      throw new Error("Invalid menu action event type");
    }
    function renderMenu() {
      stateIndex = 0;
      effectIndex = 0;
      const menu = renderComponentTree(command);
      if (menu != null && menu.type !== "menuBar") throw new Error("Expected MenuBarExtra");
      return menu;
    }
    function menuSnapshot(menu, items) {
      if (menu == null) return { kind: "menuBar", visible: false, subtitle: feedback?.text };
      return {
        kind: "menuBar",
        visible: true,
        title: menu.props.title,
        subtitle: feedback?.text,
        tooltip: menu.props.tooltip,
        ...describeMenuIcon(menu.props.icon),
        tint: typeof menu.props.icon?.tintColor === "string" ? menu.props.icon.tintColor : undefined,
        items,
        ...(viewIDs && (viewIDs.size || input.viewIDs !== undefined) && { viewIDs: [...viewIDs] }),
      };
    }

    let root = renderMenu();
    if (effects.length) {
      const initial = effects;
      effects = undefined;
      for (const effect of initial) await effect();
      await new Promise(setImmediate);
      root = renderMenu();
    }
    if (root == null) return menuSnapshot(root);
    const { items, callbacks } = describeMenu(root, children);
    if (input.menuAction !== undefined) {
      if (!Number.isSafeInteger(input.menuAction) || input.menuAction < 0) throw new Error("Invalid menu action ID");
      const callback = callbacks[input.menuAction];
      if (typeof callback !== "function") throw new Error("Unknown menu action");
      const grant = {
        active: true, effect: undefined, alertAllowed: input.menuAlertAllowed === true,
        liveToast: input.menuAlertAllowed === true && input.interactiveToast === true,
        interactiveToast: input.menuAlertAllowed === true && input.interactiveToast === true,
        clipboardReadAllowed: clipboardReadAllowed && input.menuAlertAllowed === true,
        finderRevealAllowed: input.finderRevealAllowed === true,
        openTargetAllowed: input.openTargetAllowed === true,
      };
      try {
        await userMenuAction.run(grant, () => withInteractiveToast(grant, async () => {
          await callback({ type: requestedType ?? "left-click" });
          await flushToastUpdates();
        }));
        if (grant.effect) return grant.effect;
        if (!grant.didWriteStorage && !hasCacheChanges()) return { kind: "menuAction" };
        root = renderMenu();
        return { ...menuSnapshot(root, root && describeMenu(root, children).items), storageUpdated: true };
      } finally {
        grant.active = false;
      }
    }
    return menuSnapshot(root, items);
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
  if (input.catalogNoView !== true && count && (!/^\d+$/.test(count) || Number(count) < 1 || Number(count) > 20)) {
    return { kind: "error", text: "Enter a count from 1 to 20." };
  }

  const grant = { active: true, catalog: input.catalogNoView === true,
    clipboard: clipboardReadAllowed && (suitePreferencesAllowed || input.catalogNoView === true) };
  runningCommand = true;
  try {
    await userNoViewCommand.run(grant, async () => {
      try {
        await command(input.catalogNoView === true
          ? { arguments: args, launchType: environment.launchType }
          : { arguments: args });
      } finally {
        grant.active = false;
      }
    });
    await flushToastUpdates();
  } finally {
    runningCommand = false;
  }
  if (input.catalogNoView === true) {
    const result = feedback ?? visibleToast?.result ?? { kind: "action" };
    const cache = takeCacheSnapshot({ flushPending: true });
    return cache === undefined ? result : { ...result, cache };
  }
  if (feedback?.kind === "error") return feedback;
  if (actionResult) return finish(actionResult);
  const toast = visibleToast?.result;
  return feedback ?? (toast?.toastStyle === ToastStyle.Failure ? { kind: "error", text: toast.text } : toast)
    ?? { kind: "error", text: "The command produced no result." };
}

let viewToastSequence = 0;

function withInteractiveToast(grant, run) {
  if (!grant.interactiveToast) return run();
  return runWithToastActions(run, {
    currentToast: () => visibleToast?.grant === grant ? visibleToast : undefined,
    hasResult: () => actionResult || storageChanged || feedback || grant.effect || grant.didWriteStorage,
    select: (token, polling) => require("./raycast-api.cjs").request("feedback.toastAction", polling ? token + ":poll" : token),
    redisplay: (current, callbacks) => displayToast(current.toast, current.presentation, "update", callbacks),
    flush: flushToastUpdates,
  });
}

async function displayToast(toast, options, operation, callbacks) {
  const grant = userViewAction.getStore() ?? userMenuAction.getStore();
  if (routeReplay.getStore() || (grant && !grant.active)) return;
  const id = operation === "show" ? ++viewToastSequence : visibleToast.id;
  const { style, title, message, feedbackAction, secondaryFeedbackAction } = options;
  const interaction = callbacks && grant?.interactiveToast && !actionResult && !storageChanged && !feedback
    ? toastInteraction(options) : undefined;
  if (grant?.liveToast) {
    await require("./raycast-api.cjs").request("feedback.toast", JSON.stringify({
      operation, id, style, title, message, feedbackAction, secondaryFeedbackAction, interaction,
    }));
  }
  const text = [title, message].filter(Boolean).join(" ");
  visibleToast = {
    id, toast, grant, interaction, callbacks, presentation: options,
    result: {
      kind: "toast", text, toastStyle: style,
      ...(feedbackAction && { feedbackAction }),
      ...(secondaryFeedbackAction && { secondaryFeedbackAction }),
    },
  };
  if (grant) grant.didUseToast = true;
}

const { Toast, ToastStyle, showToast, flushToastUpdates } = makeToastAdapter({
  show: (toast, options, callbacks) => displayToast(toast, options, "show", callbacks),
  update(toast, options, callbacks) {
    if (visibleToast?.toast === toast) return displayToast(toast, options, "update", callbacks);
  },
  async hide(toast) {
    const grant = userViewAction.getStore() ?? userMenuAction.getStore();
    const current = visibleToast;
    if (routeReplay.getStore() || (grant && !grant.active) || current?.toast !== toast) return;
    if (grant?.liveToast) {
      await require("./raycast-api.cjs").request("feedback.toast", JSON.stringify({ operation: "hide", id: current.id }));
    }
    if (visibleToast === current) visibleToast = undefined;
  },
});

function canReadClipboard() {
  if (!clipboardReadAllowed) return false;
  const grant = userViewAction.getStore();
  const menu = userMenuAction.getStore();
  const initial = initialViewEffects.getStore();
  return (grant?.active === true && grant.allowsFileEffects) ||
    (menu?.active === true && menu.clipboardReadAllowed === true) ||
    (userNoViewCommand.getStore()?.active === true && userNoViewCommand.getStore()?.clipboard === true) ||
    (initial?.active === true && initial.clipboardReadAllowed && !routeReplay.getStore());
}

const clipboardReaders = makeClipboardReaders(async (capability, text) => {
  const value = await require("./raycast-api.cjs").request(capability, text);
  const grant = userViewAction.getStore();
  if (grant?.active) grant.didReadClipboard = true;
  return value;
}, canReadClipboard);

async function copyClipboard(content, options) {
  const grant = userViewAction.getStore();
  const menu = userMenuAction.getStore();
  const viewAllowed = grant?.active && grant.liveToast && grant.finderRevealAllowed && grant.allowsFileEffects &&
    !grant.lifecycle && !actionResult && !routeReplay.getStore() && !replayingViewInput;
  const menuAllowed = menu?.active && menu.finderRevealAllowed && !menu.effect;
  if (!viewAllowed && !menuAllowed) return clipboardResult("copy", content, options);
  const payload = clipboardWritePayload(content, options);
  if (visibleToast) visibleToast.interaction = undefined;
  await require("./raycast-api.cjs").request("clipboard.write", payload);
}

const Clipboard = {
  ...clipboardReaders,
  clear: clearClipboard,
  copy: copyClipboard,
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

const updateCommandMetadata = require("./command-metadata.cjs").makeUpdateCommandMetadata(async (subtitle) => {
  if (routeReplay.getStore() || replayingViewInput) return;
  if (commandMetadataAllowed) {
    await require("./raycast-api.cjs").request("command.updateMetadata", JSON.stringify({ subtitle }));
  } else {
    // The standalone menu verifier has no signed installation to update.
    feedback = { kind: "metadata", text: subtitle };
  }
});

module.exports = {
  ...applicationQueries,
  WindowManagement,
  environment, LaunchType, Action, ActionPanel, Color, Detail, Form, Grid, Icon, Image, ImageMask, Keyboard, List, MenuBarExtra, LocalStorage, useState, useEffect, useRef, render, runCommand, runMenuBar,
  updateCommandMetadata,
  open,
  ...navigation,
  PopToRootType,
  openExtensionPreferences,
  openCommandPreferences: () => openPreferences("command"),
  getPreferenceValues: () => ({ ...preferenceValues }),
  preferences: makePreferences(() => preferenceValues, () => preferenceDefinitions),
  prepareInput, Cache, specialKeys,
  useId,
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
  showToast,
  Alert,
  AlertActionStyle,
  confirmAlert,
  jsxRuntime: { jsx, jsxs: jsx, Fragment },
};
