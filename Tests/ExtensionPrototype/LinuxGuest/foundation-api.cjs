const { randomBytes } = require("node:crypto");
const { environment } = require("./environment.cjs");

const AlertActionStyle = Object.freeze({ Default: "default", Cancel: "cancel", Destructive: "destructive" });
const Alert = Object.freeze({ ActionStyle: AlertActionStyle });

const specialKeys = Object.freeze({
  return: "return",
  delete: "delete",
  deleteForward: "deleteForward",
  tab: "tab",
  arrowUp: "arrowUp",
  arrowDown: "arrowDown",
  arrowLeft: "arrowLeft",
  arrowRight: "arrowRight",
  pageUp: "pageUp",
  pageDown: "pageDown",
  home: "home",
  end: "end",
  space: "space",
  escape: "escape",
  enter: "enter",
  backspace: "backspace",
});

function randomId(size = 21) {
  if (!Number.isSafeInteger(size) || size < 0) throw new RangeError("Expected a nonnegative integer ID length");
  const byteCount = Math.ceil(size * 3 / 4);
  return randomBytes(byteCount).toString("base64url").slice(0, size);
}

function viewID(index, seed) {
  if (!Number.isSafeInteger(index) || index < 0) throw new Error("useId is only available while rendering a view");
  const scope = [environment.ownerOrAuthorName, environment.extensionName, environment.entryPointName]
    .map((value) => encodeURIComponent(value ?? "")).join("/");
  return seed === undefined ? `keylane/${scope}/${index}` : `keylane/${scope}/${seed}/${index}`;
}

function resolvePreferenceValues(values, definitions) {
  const fields = new Map((definitions ?? []).map((field) => [field.name, field]));
  const resolved = Object.fromEntries([...fields.values()]
    .filter((field) => field.type !== "appPicker" && Object.hasOwn(field, "default"))
    .map(({ name, default: fallback }) => [name, fallback]));
  return { ...resolved, ...values };
}

// Outside the range of root hook indices and hashed component slots.
const viewIDSeedSlot = Number.MAX_SAFE_INTEGER;

function fitsViewIDs(entries) {
  return entries.length <= 96 && Buffer.byteLength(JSON.stringify(entries)) <= 6144;
}

function checkedViewIDs(value) {
  if (value === undefined) return new Map();
  if (!Array.isArray(value) || value.length > 96 ||
      value.some((entry) => !Array.isArray(entry) || entry.length !== 2 ||
        !Number.isSafeInteger(entry[0]) || entry[0] < 0 || typeof entry[1] !== "string" ||
        Buffer.byteLength(entry[1]) > 256 ||
        (entry[0] === viewIDSeedSlot && !/^[A-Za-z0-9_-]{12}$/.test(entry[1]))) || !fitsViewIDs(value)) {
    throw new Error("Invalid view ID snapshot");
  }
  const ids = new Map(value);
  if (ids.size !== value.length) throw new Error("Duplicate view ID slot");
  return ids;
}

function makePreference(name, values, definition) {
  const hasValue = Object.hasOwn(values, name);
  const value = hasValue ? values[name] : undefined;
  const preference = {
    name,
    type: definition?.type ?? (typeof value === "boolean" ? "checkbox" : "textfield"),
    required: definition?.required ?? false,
    title: definition?.title ?? name,
    description: definition?.description ?? "",
  };
  for (const field of ["default", "placeholder", "label"]) {
    if (definition && Object.hasOwn(definition, field)) preference[field] = definition[field];
  }
  if (definition?.data) preference.data = Object.freeze(definition.data.map((item) => Object.freeze({ ...item })));
  if (hasValue) preference.value = value;
  return Object.freeze(preference);
}

function makePreferences(readValues, readDefinitions = () => undefined) {
  let previousValues;
  let previousDefinitions;
  let entries = Object.create(null);
  const currentEntries = () => {
    const values = readValues();
    const definitions = readDefinitions();
    if (values === previousValues && definitions === previousDefinitions) return entries;

    const fields = new Map((definitions ?? []).map((field) => [field.name, field]));
    const names = new Set([...fields.keys(), ...Object.keys(values ?? {})]);
    entries = Object.fromEntries(Array.from(names, (name) => [name, makePreference(name, values ?? {}, fields.get(name))]));
    Object.setPrototypeOf(entries, null);
    previousValues = values;
    previousDefinitions = definitions;
    return entries;
  };
  // Keep one read-only facade for imports made before the active command is configured.
  return new Proxy(Object.create(null), {
    get: (_, name) => currentEntries()[name],
    has: (_, name) => Object.hasOwn(currentEntries(), name),
    ownKeys: () => Object.keys(currentEntries()),
    getOwnPropertyDescriptor: (_, name) => Object.hasOwn(currentEntries(), name)
      ? { value: currentEntries()[name], configurable: true, enumerable: true, writable: false }
      : undefined,
    set: () => false,
    defineProperty: () => false,
    deleteProperty: () => false,
    setPrototypeOf: () => false,
    preventExtensions: () => false,
  });
}

module.exports = { Alert, AlertActionStyle, makePreferences, resolvePreferenceValues, randomId, specialKeys, viewID, viewIDSeedSlot, fitsViewIDs, checkedViewIDs };
