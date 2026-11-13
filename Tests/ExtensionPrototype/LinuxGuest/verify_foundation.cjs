const assert = require("node:assert/strict");
const { test } = require("node:test");
const { configureEnvironment } = require("./environment.cjs");
const noView = require("./raycast-api.cjs");
const view = require("./view-api.cjs");

const definition = {
  name: "choice",
  type: "dropdown",
  required: true,
  title: "Choice",
  description: "Choose a value",
  default: "one",
  data: [{ title: "One", value: "one" }, { title: "Two", value: "two" }],
};

test("view module imports see scoped preference metadata and resolved values", async () => {
  const imported = view.preferences;
  const input = {
    preferences: JSON.parse('{"choice":"two","active":false,"__proto__":"configured"}'),
    preferenceDefinitions: [
      { ...definition, title: "Shared choice" },
      definition,
      { name: "missing", type: "textfield", placeholder: "Type here", value: "unresolved" },
    ],
  };
  view.prepareInput(input);
  assert.equal(imported.choice.value, "two");
  assert.equal(imported.toString, undefined);

  const reply = await view.render(() => {
    assert.deepEqual(imported.choice, { ...definition, value: "two" });
    assert.equal(imported.active.type, "checkbox");
    assert.equal(imported.active.value, false);
    assert.equal(imported.__proto__.value, "configured");
    assert.equal(imported.missing.placeholder, "Type here");
    assert.equal("value" in imported.missing, false);
    assert.equal(Reflect.set(imported.choice.data[0], "value", "changed"), false);
    assert.equal(Reflect.set(imported, "choice", {}), false);
    assert.equal(Reflect.deleteProperty(imported, "choice"), false);
    assert.equal(Reflect.setPrototypeOf(imported, {}), false);
    assert.deepEqual(Object.keys(imported).sort(), ["__proto__", "active", "choice", "missing"]);
    assert.deepEqual(Object.fromEntries(
      Object.entries(imported).filter(([, field]) => "value" in field).map(([name, field]) => [name, field.value])
    ), view.getPreferenceValues());
    return view.Detail({ markdown: imported.choice.value });
  }, input);
  assert.equal(reply.detail.markdown, "two");
  view.prepareInput({});
  assert.deepEqual(Object.keys(imported), []);
});

test("no-view preferences use the existing broker snapshot and support legacy scalar payloads", async (t) => {
  const imported = noView.preferences;
  const request = t.mock.method(noView, "request", async () => JSON.stringify({
    preferences: { choice: "two" },
    preferenceDefinitions: [definition],
  }));
  await noView.loadPreferences();
  assert.deepEqual(imported.choice, { ...definition, value: "two" });
  assert.equal(imported.choice.value, noView.getPreferenceValues().choice);
  assert.deepEqual(request.mock.calls.map(({ arguments: args }) => args), [["preferences.read", ""]]);

  request.mock.mockImplementation(async () => '{"choice":"one"}');
  await noView.loadPreferences();
  assert.equal(imported.choice.value, "one");
  assert.equal(imported.choice.type, "textfield");
});

test("useId remains stable through rerenders and distinguishes calls and commands", async () => {
  const pairs = [];
  const command = () => {
    const first = view.useId();
    const [query, setQuery] = view.useState("");
    const second = view.useId();
    pairs.push([first, second, query]);
    return view.List({ onSearchTextChange: setQuery });
  };

  configureEnvironment({ ownerOrAuthorName: "example", extensionName: "fixture", entryPointName: "first" });
  await view.render(command, { query: "test" });
  assert.equal(typeof pairs[0][0], "string");
  assert.notEqual(pairs[0][0], pairs[0][1]);
  assert.deepEqual(pairs, [
    [...pairs[0].slice(0, 2), ""],
    [...pairs[0].slice(0, 2), "test"],
  ]);

  configureEnvironment({ ownerOrAuthorName: "example", extensionName: "fixture", entryPointName: "second" });
  await view.render(command, {});
  assert.notEqual(pairs[0][0], pairs[2][0]);
});

test("both adapters expose the same immutable keyboard key equivalents", () => {
  const names = [
    "return", "delete", "deleteForward", "tab", "arrowUp", "arrowDown", "arrowLeft", "arrowRight",
    "pageUp", "pageDown", "home", "end", "space", "escape", "enter", "backspace",
  ];
  assert.equal(view.specialKeys, noView.specialKeys);
  assert.equal(Object.isFrozen(view.specialKeys), true);
  assert.deepEqual(Object.keys(view.specialKeys), names);
  assert.deepEqual(Object.values(view.specialKeys), names);
});
