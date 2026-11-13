const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function attempt(action) {
  try {
    action();
    return "allowed";
  } catch (error) {
    return error.code || error.name;
  }
}

module.exports = async () => {
  const [protectedFile, port, oppositePhase, fixtureRoot = process.cwd()] = process.argv.slice(2);
  const network = await new Promise((resolve) => {
    const socket = net.createConnection({ host: "127.0.0.1", port: Number(port) });
    socket.once("connect", () => { socket.destroy(); resolve("allowed"); });
    socket.once("error", (error) => resolve(error.code));
    socket.setTimeout(1000, () => { socket.destroy(); resolve("timeout"); });
  });
  return {
    read: attempt(() => fs.readFileSync(protectedFile)),
    symlinkRead: attempt(() => fs.readFileSync(path.join(fixtureRoot, "outside-link"))),
    write: attempt(() => fs.appendFileSync(protectedFile, "changed")),
    phaseRead: attempt(() => fs.readFileSync(oppositePhase)),
    writeInput: attempt(() => fs.writeFileSync(path.join(fixtureRoot, "probe.cjs"), "modified", { flag: "a" })),
    spawn: spawnSync("/usr/bin/true").error?.code || "allowed",
    network,
    inheritedSecret: Object.hasOwn(process.env, "KEYLANE_TEST_SECRET"),
  };
};
