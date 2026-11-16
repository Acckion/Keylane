const assert = require("node:assert/strict");
const test = require("node:test");
const { Action, ActionPanel, Form, FormSeparator, FormTextArea, FormTextField, render } = require("./view-api.cjs");

test("legacy text and separator exports are the current form components", () => {
  assert.equal(FormSeparator, Form.Separator);
  assert.equal(FormTextArea, Form.TextArea);
  assert.equal(FormTextField, Form.TextField);
});

test("legacy text fields preserve multiline values and exclude the separator from submission", async () => {
  const submissions = [];
  const command = () => Form({
    children: [
      FormTextField({ id: "name", defaultValue: "草稿", value: "标题" }),
      FormSeparator({}),
      FormTextArea({ id: "notes", defaultValue: "第一行\n第二行", enableMarkdown: true }),
    ],
    actions: ActionPanel({
      children: Action.SubmitForm({ onSubmit: (values) => submissions.push(values) }),
    }),
  });

  const snapshot = await render(command, {});
  assert.equal(snapshot.kind, "form");
  assert.deepEqual(snapshot.form.fields.map(({ kind, id, value }) => ({ kind, id, value })), [
    { kind: "textField", id: "name", value: "标题" },
    { kind: "separator", id: undefined, value: undefined },
    { kind: "textArea", id: "notes", value: "第一行\n第二行" },
  ]);

  assert.deepEqual(snapshot.form.fields.map(({ enableMarkdown }) => enableMarkdown), [undefined, undefined, true]);

  const action = { row: 0, id: 0 };
  const formValues = { name: "已编辑", notes: "**一**\n*二*" };
  assert.deepEqual(await render(command, { action, formValues }), { kind: "action" });
  await assert.rejects(render(command, { action, formValues: { ...formValues, notes: 2 } }),
    /Invalid Form field value/);
  await assert.rejects(render(command, { action, formValues: { ...formValues, separator: "" } }),
    /Invalid Form values/);
  assert.deepEqual(submissions, [formValues]);
});
