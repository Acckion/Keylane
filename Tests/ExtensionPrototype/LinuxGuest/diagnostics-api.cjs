const { memoryUsage } = require("node:process");
const { environment } = require("./environment.cjs");

const diagnosticLimit = 16;
const diagnostics = [];

function captureException(exception) {
  if (diagnostics.length >= diagnosticLimit) return;
  // Record only the JS value category. Accessing an error message, stack or getter
  // could copy extension secrets into diagnostics.
  diagnostics.push({ kind: "exception", valueType: typeof exception });
}

function captureMemorySnapshot(label) {
  if (environment.isDevelopment !== true || typeof label !== "string" || diagnostics.length >= diagnosticLimit) return;
  const { heapUsed, heapTotal } = memoryUsage();
  diagnostics.push({ kind: "memory", heapUsed, heapTotal });
}

function guestDiagnostics() {
  return diagnostics.map((entry) => ({ ...entry }));
}

module.exports = { captureException, captureMemorySnapshot, guestDiagnostics };
