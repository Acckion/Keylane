const { memoryUsage } = require("node:process");
const { isNativeError } = require("node:util").types;

const diagnosticLimit = 16;
const diagnostics = [];
let memoryReporter;
let exceptionReporter;

function configureMemoryReporting(send) {
  memoryReporter = typeof send === "function" ? { send, remaining: diagnosticLimit } : undefined;
}

function configureExceptionReporting(send) {
  exceptionReporter = typeof send === "function" ? send : undefined;
}

function captureException(exception) {
  if (diagnostics.length >= diagnosticLimit) return;
  // Record only the JS value category. Accessing an error message, stack or getter
  // could copy extension secrets into diagnostics.
  const valueType = isNativeError(exception) ? "error" : typeof exception;
  diagnostics.push({ kind: "exception", valueType });
  try {
    if (exceptionReporter) Promise.resolve(exceptionReporter(valueType)).catch(() => {});
  } catch {
    // Diagnostics must never interrupt the extension's own error recovery.
  }
}

function recordMemorySample(label) {
  const reporter = memoryReporter;
  if (!reporter?.remaining) return;
  reporter.remaining--;
  const { heapUsed, heapTotal } = memoryUsage();
  // Report immediately so the host retains previous samples after the VM exits.
  try {
    Promise.resolve(reporter.send({ label, heapUsed, heapTotal })).catch(() => {});
  } catch {
    // A rejected diagnostic should not make the command fail.
  }
}

function captureMemorySnapshot(label) {
  if (!memoryReporter?.remaining || typeof label !== "string") return;
  const safeLabel = label.slice(0, 96).replace(/[\p{Cc}\p{Cf}\p{Cs}]/gu, " ").trim();
  recordMemorySample(safeLabel);
}

function guestDiagnostics() {
  return diagnostics.map((entry) => ({ ...entry }));
}

module.exports = { captureException, captureMemorySnapshot, configureMemoryReporting, configureExceptionReporting, recordMemorySample, guestDiagnostics };
