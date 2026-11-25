import { PopToRootType, showHUD } from "@raycast/api";

export default async function checkHUD({ arguments: { navigation } }) {
  let rejected = false;
  try {
    await showHUD("Scoped HUD", { clearRootSearch: true, popToRootType: PopToRootType.Suspended });
  } catch {
    rejected = true;
  }
  if (rejected !== (navigation === "off")) throw new Error("HUD navigation authorization mismatch");
}
