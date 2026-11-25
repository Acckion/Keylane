import {
  Cache, LocalStorage, preferences, getPreferenceValues, environment, openCommandPreferences, openExtensionPreferences,
  captureException, captureMemorySnapshot,
} from "@raycast/api";

function check(condition, name) {
  if (!condition) throw new Error(name);
}

export default async function batch02({ arguments: { mode } }) {
  const cache = new Cache({ namespace: "batch" });
  if (mode === "denied") {
    check(!environment.canAccess(LocalStorage) && !environment.canAccess(openCommandPreferences)
      && !environment.canAccess(captureException), "denied access");
    check(Object.keys(preferences).length === 0 && Object.keys(getPreferenceValues()).length === 0, "no preferences");
    for (const action of [() => cache.get("key"), () => LocalStorage.getItem("key"),
      openCommandPreferences, openExtensionPreferences]) {
      let rejected = false;
      try { await action(); } catch { rejected = true; }
      check(rejected, "denied operation");
    }
    return;
  }

  check(environment.canAccess(LocalStorage) && environment.canAccess(openCommandPreferences)
    && environment.canAccess(captureException), "granted access");
  const values = getPreferenceValues();
  check(values.label === "chosen" && preferences.label.value === "chosen" && preferences.label.default === "fallback",
    "ordinary preference");
  check(preferences.label.title === "Label" && preferences.label.type === "textfield" && preferences.label.required
    && Object.isFrozen(preferences) && Object.isFrozen(preferences.label), "legacy preference metadata");
  values.label = "changed in guest";
  check(getPreferenceValues().label === "chosen", "preference read is a snapshot copy");

  if (mode === "ordinary-only") {
    for (const key of ["secret", "file", "directory", "application"]) {
      check(!Object.hasOwn(values, key) && !Object.hasOwn(preferences, key), "ungranted preference");
    }
    return;
  }
  check(values.secret === "synthetic-fixture-value" && preferences.secret.value === values.secret, "granted password");
  check(values.file === "/fixture/document.txt" && values.directory === "/fixture", "file selection value");
  check(values.application.bundleId === "org.keylane.tests.synthetic" && Object.isFrozen(values.application),
    "application selection value");

  if (mode === "write") {
    cache.set("key", "cached");
    await LocalStorage.setItem("key", -0);
    await openExtensionPreferences();
    await openCommandPreferences();
    const privateObject = new Proxy({}, { get() { throw new Error("diagnostic read a user field"); } });
    captureException(privateObject);
    captureMemorySnapshot("private label");
  } else if (mode === "failed") {
    cache.set("key", "bad cache");
    await LocalStorage.setItem("key", "bad persistent");
    await openCommandPreferences();
    throw new Error("Discard this invocation");
  } else {
    check(cache.get("key") === "cached" && Object.is(await LocalStorage.getItem("key"), -0), "reopened stores");
  }
}
