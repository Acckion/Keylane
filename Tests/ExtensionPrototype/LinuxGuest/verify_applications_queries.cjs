const assert = require("node:assert/strict");
const test = require("node:test");
const { mkdtemp, mkdir, rm, symlink, writeFile } = require("node:fs/promises");
const { tmpdir } = require("node:os");
const { join } = require("node:path");
const { pathToFileURL } = require("node:url");
const { makeApplicationQueries } = require("./applications-api.cjs");

test("application queries forward only a content type hint to the host", async () => {
  const calls = [];
  const application = { name: "Fixture Editor", path: "/Applications/Fixture Editor.app" };
  const api = makeApplicationQueries(async (capability, text) => {
    const request = JSON.parse(text);
    calls.push([capability, request]);
    return JSON.stringify(request.operation === "list" ? { items: [application] } : application);
  });

  assert.deepEqual(await api.getApplications(), [application]);
  assert.deepEqual(await api.getApplications(new URL("file:///fixture/private/File.TXT")), [application]);
  assert.deepEqual(await api.getDefaultApplication(Buffer.from("/fixture/private/File.txt")), application);
  assert.deepEqual(await api.getApplications("/fixture/private/Folder/"), [application]);
  assert.deepEqual(await api.getApplications(new URL("https://user:secret@example.invalid/private?q=secret#secret")), [application]);
  assert.deepEqual(await api.getDefaultApplication("mailto:private@example.invalid"), application);
  assert.deepEqual(await api.getDefaultApplication("file:///private/Document.pdf"), application);
  assert.deepEqual(await api.getFrontmostApplication(), application);
  assert.deepEqual(calls, [
    ["applications.query", { operation: "list", offset: 0 }],
    ["applications.query", { operation: "list", extension: "txt", offset: 0 }],
    ["applications.query", { operation: "default", extension: "txt" }],
    ["applications.query", { operation: "list", directory: true, offset: 0 }],
    ["applications.query", { operation: "list", scheme: "https", offset: 0 }],
    ["applications.query", { operation: "default", scheme: "mailto" }],
    ["applications.query", { operation: "default", extension: "pdf" }],
    ["applications.query", { operation: "frontmost" }],
  ]);
});

test("unsupported paths and broker denials stay observable", async () => {
  let requests = 0;
  const api = makeApplicationQueries(async () => {
    requests++;
    throw new Error("Capability unavailable for this command");
  });
  await assert.rejects(api.getDefaultApplication(undefined), TypeError);
  await assert.rejects(api.getDefaultApplication("file.trailing space"), /Invalid filename extension/);
  await assert.rejects(api.getApplications("a\0b.txt"), TypeError);
  await assert.rejects(api.getApplications(new URL("file:///test/%00.txt")), TypeError);
  await assert.rejects(api.getApplications("https://"), TypeError);
  await assert.rejects(api.getApplications("x".repeat(33) + "://example.invalid"), TypeError);
  await assert.rejects(api.getApplications(Buffer.from([0xff])), TypeError);
  await assert.rejects(api.getFrontmostApplication(), /Capability unavailable/);
  assert.equal(requests, 1);
});

test("frontmost lookup rejects a missing or malformed application record", async () => {
  const makeAPI = (result) => makeApplicationQueries(async () => JSON.stringify(result));
  for (const result of [null, {}, { name: "", path: "/Applications/App.app" },
    { name: "App", path: "relative.app" }, { name: "App", path: "/Applications/App.app", bundleId: null },
    { name: "App", path: "/Applications/App.app", localizedName: 123 }]) {
    await assert.rejects(makeAPI(result).getFrontmostApplication(), /No valid frontmost application/);
  }
});

test("guest directory identification works without a slash in all PathLike forms", async () => {
  const root = await mkdtemp(join(tmpdir(), "raycast-dir-"));
  try {
    const calls = [];
    const api = makeApplicationQueries(async (_, text) => {
      const query = JSON.parse(text);
      calls.push(query);
      return JSON.stringify(query.operation === "list" ? { items: [] } : {});
    });
    const dotted = join(root, "folder.txt");
    const linked = join(root, "linked");
    await mkdir(dotted);
    await symlink(dotted, linked);
    await api.getApplications(pathToFileURL(dotted));
    await api.getDefaultApplication(Buffer.from(linked));
    await api.getDefaultApplication(root);
    assert.deepEqual(calls, [
      { operation: "list", directory: true, offset: 0 },
      { operation: "default", directory: true },
      { operation: "default", directory: true },
    ]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("extensionless files and symlinks disclose only predefined selectors and extensions", async () => {
  const root = await mkdtemp(join(tmpdir(), "raycast-files-"));
  try {
    const calls = [];
    const api = makeApplicationQueries(async (_, text) => {
      const query = JSON.parse(text);
      calls.push(query);
      return JSON.stringify(query.operation === "list" ? { items: [] } : {});
    });
    const readme = join(root, "README");
    const link = join(root, "link.pdf");
    const source = join(root, "example.C++");
    const sourceLink = join(root, "no-extension");
    await writeFile(readme, "synthetic");
    await writeFile(source, "");
    await symlink(readme, link);
    await symlink(source, sourceLink);
    await api.getApplications(pathToFileURL(link));
    await api.getDefaultApplication(pathToFileURL(link));
    await api.getDefaultApplication(Buffer.from(sourceLink));
    await api.getDefaultApplication(join(root, "Makefile"));
    await api.getApplications(join(root, ".private-configuration"));
    await api.getDefaultApplication(join(root, "private-name"));
    assert.deepEqual(calls, [
      { operation: "list", symlink: true, offset: 0 },
      { operation: "default", extensionless: "readme" },
      { operation: "default", extension: "c++" },
      { operation: "default", extensionless: "makefile" },
      { operation: "list", extensionless: "generic", offset: 0 },
      { operation: "default", extensionless: "generic" },
    ]);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("selected absolute paths are sent as invocation-scoped indexes", async () => {
  const paths = ["/test/selected/private.file with spaces", "/test/selected/文档.pdf"];
  let selected = paths;
  const calls = [];
  const api = makeApplicationQueries(async (_, text) => {
    const query = JSON.parse(text);
    calls.push(query);
    return JSON.stringify(query.operation === "list" ? { items: [] } : {});
  }, (path) => selected.indexOf(path));

  await api.getApplications(pathToFileURL(paths[0]));
  await api.getDefaultApplication(Buffer.from(paths[1]));
  await api.getDefaultApplication("/test/other/文档.pdf");
  selected = [];
  await assert.rejects(api.getDefaultApplication(paths[0]), /Invalid filename extension/);
  assert.deepEqual(calls, [
    { operation: "list", selectedFile: 0, offset: 0 },
    { operation: "default", selectedFile: 1 },
    { operation: "default", extension: "pdf" },
  ]);
});

test("parallel application listings finish each cursor before starting another", async () => {
  const calls = [];
  const application = { name: "Fixture", path: "/Applications/Fixture.app" };
  const api = makeApplicationQueries(async (capability, text) => {
    const { scheme, offset } = JSON.parse(text);
    calls.push([capability, scheme, offset]);
    return JSON.stringify({ items: [application], nextOffset: offset === 0 ? 1 : undefined });
  });
  const [web, mail] = await Promise.all([api.getApplications("https://example.invalid"), api.getApplications("mailto:a@example.invalid")]);
  assert.deepEqual(web, [application, application]);
  assert.deepEqual(mail, web);
  assert.deepEqual(calls, [
    ["applications.query", "https", 0],
    ["applications.listPage", "https", 1],
    ["applications.query", "mailto", 0],
    ["applications.listPage", "mailto", 1],
  ]);
  const invalid = makeApplicationQueries(async () => JSON.stringify({ items: [application], nextOffset: 2 }));
  await assert.rejects(invalid.getApplications(), /Invalid application list continuation/);
});
