(async () => {
  const report = await require("./probe.cjs")();
  report.result = Buffer.from("Keylane 中文").toString("base64");
  process.stdout.write(JSON.stringify(report));
})().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
