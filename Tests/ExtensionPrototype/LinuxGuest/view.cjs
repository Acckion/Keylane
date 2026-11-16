const broker = require("/raycast-api.cjs");
const api = require("/view-api.cjs");
const { limitImagePayloads } = require("./image-api.cjs");

const uuidCommands = new Set([
  "generate", "generateV5", "generateV7", "generateUlid", "generateTypeID", "parseTypeID", "packTypeID",
]);

async function main() {
  broker.connect();
  const input = JSON.parse(await broker.request("view.input", ""));
  require("./environment.cjs").configureEnvironment(input.environment);
  api.prepareInput(input);
  const commands = require("/sample.cjs");
  let result;
  if (input.mode === "menuBar") {
    result = await api.runMenuBar(commands.default, input);
  } else if (uuidCommands.has(input.mode)) {
    result = await api.runCommand(commands[input.mode], input);
  } else {
    result = await api.render(input.mode === "history" ? commands.history : commands.default, input);
  }
  await broker.request("view.result", JSON.stringify(limitImagePayloads(result)));
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
