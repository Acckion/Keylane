# M0 macOS runtime feasibility fixture

This is a first-party diagnostic, not a product runtime. It has no extension
store integration and never starts the Keylane application or installs a bundle.

Run on a macOS arm64 test host with an existing Apple Development identity:

```sh
python3 scripts/verify-macos-runtime-m0.py --report /private/tmp/keylane-m0-report.json
```

The script downloads Node **24.12.0 darwin-arm64** from nodejs.org and verifies a
fixed SHA-256 before extraction or execution. This version is a reproducible
probe input, not the selected future production runtime. For repeated runs,
`--archive /path/to/node-v24.12.0-darwin-arm64.tar.gz` reuses an archive but still
requires that exact digest. There is no PATH/unsigned/alternate-runtime fallback.
The temporary runtime retains the upstream LICENSE. No runtime or archive is
checked into this repository.

The script signs the temporary helper app and nested Node with the local Apple
Development identity. It checks the certificate requirement, Hardened Runtime,
and exact entitlements before and after execution. It does not export keys,
write a new signing-identity pin, use ad-hoc signing, or install an app. No signing
credentials are needed for the normal Python policy tests in CI.

`Helper.swift` uses Foundation.Process with a minimal environment. Node receives
only this first-party probe on stdin. There is no API shim or Node permission
model: the test deliberately checks the actual OS boundary. The positive control
uses the same official Node and synthetic paths outside the sandbox. The only
network endpoint is a listener created by the test on 127.0.0.1. The two sandbox
invocations share an app identifier to test the assumption of per-extension
storage isolation, then delete only their own randomly named marker files.
The OS may retain an empty fixture container; the test never removes an entire
container or accesses unrelated contents.

The lifecycle test first records whether killing the helper's group stops its
Node descendants. It preserves a failure, then separately cleans up only the
known-owned Node groups. PID/path/group checks are **fixture cleanup checks**,
not the production peer-identity protocol. `/tmp` and `/private/tmp` are normalized
before matching; process `comm` is not used because macOS truncates it. Bounded
checks confirm there are no running owned processes. An abrupt Node exit is
propagated through the helper; this is not a native crash-recovery test.

Exit codes:

- `0`: all mandatory probes passed (not currently reachable with the implemented
  coverage; this fixture cannot approve production use).
- `2`: isolation blockers were observed and the JSON report was written.
- `3`: no blocker in the observed subset, but mandatory coverage remains missing.
- `1`/other nonzero: environment/setup/probe failure; not an isolation pass.

Observed 2026-11-21: **blocked**. Synthetic host reads/writes, symlink reads and
loopback networking were denied; JIT and child execution worked. Child Node
inherited host-file denial. Two invocations could share container files, and
terminating only the helper group left Node descendants. See the deidentified
[report](../../../docs/evidence/macos-runtime-m0/first-probe.json).

Coverage still missing: Keychain, native addon loading, direct host-service
connections, descriptor inheritance, forged-peer admission and full native
crash/host-disconnect behavior. They must not be silently counted as denials.
M1 and third-party execution remain unavailable; the production VM path was not
changed by this experiment.
