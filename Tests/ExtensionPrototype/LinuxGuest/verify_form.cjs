const assert = require("node:assert/strict");
const test = require("node:test");
const { formComponents, describeForm, submitForm } = require("./form-api.cjs");

const component = (type) => (props = {}) => ({ type, props });
const children = ({ props }) => [props.children].flat(Infinity).filter(Boolean);
const Form = formComponents(component);
const Submit = component("submitForm");

const root = () => Form({
  navigationTitle: "Reviewed form",
  children: [
    Form.Description({ text: "Demo" }),
    Form.TextField({ id: "name", title: "Name", defaultValue: "默认", value: "初始", autoFocus: true }),
    Form.TextArea({ id: "notes", defaultValue: "示例" }),
    Form.Checkbox({ id: "confirmed", label: "Confirm", defaultValue: true }),
    Form.Separator(),
    Form.Dropdown({ id: "mode", defaultValue: "b", children: [
      Form.Dropdown.Item({ value: "a", title: "First" }),
      Form.Dropdown.Item({ value: "b", title: "Second" }),
    ] }),
  ],
});

test("Form serializes typed defaults, static content, and dropdown choices", () => {
  const snapshot = describeForm(root(), children);
  assert.equal(snapshot.navigationTitle, "Reviewed form");
  assert.deepEqual(snapshot.fields.map((field) => field.kind), [
    "description", "textField", "textArea", "checkbox", "separator", "dropdown",
  ]);
  assert.deepEqual(snapshot.fields.filter((field) => field.id).map(({ id, value }) => [id, value]), [
    ["name", "初始"], ["notes", "示例"], ["confirmed", true], ["mode", "b"],
  ]);
  assert.deepEqual(snapshot.fields[5].options, [{ value: "a", title: "First" }, { value: "b", title: "Second" }]);
});

test("SubmitForm passes the declared values once and rejects forged or mismatched values", async () => {
  const values = { name: "名字", notes: "多行\n示例", confirmed: false, mode: "a" };
  const received = [];
  const action = Submit({ onSubmit: async (input) => received.push(input) });
  await submitForm(root(), children, action, values);
  assert.deepEqual(received, [values]);

  await assert.rejects(submitForm(root(), children, action, { ...values, unexpected: true }), /Invalid Form values/);
  await assert.rejects(submitForm(root(), children, action, { ...values, confirmed: "false" }), /Invalid Form field value/);
  await assert.rejects(submitForm(root(), children, action, { ...values, mode: "forged" }), /Invalid Form dropdown selection/);
  assert.deepEqual(received, [values]);
});

test("loading, field errors, and malformed form schemas stop submission", async () => {
  const unexpected = Submit({ onSubmit: () => assert.fail("must not submit") });
  await assert.rejects(submitForm(Form({ isLoading: true }), children, unexpected, {}), /unavailable/);
  const invalid = Form({ children: Form.TextField({ id: "name", error: "Missing name" }) });
  await assert.rejects(submitForm(invalid, children, unexpected, { name: "" }), /unavailable/);
  assert.throws(() => describeForm(Form({ children: [
    Form.TextField({ id: "duplicate" }), Form.Checkbox({ id: "duplicate" }),
  ] }), children), /Invalid Form field ID/);
  assert.throws(() => describeForm(Form({ children: Form.Dropdown({ id: "d", children: [
    Form.Dropdown.Item({ title: "A", value: "same" }), Form.Dropdown.Item({ title: "B", value: "same" }),
  ] }) }), children), /Invalid Form.Dropdown.Item/);
});

test("date fields submit Date objects, preserve null, and distinguish all-day values", async () => {
  const fields = Form({ children: [
    Form.DatePicker({
      id: "day", type: Form.DatePicker.Type.Date,
      defaultValue: new Date("2026-01-02T16:40:21.123Z"),
      min: new Date("2026-01-01T23:59:59.999Z"),
      max: new Date("2026-01-03T08:00:00.000Z"),
    }),
    Form.DatePicker({ id: "instant", defaultValue: new Date("1955-02-24T06:30:15.123Z") }),
    Form.DatePicker({ id: "unset", defaultValue: new Date(), value: null }),
  ] });
  const snapshot = describeForm(fields, children);
  const selected = {
    day: "2026-01-03T00:00:00.000Z", instant: "1955-02-24T06:30:15.123Z", unset: null,
  };
  assert.equal(snapshot.fields[0].value, "2026-01-02T00:00:00.000Z");
  assert.equal(snapshot.fields[0].minimum, "2026-01-01T00:00:00.000Z");
  assert.equal(snapshot.fields[0].maximum, "2026-01-03T00:00:00.000Z");
  assert.equal(snapshot.fields[1].dateType, "date_time");
  assert.equal(snapshot.fields[2].value, null);
  const result = [];
  const action = Submit({ onSubmit(values) { result.push(values); } });
  await submitForm(fields, children, action, selected);
  assert.equal(result.length, 1);
  assert.deepEqual(result[0], { day: new Date(selected.day), instant: new Date(selected.instant), unset: null });
  assert.equal(Form.DatePicker.isFullDay(result[0].day), true);
  assert.equal(Form.DatePicker.isFullDay(result[0].instant), false);
  assert.equal(Form.DatePicker.isFullDay(null), false);
  await assert.rejects(submitForm(fields, children, action, { ...selected, day: "2026-01-03T01:00:00.000Z" }), /Invalid Form date/);
  await assert.rejects(submitForm(fields, children, action, { ...selected, day: "2026-01-04T00:00:00.000Z" }), /Invalid Form date/);
  await assert.rejects(submitForm(fields, children, action, { ...selected, instant: "1955-02-30T06:30:15.123Z" }), /Invalid Form date/);
  assert.equal(result.length, 1);
  assert.throws(() => describeForm(Form({ children: Form.DatePicker({
    id: "inverted", min: new Date("2026-01-03"), max: new Date("2026-01-01"),
  }) }), children), /Invalid Form date bounds/);
});

test("tag and grouped dropdown fields preserve declared option values", async () => {
  const fields = Form({ children: [
    Form.TagPicker({ id: "tags", defaultValue: ["咖啡", "missing", "咖啡"], children: [
      Form.TagPicker.Item({ title: "Coffee", value: "咖啡" }),
      Form.TagPicker.Item({ title: "Tea", value: "茶" }),
    ] }),
    Form.Dropdown({ id: "mode", children: [
      Form.Dropdown.Item({ title: "None", value: "" }),
      Form.Dropdown.Section({ title: "Colors", children: Form.Dropdown.Item({ title: "Blue", value: "b" }) }),
    ] }),
  ] });
  const snapshot = describeForm(fields, children);
  assert.deepEqual(snapshot.fields[0].value, ["咖啡"]);
  assert.deepEqual(snapshot.fields[1].options, [
    { value: "", title: "None" },
    { value: "b", title: "Blue", section: 1, sectionTitle: "Colors" },
  ]);
  const result = [];
  const action = Submit({ onSubmit(values) { result.push(values); } });
  const selected = { tags: ["茶", "咖啡"], mode: "b" };
  await submitForm(fields, children, action, selected);
  assert.deepEqual(result, [selected]);
  for (const tags of [["咖啡", "咖啡"], ["missing"], "茶", [1]]) {
    await assert.rejects(submitForm(fields, children, action, { ...selected, tags }), /Invalid Form tag selection/);
  }
  assert.equal(result.length, 1);
});

test("password fields serialize an empty snapshot and pass a string only to the explicit callback", async () => {
  const { hasPasswordField } = require("./form-api.cjs");
  const snapshot = Form({ children: Form.PasswordField({
    id: "password", defaultValue: "guest-default", value: "guest-value", storeValue: true,
  }) });
  assert.equal(hasPasswordField(snapshot, children), true);
  assert.equal(describeForm(snapshot, children).fields[0].value, "");
  assert.doesNotMatch(JSON.stringify(describeForm(snapshot, children)), /guest-default|guest-value|storeValue/);

  const submitted = [];
  const action = Submit({ onSubmit: (values) => submitted.push(values) });
  await submitForm(snapshot, children, action, { password: "synthetic-only" });
  await assert.rejects(submitForm(snapshot, children, action, { password: false }), /password value/);
  await assert.rejects(submitForm(snapshot, children, action, { password: "密".repeat(342) }), /password value/);
  assert.deepEqual(submitted, [{ password: "synthetic-only" }]);
});

test("file picker keeps native selection options and submits only bounded absolute paths", async () => {
  const snapshot = Form({ children: Form.FilePicker({
    id: "files", canChooseFiles: false, canChooseDirectories: true,
    allowMultipleSelection: false, showHiddenFiles: true, defaultValue: ["/host-default"],
  }) });
  const field = describeForm(snapshot, children).fields[0];
  assert.deepEqual(field.value, []);
  assert.deepEqual(field.picker, {
    canChooseFiles: false, canChooseDirectories: true, allowMultipleSelection: false, showHiddenFiles: true,
  });
  const submitted = [];
  const action = Submit({ onSubmit: (values) => submitted.push(values) });
  await submitForm(snapshot, children, action, { files: ["/synthetic/资料"] });
  for (const files of [["relative"], ["file:///synthetic"], ["//server/path"], ["/one", "/two"], ["/bad\nline"]]) {
    await assert.rejects(submitForm(snapshot, children, action, { files }), /Invalid Form file selection/);
  }
  assert.deepEqual(submitted, [{ files: ["/synthetic/资料"] }]);

  const defaults = describeForm(Form({ children: Form.FilePicker({ id: "default" }) }), children).fields[0];
  assert.deepEqual(defaults.picker, {
    canChooseFiles: true, canChooseDirectories: false, allowMultipleSelection: true, showHiddenFiles: false,
  });
});

test("form links are web-only header accessories and never submit values", async () => {
  const snapshot = Form({ searchBarAccessory: Form.LinkAccessory({
    target: "HTTPS://example.invalid/帮助", text: "文档",
  }) });
  assert.deepEqual(describeForm(snapshot, children).linkAccessory, {
    target: "https://example.invalid/%E5%B8%AE%E5%8A%A9", text: "文档",
  });
  const received = [];
  await submitForm(snapshot, children, Submit({ onSubmit: (values) => received.push(values) }), {});
  assert.deepEqual(received, [{}]);

  const invalid = Form({ searchBarAccessory: Form.LinkAccessory({ target: "file:///private/tmp", text: "File" }) });
  assert.equal(describeForm(invalid, children).linkAccessory, undefined);
});

test("password submissions suppress extension output and storage effects", async () => {
  const api = require("./view-api.cjs");
  const request = { action: { row: 0, id: 0 }, formValues: { password: "synthetic-only" }, storage: {} };
  const renderForm = (onSubmit) => () => api.Form({
    children: api.Form.PasswordField({ id: "password" }),
    actions: api.ActionPanel({ children: api.Action.SubmitForm({ onSubmit }) }),
  });
  const command = renderForm(async ({ password }) => {
    await assert.rejects(api.LocalStorage.setItem("password", password), /unavailable/);
    await api.showToast({ style: api.Toast.Style.Failure, title: password });
  });
  assert.deepEqual(await api.render(command, request), { kind: "error" });
  const throwing = renderForm(({ password }) => { throw new Error(password); });
  assert.deepEqual(await api.render(throwing, request), { kind: "error" });
});
