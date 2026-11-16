const assert = require("node:assert/strict");
const test = require("node:test");
const { formComponents } = require("./form-api.cjs");
const { pickDateComponent, describePickDate, submitPickDate } = require("./date-action.cjs");

const component = (type) => (props = {}) => ({ type, props });
const PickDate = pickDateComponent(component);

test("Action.PickDate exposes SDK values and describes inclusive date or date-time limits", () => {
  assert.deepEqual(PickDate.Type, { Date: "date", DateTime: "date_time" });
  const minimum = new Date("2026-11-03T10:20:30Z");
  const maximum = new Date("2026-11-03T23:59:59Z");
  const onChange = () => assert.fail("describing must not invoke the callback");
  const date = describePickDate(PickDate({ title: "日期", type: PickDate.Type.Date, min: minimum, max: maximum, onChange }));
  assert.deepEqual(date, { kind: "pickDate", pickDate: {
    title: "日期", dateType: "date",
    minimum: "2026-11-03T00:00:00.000Z", maximum: "2026-11-03T00:00:00.000Z",
  } });
  const dateTime = describePickDate(PickDate({ title: "日期和时间", min: minimum, max: maximum, onChange }));
  assert.deepEqual(dateTime, { kind: "pickDate", pickDate: {
    title: "日期和时间", dateType: "date_time",
    minimum: "2026-11-03T10:20:30.000Z", maximum: "2026-11-03T23:59:59.000Z",
  } });
});

test("confirmed dates replay as Date and preserve all-day identity across API helpers", async () => {
  const received = [];
  const onChange = async (date) => { await Promise.resolve(); received.push(date); };
  const formDatePicker = formComponents(component).DatePicker;
  const day = PickDate({ title: "Day", type: PickDate.Type.Date, onChange });
  const time = PickDate({ title: "Time", onChange });
  await submitPickDate(day, "2026-11-03T00:00:00.000Z");
  await submitPickDate(time, "2026-11-03T00:00:00.000Z");
  await submitPickDate(day, null);
  assert.equal(received[0].toISOString(), received[1].toISOString());
  assert.equal(received[2], null);
  assert.equal(PickDate.isFullDay(received[0]), true);
  assert.equal(formDatePicker.isFullDay(received[0]), true);
  const api = require("./view-api.cjs");
  for (const helper of [api.Action.PickDate.isFullDay, api.ActionPanel.Item.PickDate.isFullDay,
                        api.Form.DatePicker.isFullDay]) {
    assert.equal(helper(received[0]), true);
    for (const value of [received[1], received[2], undefined, new Date(received[0])]) {
      assert.equal(helper(value), false);
    }
  }
  received[0].setTime(NaN);
  assert.equal(PickDate.isFullDay(received[0]), false);
});

test("malformed descriptors and rejected replay values never trigger onChange", async () => {
  const onChange = () => assert.fail("must not invoke");
  const minimum = new Date("2026-11-03T00:00:00Z");
  const maximum = new Date("2026-11-04T00:00:00Z");
  const date = PickDate({ title: "Pick", type: PickDate.Type.Date, min: minimum, max: maximum, onChange });
  for (const value of [
    undefined, 42, "not-a-date", "2026-11-02T00:00:00.000Z", "2026-11-05T00:00:00.000Z",
    "2026-11-03T12:00:00.000Z", "2026-11-03T00:00:00.000+00:00",
  ]) {
    await assert.rejects(submitPickDate(date, value), /Invalid Form date/);
  }
  assert.throws(() => describePickDate(PickDate({ title: "Pick" })), /Invalid Action.PickDate/);
  assert.throws(() => describePickDate(PickDate({ title: "Pick", type: "bad", onChange })), /Invalid Form date type/);
  assert.throws(() => describePickDate(PickDate({ title: "Pick", min: maximum, max: minimum, onChange })), /Invalid Form date bounds/);
});

test("reviewed view only replays a PickDate callback after the native confirmation payload", async () => {
  const api = require("./view-api.cjs");
  const confirmed = [];
  const command = () => api.Detail({
    actions: api.ActionPanel({ children: api.Action.PickDate({
      title: "Due date",
      type: api.Action.PickDate.Type.Date,
      onChange: async (value) => {
        confirmed.push(value === null ? null : [value.toISOString(), api.Action.PickDate.isFullDay(value)]);
        if (value) await api.clearSearchBar({ forceScrollToTop: false });
      },
    }) }),
  });
  const selection = { action: { row: 0, id: 0 } };
  const descriptor = await api.render(command, selection);
  assert.equal(descriptor.kind, "pickDate");
  assert.equal(descriptor.pickDate.dateType, "date");
  assert.match(descriptor.dateReceipt, /^[0-9a-f]{64}$/);
  assert.deepEqual(confirmed, []);
  await assert.rejects(api.render(command, { ...selection, pickedDate: null }), /Invalid date selection receipt/);
  const completion = { ...selection, dateReceipt: descriptor.dateReceipt };
  assert.deepEqual(await api.render(command, { ...completion, pickedDate: "2026-11-03T00:00:00.000Z" }),
    { kind: "clearSearchBar", forceScrollToTop: false });
  assert.equal((await api.render(command, { ...completion, pickedDate: null })).kind, "detail");
  assert.deepEqual(confirmed, [["2026-11-03T00:00:00.000Z", true], null]);
});

test("the accepted date updates the current view and receipts cannot select a changed picker", async () => {
  const { Action, ActionPanel, Detail, Icon, render, useState } = require("./view-api.cjs");
  const view = (title) => () => {
    const [selection, setSelection] = useState("unselected");
    return Detail({ markdown: selection, actions: ActionPanel({ children: Action.PickDate({
      title, onChange(value) { setSelection(value?.toISOString() ?? "cleared"); },
    }) }) });
  };
  const action = { row: 0, id: 0 };
  const command = view("Pick a date");
  assert.equal((await render(command, {})).detail.actions[0].icon, Icon.Calendar);
  const { dateReceipt } = await render(command, { action });
  const input = { action, dateReceipt, pickedDate: "2026-11-12T12:34:56.000Z" };
  const result = await render(command, input);
  assert.equal(result.detail.markdown, input.pickedDate);
  assert.equal((await render(command, { ...input, pickedDate: null })).detail.markdown, "cleared");
  await assert.rejects(render(view("Different action"), input), /Invalid date selection receipt/);
});
