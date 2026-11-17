const assert = require("node:assert/strict");
const test = require("node:test");
const noView = require("./raycast-api.cjs");
const { Action, ActionPanel, ActionPanelItem, Alert, AlertActionStyle, Detail, confirmAlert, open, render } =
  require("./view-api.cjs");

test("ActionPanelItem reuses the modern action component, styles, and supported built-ins", async () => {
  assert.equal(ActionPanelItem, Action);
  assert.equal(ActionPanelItem.CopyToClipboard, Action.CopyToClipboard);
  assert.equal(ActionPanelItem.OpenInBrowser, Action.OpenInBrowser);

  let calls = 0;
  const command = () => Detail({ actions: ActionPanel({ children: [
    ActionPanelItem({ title: "Remove", style: ActionPanelItem.Style.Destructive, onAction: () => calls++ }),
    ActionPanelItem.CopyToClipboard({ title: "Copy", content: "示例" }),
  ] }) });
  const snapshot = await render(command, {});
  assert.equal(calls, 0);
  assert.deepEqual(snapshot.detail.actions.map(({ kind, destructive }) => [kind, destructive]), [
    ["callback", true], ["copy", false],
  ]);
  assert.deepEqual(await render(command, { action: { row: 0, id: 0 } }), { kind: "action" });
  assert.equal(calls, 1);
  assert.deepEqual(await render(command, { action: { row: 0, id: 1 } }), { kind: "copy", text: "示例" });
});

test("Alert validates options and relays the host choice to the selected callback", async (t) => {
  assert.equal(Alert.ActionStyle, AlertActionStyle);
  assert.equal(noView.Alert, Alert);
  assert.equal(noView.AlertActionStyle, AlertActionStyle);
  assert.deepEqual(AlertActionStyle, { Default: "default", Cancel: "cancel", Destructive: "destructive" });

  let calls = 0;
  let dismissed = 0;
  let response = "primary";
  const request = t.mock.method(noView, "request", async (topic, payload) => {
    assert.equal(topic, "feedback.confirmAlert");
    const value = JSON.parse(payload);
    assert.equal(value.title, "Confirm");
    assert.deepEqual(value.primaryAction, { title: "Continue", style: "destructive" });
    assert.deepEqual(value.dismissAction, { title: "Stay", style: "cancel" });
    assert.equal(value.rememberUserChoice, true);
    assert.equal(JSON.parse(Buffer.from(value.icon, "base64")).light.symbol, noView.Icon.Circle);
    return response;
  });
  const command = () => Detail({ actions: ActionPanel({ children: ActionPanelItem({
    title: "Open after confirmation",
    async onAction() {
      await confirmAlert({
        title: "Confirm",
        icon: noView.Icon.Circle,
        rememberUserChoice: true,
        dismissAction: { title: "Stay", onAction: () => dismissed++ },
        primaryAction: {
          title: "Continue",
          style: AlertActionStyle.Destructive,
          onAction: async () => {
            calls++;
            await open("https://example.com/");
          },
        },
      });
    },
  }) }) });
  const action = { row: 0, id: 0 };
  await assert.rejects(render(command, { action }), /authorized view action/);
  assert.equal(calls, 0);
  const input = { action, liveNavigation: true, navigationCloseAllowed: true };
  assert.deepEqual(await render(command, input), {
    kind: "openURL", text: "https://example.com/",
  });
  assert.equal(calls, 1);
  response = "dismiss";
  assert.deepEqual(await render(command, input), { kind: "action" });
  assert.equal(dismissed, 1);
  await assert.rejects(noView.confirmAlert({ title: " ", primaryAction: {} }), /Invalid alert title/);
  assert.equal(request.mock.callCount(), 2);
});
