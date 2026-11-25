// Uses the same production API adapter and command wrapper as a reviewed extension.
import { useEffect, useRef, useState } from "react";
import { Action, ActionPanel, ActionPanelItem, ActionPanelSection, ActionPanelSubmenu, Detail, PushAction,
  Toast, confirmAlert, showToast, useActionPanel, useId, useNavigation } from "@raycast/api";
import { showFailureToast } from "@raycast/utils";

if (ActionPanelItem !== Action || ActionPanel.Item !== Action || PushAction !== Action.Push ||
    ActionPanelSection !== ActionPanel.Section || ActionPanelSubmenu !== ActionPanel.Submenu ||
    Action.Style.Regular !== "regular" || Action.Style.Destructive !== "destructive")
  throw Error("Unexpected legacy action aliases");

function DetailPage() {
  const { pop } = useNavigation();
  return <Detail markdown="child" navigationTitle="Second page" actions={
    <ActionPanel><Action title="Pop" onAction={pop} /></ActionPanel>
  } />;
}

export default function Command() {
  const id = useId();
  const original = useRef(id);
  if (original.current !== id) throw Error("unstable useId");
  const menu = useActionPanel();
  const [result, setResult] = useState("ready");
  const [search, setSearch] = useState("");
  useEffect(() => {
    menu.update(<ActionPanel>
      <Action title="Ask" shortcut={{ modifiers: ["cmd"], key: "g" }} onAction={async () => {
        const progress = await showToast({ title: "Waiting", style: Toast.Style.Animated });
        const accepted = await confirmAlert({
          title: "Choose", primaryAction: { title: "Proceed", style: "destructive" }, dismissAction: { title: "Decline" },
        });
        setResult(accepted ? "accepted" : "declined");
        progress.style = Toast.Style.Success;
        progress.title = "Choice saved";
        progress.primaryAction = { title: "Undo", onAction: async () => {
          setResult("undone"); await progress.hide();
        } };
        progress.secondaryAction = { title: "Retry", onAction: async () => {
          setResult("retried");
          const failure = await showFailureToast(new Error("Retry failed"), { primaryAction: {
            title: "Undo", onAction: async () => { setResult("undone"); await failure.hide(); },
          } });
        } };
      }} />
      <ActionPanel.Section title="More">
        <Action.Push title="Push" target={<DetailPage />} onPop={() => setResult("returned")} />
        <ActionPanel.Submenu title="Searchable" onSearchTextChange={setSearch}>
          {search && <Action title={search} onAction={() => setResult("selected:" + search)} />}
        </ActionPanel.Submenu>
      </ActionPanel.Section>
    </ActionPanel>);
  }, [menu, search]);
  return <Detail markdown={result} />;
}
