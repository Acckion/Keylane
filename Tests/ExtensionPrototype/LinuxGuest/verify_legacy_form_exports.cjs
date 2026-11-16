const assert = require("node:assert/strict");
const test = require("node:test");
const { Action, ActionPanel, Form, FormCheckbox, FormDropdown, FormDropdownItem, FormDropdownSection, render } = require("./view-api.cjs");

test("legacy form exports share the current form components", () => {
  assert.equal(FormCheckbox, Form.Checkbox);
  assert.equal(FormDropdown, Form.Dropdown);
  assert.equal(FormDropdownItem, Form.Dropdown.Item);
  assert.equal(Form.DropdownItem, Form.Dropdown.Item);
  assert.equal(Form.DropdownSection, Form.Dropdown.Section);
  assert.equal(FormDropdownSection, Form.Dropdown.Section);
  assert.equal(Form.TagPickerItem, Form.TagPicker.Item);
});

test("legacy form fields render defaults and validate typed submissions", async () => {
  const submissions = [];
  const command = () => Form({
    children: [
      FormCheckbox({ id: "enabled", label: "Enable", defaultValue: true }),
      FormDropdown({
        id: "mode",
        defaultValue: "blue",
        children: Form.DropdownSection({
          title: "Colors",
          children: [
            Form.DropdownItem({ value: "blue", title: "Blue" }),
            FormDropdownItem({ value: "red", title: "Red" }),
          ],
        }),
      }),
      Form.TagPicker({
        id: "labels",
        defaultValue: ["one"],
        children: [
          Form.TagPickerItem({ value: "one", title: "One" }),
          Form.TagPickerItem({ value: "two", title: "Two" }),
        ],
      }),
    ],
    actions: ActionPanel({
      children: Action.SubmitForm({
        title: "Apply",
        onSubmit: (values) => submissions.push(values),
      }),
    }),
  });

  const snapshot = await render(command, {});
  assert.equal(snapshot.kind, "form");
  assert.deepEqual(snapshot.form.fields.map(({ kind, value }) => [kind, value]), [
    ["checkbox", true],
    ["dropdown", "blue"],
    ["tagPicker", ["one"]],
  ]);
  assert.deepEqual(snapshot.form.fields[1].options, [
    { value: "blue", title: "Blue", section: 0, sectionTitle: "Colors" },
    { value: "red", title: "Red", section: 0, sectionTitle: "Colors" },
  ]);

  assert.deepEqual(snapshot.form.fields[2].options, [
    { value: "one", title: "One" },
    { value: "two", title: "Two" },
  ]);

  const action = { row: 0, id: 0 };
  const formValues = { enabled: false, mode: "red", labels: ["two"] };
  assert.deepEqual(await render(command, { action, formValues }), { kind: "action" });
  await assert.rejects(render(command, { action, formValues: { ...formValues, mode: "unknown" } }),
    /Invalid Form dropdown selection/);
  assert.deepEqual(submissions, [formValues]);
});

test("dropdown sections preserve order with empty, untitled, and repeated-title sections", async () => {
  const item = (value) => Form.Dropdown.Item({ title: value, value });
  const snapshot = await render(() => Form({ children: Form.Dropdown({ id: "choice", defaultValue: "second", children: [
    item("loose"),
    Form.Dropdown.Section({ title: "Empty" }),
    Form.DropdownSection({ title: "Same", children: item("first") }),
    FormDropdownSection({ title: "Same", children: item("second") }),
    Form.Dropdown.Section({ children: item("untitled") }),
  ] }) }), {});
  const field = snapshot.form.fields[0];
  assert.equal(field.value, "second");
  assert.deepEqual(field.options.map(({ value, section, sectionTitle }) => [value, section, sectionTitle]), [
    ["loose", undefined, undefined], ["first", 2, "Same"],
    ["second", 3, "Same"], ["untitled", 4, undefined],
  ]);
});
