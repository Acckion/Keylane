// First-party synthetic command, no host effect or external extension code.
const input: number[] = [5, 7, 30];
globalThis.__m0Result = JSON.stringify({ kind: "no-view", answer: input.reduce((a, b) => a + b, 0) });
