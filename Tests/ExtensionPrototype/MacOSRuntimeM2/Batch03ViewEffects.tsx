import { useEffect } from "react";
import { clearSearchBar, closeMainWindow, Detail, popToRoot, PopToRootType, showHUD } from "@raycast/api";

export default function Command() {
  useEffect(() => {
    void (async () => {
      try {
        await clearSearchBar({ forceScrollToTop: false });
        await showHUD("View HUD", { popToRootType: PopToRootType.Suspended });
        await popToRoot({ clearSearchBar: true });
        await closeMainWindow();
      } catch {
        // No grant is a recoverable API error, not an implicit host action.
      }
    })();
  }, []);
  return <Detail markdown="view effects" />;
}
