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

## Second candidate: fixed signed slots

```sh
python3 scripts/verify-macos-runtime-slots.py --report /private/tmp/keylane-m0-slots-report.json
```

It shares the original runtime lock/signature policy. `--archive` accepts only
the same digest-verified official archive. `GroupHelper.m` uses public
`posix_spawn` flags to join the helper-owned session group and close all FDs
except explicit stdin/out/err. It refuses launch outside its own group (exit78).
Two predeclared Bundle IDs are signed before running; production would not need
to sign a new helper per extension. No app/Node receives extra permissions.

Positive controls intentionally pass a synthetic FD to a direct Node; the same
FD is passed to the helper but must not reach Node. Slot A writes a random
marker, Slot B attempts that exact existing path, and A rereads it as a positive
control. Marker cleanup happens through each owning slot, not by recursively
removing containers. The lifecycle cases cover both a normal descendant and
`detached:true`, which attempts to create a separate process group/session.
The harness cleans only recorded first-party PIDs after rechecking their paths;
this is not a production solution for hostile descendants. All lifecycle results
retain the failed group-cancellation observation before harness cleanup.

Observed: cross-slot read denied (EPERM), extra FD closed (EBADF), cooperative
Node descendants exited with the helper group. However same-slot reuse exposed
the old marker, arbitrary subprocesses remained allowed, and the detached
first-party descendant escaped group cancellation. Therefore exit2/blocked.
See [report](../../../docs/evidence/macos-runtime-m0/fixed-slots-probe.json).
The original baseline still returns blocked and its gate was not relaxed.

The temporary bundle directory may get a Finder `.DS_Store` during removal.
Cleanup retries ENOTEMPTY at most three times, only for this run's mkdtemp root;
permission failures are never swallowed. The experiment report is written only
after process and temporary-artifact cleanup is confirmed. Normal CI executes
only the non-signing verdict/cleanup tests, not the signed experiment.

## Third batch: restricted JS contrast, not a Node replacement

See [scope, evidence and compatibility differences](../../../docs/RESTRICTED-JS-M0.md).
`verify-macos-restricted-js-m0.py` tests a separate system JavaScriptCore context
with no Node/native capabilities, signed kernel parent constraints and a native
parent-EOF watcher. A compile-time watcher-disabled twin is a negative control,
never a runtime fallback. JSContext/JSVirtualMachine is an engine context, not a
Linux guest VM. The product engine and compatibility CSV remain unchanged.

The 18-case subset returns exit3/incomplete even when all cases pass. It does
not implement a business broker, Node modules, React or Raycast extension APIs.
The original blocked Node experiments remain reproducible; no trust boundary is
relaxed to enable production. All first-party processes are cleaned up, and only
deidentified results are retained.

## Fourth batch: bounded first-party broker

```sh
python3 scripts/verify-macos-broker-m0.py --report /private/tmp/keylane-broker-report.json
```

See [scope and remaining gates](../../../docs/BROKER-M0.md). The signed parent
binds synthetic records to a dedicated native channel; JS cannot supply owner
metadata. Preparation, execution and publication recheck epochs, with bounded
frames, replay rejection and in-memory namespace controls. Seventeen signed
subchecks pass, but the synthetic seal is not actual installation admission.
The fixture is serial and does not implement product storage, Node or Raycast
compatibility. Exit3/incomplete remains mandatory even when all observations pass.
Normal CI runs only verdict checks and the unsigned synthetic Swift authority test;
the signed helper experiment remains a separate local check. No product packaging
or runtime path includes this fixture.

## Fifth batch: transport faults and bounded memory pressure

```sh
python3 scripts/verify-macos-transport-m0.py --report /private/tmp/keylane-transport-report.json
```

See [scope and evidence](../../../docs/TRANSPORT-PRESSURE-M0.md). Partial headers
are protocol errors, distinct from clean EOF; malformed/truncated replies terminate
the helper. First-party native peers inject raw faults without adding a JS escape
API. A signed parent twin holds replies to test EOF supervision while native RPC
blocks. The native memory sampler checks only its unreaped child and joins before
waitpid; an observe-only twin is the negative control. A 64MiB sampling threshold
is not a hard memory ceiling. The synthetic workload allocates at most128MiB of
TypedArray payload, plus engine overhead, without exhausting the machine.
All nineteen subchecks passed; exit3/incomplete, no production approval.
