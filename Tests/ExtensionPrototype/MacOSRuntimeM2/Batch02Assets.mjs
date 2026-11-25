import { Cache, environment } from "@raycast/api";
import { readFileSync, writeFileSync } from "node:fs";
import { readFile, writeFile } from "node:fs/promises";

async function rejects(read) {
  try { await read(); } catch { return; }
  throw new Error("Unexpected resource access");
}

export default async function checkAssets({ arguments: { mode } }) {
  if (mode === "denied") {
    if (environment.assetsPath !== undefined || environment.supportPath !== undefined) throw new Error("Ungrantable asset path");
    await rejects(() => readFileSync("/assets/sub/hello.txt", "utf8"));
    await rejects(() => readFileSync("/support/data.txt", "utf8"));
    await rejects(() => writeFile("/support/data.txt", "not allowed"));
    return;
  }
  if (environment.assetsPath !== "/assets" || environment.supportPath !== "/support") throw new Error("Invalid asset root");
  const directory = environment.assetsPath + "/sub";
  if (await readFile(directory + "/hello.txt", "utf8") !== "你好") throw new Error("UTF-8 asset read failed");
  const data = readFileSync(environment.assetsPath + "/bytes.bin");
  if (!(data instanceof Uint8Array) || String(data) !== "0,128,255") throw new Error("Binary asset read failed");
  await rejects(() => readFile("/assets/../package.json", "utf8"));
  await rejects(() => readFileSync("/etc/passwd", "utf8"));
  await rejects(() => readFileSync(directory + "/hello.txt", { encoding: "utf8", flag: "w" }));
  await rejects(() => writeFileSync(directory + "/hello.txt", "cannot write assets"));
  await rejects(() => writeFileSync(environment.supportPath + "/../escape.txt", "cannot escape"));
  const support = environment.supportPath + "/data.txt";
  const shared = new Cache();
  const custom = new Cache({ directory: "/support/nested" });
  if (Cache.STORAGE_DIRECTORY_NAME !== "cache" || shared.storageDirectory !== "/support/cache" ||
      custom.storageDirectory !== "/support/nested/cache") throw new Error("Cache directory path mismatch");
  await rejects(() => new Cache({ directory: "/outside" }));
  if (mode === "write") {
    shared.set("key", "default");
    custom.set("key", "custom");
    await rejects(() => writeFile(custom.storageDirectory + "/entries.json", "cannot overwrite cache"));
    await writeFile(support, "已保存");
    if (readFileSync(support, "utf8") !== "已保存") throw new Error("Support read-back failed");
    await rejects(() => writeFile(support, "z".repeat(32769)));
  } else if (await readFile(support, "utf8") !== "已保存") {
    throw new Error("Support file did not persist");
  }
  if (shared.get("key") !== "default" || custom.get("key") !== "custom") throw new Error("Cache directories overlap");
  const entries = JSON.parse(await readFile(custom.storageDirectory + "/entries.json", "utf8"));
  if (entries.length !== 1 || entries[0][1] !== "custom") throw new Error("Cache directory index mismatch");
}
