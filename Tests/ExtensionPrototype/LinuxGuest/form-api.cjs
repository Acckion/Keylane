const { describeImage } = require("./image-api.cjs");
const { webURL } = require("./open-api.cjs");

const fieldKinds = new Set([
  "textField", "textArea", "checkbox", "dropdown", "datePicker", "tagPicker", "passwordField", "filePicker",
]);
const interactiveKinds = new Set(["textField", "textArea", "checkbox", "datePicker", "tagPicker", "dropdown"]);
const formEventCallbacks = Object.freeze({ change: "onChange", focus: "onFocus", blur: "onBlur", search: "onSearchTextChange" });
const dateTypes = Object.freeze({ Date: "date", DateTime: "date_time" });
const fullDayDates = new WeakSet();
// Classification follows the date-only picker value, including when a time picker returns midnight.
function isFullDay(value) {
  return fullDayDates.has(value) && Number.isFinite(Date.prototype.getTime.call(value));
}

function formComponents(component) {
  const Dropdown = Object.assign(component("dropdown"), {
    Item: component("formOption"),
    Section: component("formOptionSection"),
  });
  const DatePicker = Object.assign(component("datePicker"), {
    Type: dateTypes,
    isFullDay,
  });
  const TagPicker = Object.assign(component("tagPicker"), { Item: component("formTag") });
  return Object.assign(component("form"), {
    TextField: component("textField"),
    PasswordField: component("passwordField"),
    FilePicker: component("filePicker"),
    LinkAccessory: component("formLinkAccessory"),
    TextArea: component("textArea"),
    Checkbox: component("checkbox"),
    Dropdown,
    DatePicker,
    TagPicker,
    Description: component("description"),
    Separator: component("separator"),
  });
}

function formOptions(node, children, kind) {
  const seen = new Set();
  const options = [];
  function append({ type, props }, section) {
    const itemType = kind === "dropdown" ? "formOption" : "formTag";
    if (type !== itemType || typeof props?.title !== "string" || typeof props.value !== "string" ||
        seen.has(props.value)) {
      throw new Error(kind === "dropdown" ? "Invalid Form.Dropdown.Item" : "Invalid Form.TagPicker.Item");
    }
    seen.add(props.value);
    const imageDescriptor = describeImage(props.icon, true);
    const keywords = kind === "dropdown" && Array.isArray(props.keywords)
      ? props.keywords.filter((word) => typeof word === "string" && Buffer.byteLength(word) <= 128).slice(0, 8) : undefined;
    options.push({ value: props.value, title: props.title, ...section, ...(imageDescriptor && { imageDescriptor }),
      ...(keywords && { keywords }) });
    if (options.length > 96) throw new Error("Form option limit exceeded");
  }
  for (const [index, child] of children(node).entries()) {
    if (kind === "dropdown" && child.type === "formOptionSection") {
      const title = child.props.title;
      const section = { section: index, sectionTitle: typeof title === "string" ? title : undefined };
      for (const item of children(child)) append(item, section);
    } else {
      append(child);
    }
  }
  return options;
}

function normalizeDate(value, type) {
  if (!(value instanceof Date) || !Number.isFinite(value.getTime())) throw new Error("Invalid Form date");
  const date = new Date(value);
  // Date-only fields share the guest's UTC calendar with the native picker.
  if (type === dateTypes.Date) date.setUTCHours(0, 0, 0, 0);
  if (date.getUTCFullYear() < 1 || date.getUTCFullYear() > 9999) throw new Error("Invalid Form date");
  return date;
}

function dateField(props, value) {
  const type = props.type ?? dateTypes.DateTime;
  if (type !== dateTypes.Date && type !== dateTypes.DateTime) throw new Error("Invalid Form date type");
  const minimum = props.min == null ? undefined : normalizeDate(props.min, type).toISOString();
  const maximum = props.max == null ? undefined : normalizeDate(props.max, type).toISOString();
  if (minimum && maximum && minimum > maximum) throw new Error("Invalid Form date bounds");
  let date = value == null ? null : normalizeDate(value, type).toISOString();
  if (date && minimum && date < minimum) date = minimum;
  if (date && maximum && date > maximum) date = maximum;
  return { dateType: type, minimum, maximum, value: date };
}

function submitDate(value, field) {
  if (value === null) return null;
  if (typeof value !== "string") throw new Error("Invalid Form date");
  const date = normalizeDate(new Date(value), field.dateType);
  if (date.toISOString() !== value ||
      (field.minimum && value < field.minimum) || (field.maximum && value > field.maximum)) {
    throw new Error("Invalid Form date");
  }
  if (field.dateType === dateTypes.Date) fullDayDates.add(date);
  return date;
}

function describeLinkAccessory(node) {
  if (node?.type !== "formLinkAccessory") return undefined;
  const { target, text } = node.props ?? {};
  if (typeof text !== "string" || text.length === 0 || Buffer.byteLength(text) > 512) return undefined;
  try {
    return { target: webURL(target), text };
  } catch {
    return undefined;
  }
}

function filePickerOptions(props) {
  return {
    canChooseFiles: props.canChooseFiles !== false,
    canChooseDirectories: props.canChooseDirectories === true,
    allowMultipleSelection: props.allowMultipleSelection !== false,
    showHiddenFiles: props.showHiddenFiles === true,
  };
}

function validSelectedPaths(paths, picker) {
  if (!Array.isArray(paths) || paths.length > (picker.allowMultipleSelection ? 16 : 1) ||
      new Set(paths).size !== paths.length) return false;
  if (paths.length && !picker.canChooseFiles && !picker.canChooseDirectories) return false;
  return paths.every((path) => typeof path === "string" && path.startsWith("/") &&
    !path.startsWith("//") && Buffer.byteLength(path) <= 1024 && !/[\p{Cc}\p{Cf}]/u.test(path));
}

function hasPasswordField(root, children) {
  return children(root).some(({ type }) => type === "passwordField");
}

function rememberDropdownOptions(root, children, context) {
  if (root?.type !== "form") return;
  for (const node of children(root)) {
    if (node.type !== "dropdown" || typeof node.props.id !== "string") continue;
    const known = context.options.get(node.props.id) ?? new Map();
    for (const option of formOptions(node, children, "dropdown")) known.set(option.value, option);
    context.options.set(node.props.id, known);
  }
}

function describeForm(root, children, useDefaults = false, context) {
  const ids = new Set();
  const nodes = children(root);
  if (nodes.length > 32) throw new Error("Form field limit exceeded");
  let optionCount = 0;
  const fields = nodes.map((node) => {
    const { type: kind, props = {} } = node;
    if (kind === "separator") return { kind };
    if (kind === "description") return { kind, title: props.title, text: props.text };
    if (!fieldKinds.has(kind)) throw new Error("Unsupported Form child");
    const { id, title, info, error, placeholder, label, autoFocus } = props;
    if (typeof id !== "string" || id.length === 0 || Buffer.byteLength(id) > 128 || ids.has(id)) {
      throw new Error("Invalid Form field ID");
    }
    ids.add(id);
    const field = { kind, id, title, info, error, placeholder, label, autoFocus };
    if (kind === "textArea" && props.enableMarkdown === true) field.enableMarkdown = true;
    if (interactiveKinds.has(kind)) {
      if (props.value !== undefined) field.controlled = true;
      if (props.storeValue === true) field.storeValue = true;
      const events = Object.keys(formEventCallbacks).filter((event) =>
        (event !== "search" || kind === "dropdown") && typeof props[formEventCallbacks[event]] === "function");
      if (events.length) field.events = events;
    }
    // Secure fields and host paths only accept explicit user input for this invocation.
    if (kind === "passwordField") return { ...field, value: "" };
    if (kind === "filePicker") return { ...field, picker: filePickerOptions(props), value: [] };
    const value = useDefaults || props.value === undefined ? props.defaultValue : props.value;
    if (kind === "checkbox") return { ...field, value: typeof value === "boolean" ? value : false };
    if (kind === "datePicker") return { ...field, ...dateField(props, value) };
    if (kind === "dropdown" || kind === "tagPicker") {
      const options = formOptions(node, children, kind);
      optionCount += options.length;
      if (optionCount > 96) throw new Error("Form option limit exceeded");
      if (kind === "tagPicker") {
        const known = new Set(options.map((option) => option.value));
        const tags = Array.isArray(value) ? [...new Set(value.filter((tag) => known.has(tag)))] : [];
        return { ...field, options, value: tags };
      }
      const hostValue = !useDefaults && props.value === undefined && context?.values &&
        Object.hasOwn(context.values, id) ? context.values[id] : undefined;
      const requested = hostValue ?? value;
      const selection = options.find((option) => option.value === requested);
      const retainedOption = selection ? undefined : context?.options.get(id)?.get(requested);
      const observesSearch = typeof props.onSearchTextChange === "function";
      return {
        ...field, options, ...(retainedOption && { retainedOption }),
        value: (selection ?? retainedOption ?? options[0])?.value ?? "",
        search: {
          query: context?.searches.get(id),
          observesSearch,
          nativeFiltering: props.filtering === undefined ? !observesSearch : props.filtering !== false,
          keepSectionOrder: props.filtering?.keepSectionOrder === true,
          isLoading: props.isLoading === true,
          throttle: props.throttle === true,
        },
      };
    }
    return { ...field, value: typeof value === "string" ? value : "" };
  });
  const { navigationTitle, isLoading, searchBarAccessory } = root.props;
  const linkAccessory = describeLinkAccessory(searchBarAccessory);
  return { navigationTitle, isLoading, fields, ...(linkAccessory && { linkAccessory }) };
}

function checkedFormEvents(events) {
  if (events === undefined) return [];
  if (!Array.isArray(events) || events.length > 16) throw new Error("Invalid form event list");
  for (const event of events) {
    if (!event || typeof event.id !== "string" || Buffer.byteLength(event.id) > 128 ||
        !Object.hasOwn(formEventCallbacks, event.kind) ||
        !validFormEventValue(event.value) ||
        (event.kind === "search" && (typeof event.value !== "string" || Buffer.byteLength(event.value) > 256))) {
      throw new Error("Invalid form field event");
    }
  }
  return events;
}

function validFormEventValue(value) {
  const validText = (text) => typeof text === "string" && Buffer.byteLength(text) <= 1024;
  return value === null || typeof value === "boolean" || validText(value) ||
    (Array.isArray(value) && value.length <= 96 && value.every(validText));
}

function formValue(field, value, acceptsRetained = false) {
  const { kind, options } = field;
  if (kind === "datePicker") return submitDate(value, field);
  if (kind === "filePicker") {
    if (!validSelectedPaths(value, field.picker)) throw new Error("Invalid Form file selection");
    return [...value];
  }
  if (kind === "tagPicker") {
    const known = new Set(options.map((option) => option.value));
    if (!Array.isArray(value) || value.length > known.size ||
        new Set(value).size !== value.length || value.some((tag) => !known.has(tag))) {
      throw new Error("Invalid Form tag selection");
    }
    return [...value];
  }
  if (kind === "passwordField" && (typeof value !== "string" || Buffer.byteLength(value) > 1024)) {
    throw new Error("Invalid Form password value");
  }
  if (typeof value !== (kind === "checkbox" ? "boolean" : "string")) {
    throw new Error("Invalid Form field value");
  }
  if (kind === "dropdown" && !(options.some((option) => option.value === value) ||
      (acceptsRetained && field.retainedOption?.value === value) || (!options.length && value === ""))) {
    throw new Error("Invalid Form dropdown selection");
  }
  return value;
}

async function replayFormEvent(root, children, event, context) {
  if (root?.type !== "form") throw new Error("Expected a form for field events");
  const node = children(root).find(({ type, props }) => interactiveKinds.has(type) && props?.id === event.id);
  if (event.kind === "search" && node?.type !== "dropdown") return;
  const callback = node?.props[formEventCallbacks[event.kind]];
  if (typeof callback !== "function") return;
  if (event.kind === "search") {
    context?.searches.set(event.id, event.value);
    await callback(event.value);
    return;
  }
  const field = describeForm(root, children, false, context).fields.find(({ id }) => id === event.id);
  let value;
  try {
    value = formValue(field, event.value, event.kind !== "change");
  } catch {
    // A preceding callback may have changed the options or date bounds since this event.
    return;
  }
  if (event.kind === "change") await callback(value);
  else await callback({ type: event.kind, target: { id: event.id, value } });
}

function mountFormRefs(root, children, commands, mounted, context) {
  if (root?.type !== "form") return;
  const nodes = children(root);
  for (const { type, props } of nodes) {
    if (!interactiveKinds.has(type) || typeof props?.id !== "string" ||
        (typeof props.ref !== "function" && (!props.ref || typeof props.ref !== "object"))) continue;
    const { id, ref } = props;
    const resetValue = () => describeForm(root, children, true, context).fields.find((field) => field.id === id).value;
    let reference = mounted.get(ref);
    if (reference) {
      Object.assign(reference, { id, resetValue });
      continue;
    }
    reference = { id, resetValue };
    const api = Object.freeze({
      focus() { commands.focus = reference.id; },
      reset() { (commands.reset ??= Object.create(null))[reference.id] = reference.resetValue(); },
    });
    mounted.set(ref, reference);
    if (typeof ref === "function") ref(api);
    else ref.current = api;
  }
}

async function submitForm(root, children, selectedAction, values, events = [], context) {
  if (selectedAction?.type !== "submitForm" ||
      (selectedAction.props.onSubmit !== undefined && typeof selectedAction.props.onSubmit !== "function")) {
    throw new Error("Invalid Action.SubmitForm");
  }
  const { fields, isLoading } = describeForm(root, children, false, context);
  if (isLoading === true || fields.some((field) => field.error)) throw new Error("Form is unavailable for submission");
  const inputs = fields.filter((field) => fieldKinds.has(field.kind));
  if (!values || typeof values !== "object" || Array.isArray(values) || Object.keys(values).length !== inputs.length) {
    throw new Error("Invalid Form values");
  }
  const entries = inputs.map((field) => {
    const { id } = field;
    if (!Object.hasOwn(values, id)) throw new Error("Missing Form field value");
    const value = values[id];
    if (field.controlled && events.some((event) => event.id === id && event.kind === "change") &&
        JSON.stringify(field.value) !== JSON.stringify(value)) {
      throw new Error("Invalid controlled Form value");
    }
    return [id, formValue(field, value, true)];
  });
  return selectedAction.props.onSubmit?.(Object.fromEntries(entries));
}

module.exports = {
  formComponents, describeForm, hasPasswordField, submitForm, dateTypes, dateField, submitDate, isFullDay,
  checkedFormEvents, replayFormEvent, mountFormRefs, rememberDropdownOptions,
};
