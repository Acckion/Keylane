const fs = require("node:fs");
const vm = require("node:vm");

(async () => {
  const report = await require("./probe.cjs")();
  const source = fs.readFileSync("extension.cjs", "utf8");
  new vm.Script(source, { filename: "extension.cjs" });
  fs.writeFileSync("output/extension.cjs", source, { flag: "wx" });
  process.stdout.write(JSON.stringify(report));
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
