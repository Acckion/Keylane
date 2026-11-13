const assert = require("node:assert/strict");
const test = require("node:test");
const { Action, ActionPanel, Form, FormCheckbox, FormTextField, LocalStorage, render, useRef, useState } = require("./view-api.cjs");

test("form dropdown searches and selects grouped async options without losing the current value", async () => {
  const { FormDropdown, FormDropdownItem, Icon } = require("./view-api.cjs");
  assert.equal(FormDropdown, Form.Dropdown);
  assert.equal(FormDropdownItem, Form.Dropdown.Item);
  assert.equal(Form.DropdownItem, FormDropdownItem);
  const focus = { id: "editor", kind: "focus", value: "first" };
  const search = (value) => ({ id: "editor", kind: "search", value });
  const change = { id: "editor", kind: "change", value: "second" };
  function command() {
    const [query, setQuery] = useState("");
    const [value, setValue] = useState("first");
    const [notice, setNotice] = useState("");
    const field = useRef(null);
    return Form({
      navigationTitle: notice,
      children: FormDropdown({
        id: "editor", value, ref: field, defaultValue: "first", storeValue: true, throttle: true,
        filtering: { keepSectionOrder: true }, isLoading: query === "wait",
        placeholder: "Search editors", onChange: setValue,
        onFocus(event) { setNotice(event.target.value); },
        async onSearchTextChange(text) { await Promise.resolve(); setQuery(text); },
        children: FormDropdown.Section({ title: "Utilities", children: query === "" ? [
          FormDropdownItem({ value: "first", title: "First", keywords: ["default"], icon: Icon.Circle }),
        ] : query === "code" ? [
          FormDropdownItem({ value: "second", title: "Second", keywords: ["编辑器"], icon: Icon.Code }),
        ] : [] }),
      }),
      actions: ActionPanel({ children: Action.SubmitForm({
        onSubmit({ editor }) {
          assert.equal(editor, "second");
          field.current.focus();
          field.current.reset();
        },
      }) }),
    });
  }
  const before = await render(command, { formEvents: [focus] });
  assert.equal(before.form.navigationTitle, "first");
  const searching = await render(command, { formEvents: [focus, search("code")] });
  const [option] = searching.form.fields[0].options;
  assert.equal(option.value, "second");
  assert.equal(option.sectionTitle, "Utilities");
  assert.deepEqual(option.keywords, ["编辑器"]);
  assert.equal(option.imageDescriptor.light.symbol, Icon.Code);
  assert.equal(searching.form.fields[0].value, "first");
  assert.equal(searching.form.fields[0].retainedOption.value, "first");
  assert.deepEqual(searching.form.fields[0].search, {
    query: "code", observesSearch: true, nativeFiltering: true, keepSectionOrder: true, isLoading: false, throttle: true,
  });
  const formEvents = [focus, search("code"), change, search("wait")];
  const hidden = await render(command, { formEvents });
  assert.equal(hidden.form.fields[0].value, "second");
  assert.equal(hidden.form.fields[0].retainedOption.value, "second");
  assert.equal(hidden.form.fields[0].search.isLoading, true);
  assert.equal(hidden.form.fields[0].storeValue, true);
  const result = await render(command, { action: { row: 0, id: 0 }, formValues: { editor: "second" }, formEvents });
  assert.equal(result.formCommands.focus, "editor");
  assert.equal(result.formCommands.reset.editor, "first");
  await assert.rejects(render(command, { formEvents: [search("x".repeat(257))] }), /Invalid form field event/);
});

test("uncontrolled dynamic dropdowns preserve only selections observed in the same form", async () => {
  function command() {
    const [query, setQuery] = useState("");
    return Form({ children: Form.Dropdown({
      id: "choice", defaultValue: "first", onSearchTextChange: setQuery,
      children: Form.Dropdown.Item({ value: query || "first", title: query || "First" }),
    }) });
  }
  const input = { formEvents: [
    { id: "choice", kind: "search", value: "second" }, { id: "choice", kind: "change", value: "second" },
    { id: "choice", kind: "search", value: "third" },
  ], formDropdownValues: { choice: "second" } };
  const result = await render(command, input);
  assert.equal(result.form.fields[0].value, "second");
  assert.equal(result.form.fields[0].retainedOption.title, "second");
  assert.equal(result.form.fields[0].search.nativeFiltering, false);
  const forged = await render(command, { ...input, formDropdownValues: { choice: "unknown" } });
  assert.notEqual(forged.form.fields[0].value, "unknown");
  await assert.rejects(render(() => Form({ children: Form.Dropdown({
    id: "choice", onSearchTextChange: () => LocalStorage.setItem("blocked", "value"),
  }) }), { storage: {}, formEvents: [{ id: "choice", kind: "search", value: "query" }] }), /LocalStorage writes are unavailable/);
});

test("SubmitForm distinguishes async rejection from success and returns refreshed validation", async () => {
  const { SubmitFormAction } = require("./view-api.cjs");
  assert.equal(SubmitFormAction, Action.SubmitForm);
  assert.equal(ActionPanel.Item.SubmitForm, Action.SubmitForm);
  function form() {
    const [error, setError] = useState(undefined);
    return Form({
      children: Form.TextField({ id: "name", error, storeValue: true }),
      actions: ActionPanel({ children: SubmitFormAction({
        style: Action.Style.Destructive,
        async onSubmit({ name }) {
          await Promise.resolve();
          if (name === "valid") return true;
          setError("Use a different name");
          return false;
        },
      }) }),
    });
  }
  const action = { row: 0, id: 0 };
  const [description] = (await render(form, {})).formActions;
  assert.equal(description.title, "Submit Form");
  assert.equal(description.destructive, true);
  const failed = await render(form, { action, formValues: { name: "invalid" } });
  assert.equal(failed.kind, "formRejected");
  assert.equal(failed.form.fields[0].error, "Use a different name");
  assert.deepEqual(await render(form, { action, formValues: { name: "valid" } }), { kind: "action" });
  const sensitive = () => Form({
    children: Form.PasswordField({ id: "secret" }),
    actions: ActionPanel({ children: SubmitFormAction({ onSubmit: () => false }) }),
  });
  assert.deepEqual(await render(sensitive, { action, formValues: { secret: "fixture" }, sensitiveFormSubmission: true }),
    { kind: "formRejected" });
  const withoutHandler = () => Form({
    children: Form.TextField({ id: "name" }),
    actions: ActionPanel({ children: SubmitFormAction({}) }),
  });
  assert.deepEqual(await render(withoutHandler, { action, formValues: { name: "valid" } }), { kind: "action" });
});

function command() {
  const [name, setName] = useState("");
  const [error, setError] = useState(undefined);
  const [checked, setChecked] = useState(false);
  const [status, setStatus] = useState("");
  const field = useRef(null);
  return Form({
    navigationTitle: status,
    children: [
      FormTextField({
        id: "name", ref: field, value: name, storeValue: true, error,
        onChange: setName,
        onFocus: (event) => setStatus(`${event.type}:${event.target.id}`),
        onBlur: (event) => setError(event.target.value.length < 3 ? "Too short" : undefined),
      }),
      FormCheckbox({ id: "checked", label: "Checked", value: checked, onChange: setChecked, storeValue: true }),
      Form.TextArea({ id: "notes", defaultValue: "initial", onChange: (value) => setStatus(value) }),
    ],
    actions: ActionPanel({ children: Action.SubmitForm({
      onSubmit(values) {
        assert.equal(values.name, name);
        assert.equal(values.checked, checked);
        field.current.focus();
        field.current.reset();
      },
    }) }),
  });
}

test("form field replay supports controlled values, validation and focus payloads before submit", async () => {
  const first = await render(command, {});
  assert.deepEqual(first.form.fields[0].events, ["change", "focus", "blur"]);
  assert.equal(first.form.fields[0].controlled, true);
  assert.equal(first.form.fields[0].storeValue, true);
  const focus = { id: "name", kind: "focus", value: "" };
  assert.equal((await render(command, { formEvents: [focus] })).form.navigationTitle, "focus:name");
  const short = [
    focus, { id: "name", kind: "change", value: "中" }, { id: "name", kind: "blur", value: "中" },
  ];
  const failed = await render(command, { formEvents: short });
  assert.equal(failed.form.fields[0].error, "Too short");
  const action = { row: 0, id: 0 };
  const formValues = { name: "中文名", checked: true, notes: "Draft" };
  await assert.rejects(render(command, { action, formValues, formEvents: short }), /Form is unavailable/);
  const valid = [
    focus, { id: "name", kind: "change", value: "中文名" },
    { id: "name", kind: "blur", value: "中文名" },
    { id: "checked", kind: "change", value: true },
    { id: "notes", kind: "change", value: "Draft" },
  ];
  const refreshed = await render(command, { formEvents: valid });
  assert.equal(refreshed.form.fields[0].value, "中文名");
  assert.equal(refreshed.form.fields[1].value, true);
  assert.equal(refreshed.form.navigationTitle, "Draft");
  await assert.rejects(render(command, { action, formValues: { ...formValues, name: "mismatch" }, formEvents: valid }),
    /Invalid controlled Form value/);
  const submitted = await render(command, { action, formValues, formEvents: valid });
  assert.equal(submitted.kind, "action");
  assert.equal(submitted.formCommands.focus, "name");
  assert.equal(submitted.formCommands.reset.name, "");
});

test("form field events cannot replay passwords or obtain storage write grants", async () => {
  const mixed = () => Form({ children: [
    Form.PasswordField({ id: "secret", onChange: () => assert.fail("password event replay") }),
    Form.TextField({ id: "name", onChange: () => LocalStorage.setItem("secret", "blocked") }),
  ] });
  const password = await render(mixed, { formEvents: [{ id: "secret", kind: "change", value: "synthetic" }] });
  assert.equal(password.form.fields[0].value, "");
  assert.equal(password.form.fields[0].events, undefined);
  await assert.rejects(render(mixed, {
    storage: {}, formEvents: [{ id: "name", kind: "change", value: "synthetic" }],
  }), /LocalStorage writes are unavailable/);
  await assert.rejects(render(command, { formEvents: [{ id: "name", kind: "construct", value: "x" }] }),
    /Invalid form field event/);
});

test("date and tag interactions keep their SDK types through focus, selection, clearing, and reset", async () => {
  const defaultDay = "2026-11-12T00:00:00.000Z";
  const chosenDay = "2026-11-13T00:00:00.000Z";
  const tag = (value) => Form.TagPicker.Item({ title: value, value });
  function command() {
    const [date, setDate] = useState(new Date(defaultDay));
    const [tags, setTags] = useState(["a"]);
    const [status, setStatus] = useState(undefined);
    const dayRef = useRef(null);
    const tagRef = useRef(null);
    return Form({
      navigationTitle: status,
      children: [
        Form.DatePicker({
          id: "day", type: Form.DatePicker.Type.Date, min: new Date(defaultDay), value: date, defaultValue: null,
          ref: dayRef, storeValue: true,
          onChange(day) {
            assert.ok(day === null || Form.DatePicker.isFullDay(day));
            setDate(day);
          },
          onBlur({ target }) { setStatus(target.value.toISOString()); },
        }),
        Form.TagPicker({
          id: "tags", value: tags, defaultValue: ["a"], ref: tagRef, storeValue: true,
          children: [tag("a"), tag("中")], onChange: setTags,
          onFocus({ target }) { setStatus(target.value.join("|")); },
        }),
      ],
      actions: ActionPanel({ children: Action.SubmitForm({ onSubmit(values) {
        assert.equal(values.day, null);
        assert.deepEqual(values.tags, ["中", "a"]);
        dayRef.current.focus();
        dayRef.current.reset();
        tagRef.current.reset();
      } }) }),
    });
  }
  const changeDay = { id: "day", kind: "change", value: chosenDay };
  const blurDay = { id: "day", kind: "blur", value: chosenDay };
  const dayResult = await render(command, { formEvents: [changeDay, blurDay] });
  assert.equal(dayResult.form.navigationTitle, chosenDay);
  assert.equal(dayResult.form.fields[0].value, chosenDay);
  assert.equal(dayResult.form.fields[0].storeValue, true);
  assert.deepEqual(dayResult.form.fields[1].events, ["change", "focus"]);

  const changeTags = { id: "tags", kind: "change", value: ["中", "a"] };
  const focusTags = { id: "tags", kind: "focus", value: ["中", "a"] };
  const clearDay = { id: "day", kind: "change", value: null };
  const formEvents = [clearDay, changeTags, focusTags];
  const edited = await render(command, { formEvents });
  assert.equal(edited.form.navigationTitle, "中|a");
  assert.equal(edited.form.fields[0].value, null);
  const action = { row: 0, id: 0 };
  const formValues = { day: null, tags: ["中", "a"] };
  const reply = await render(command, { action, formEvents, formValues });
  assert.equal(reply.formCommands.focus, "day");
  assert.deepEqual({ ...reply.formCommands.reset }, { day: null, tags: ["a"] });
  await assert.rejects(render(command, { action, formEvents, formValues: { ...formValues, tags: ["a"] } }),
    /Invalid controlled Form value/);
  const forged = await render(command, { formEvents: [
    { ...changeDay, value: "2026-11-10T00:00:00.000Z" }, { ...changeTags, value: ["unknown"] },
  ] });
  assert.deepEqual(forged.form.fields.map(({ value }) => value), [defaultDay, ["a"]]);
});

test("form replay settles async dropdown options before a following change", async () => {
  const { usePromise } = require("./raycast-utils.cjs").utilitiesFor(() => require("./view-api.cjs"));
  const { useEffect } = require("./view-api.cjs");
  const calls = [];
  const command = () => {
    const [query, setQuery] = useState("");
    const [value, setValue] = useState("default");
    const options = usePromise(async (text) => {
      calls.push(text);
      return [text || "default"];
    }, [query]);
    const detail = usePromise(async (selected) => `Selected ${selected}`, [value]);
    useEffect(async () => {
      if (!query) return;
      await assert.rejects(LocalStorage.setItem("blocked", query), /LocalStorage writes are unavailable/);
      calls.push("write denied");
    }, [query]);
    return Form({ navigationTitle: detail.data, children: Form.Dropdown({
      id: "choice", value, onChange: setValue, onSearchTextChange: setQuery,
      isLoading: options.isLoading,
      children: options.data?.map((item) => Form.Dropdown.Item({ value: item, title: item })),
    }) });
  };
  const { form } = await render(command, { storage: {}, formEvents: [
    { id: "choice", kind: "search", value: "new" },
    { id: "choice", kind: "change", value: "new" },
  ] });
  assert.equal(form.navigationTitle, "Selected new");
  assert.equal(form.fields[0].value, "new");
  assert.equal(form.fields[0].search.isLoading, false);
  assert.deepEqual(calls, ["", "new", "write denied"]);
});

test("form replay uses one effect pass budget for all events", async () => {
  const { useEffect } = require("./view-api.cjs");
  let runs = 0;
  const command = () => {
    const [query, setQuery] = useState("");
    useEffect(() => { runs++; }, [query]);
    return Form({ children: Form.Dropdown({ id: "choice", onSearchTextChange: setQuery }) });
  };
  const formEvents = Array.from({ length: 8 }, (_, index) => ({
    id: "choice", kind: "search", value: String(index),
  }));
  await assert.rejects(render(command, { formEvents }), /View effects did not settle/);
  assert.equal(runs, 8);
});
