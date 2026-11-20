# Store data transport gate (not a live installer)

`package-data.cjs` defines a prospective guest-side data envelope decoder. It does
not extract, import, compile, execute, install, or grant capabilities. It is not
wired into the application, Host.swift, init.c, or package.sh. No additional
catalog allowlist is introduced. The Store source contract remains authoritative.

Adapter input: the existing prepared source `files: [String: Data]` mapping.
Encode UTF-8 JSON `{ "version": 1, "files": [{ "path": "src/index.ts",
"body": "<canonical base64>", "sha256": "<lowercase SHA256 of bytes>" }] }`.
The adapter must preserve source identity (official repository, fixed commit,
slug, manifest and licenses) outside this envelope, binding its complete digest
to the host-owned request/session. Per-file hashes detect corruption, NOT trust.

The decoder accepts at most 4096 files, 32 MiB decoded bytes and 46 MiB wire
bytes; only ASCII relative paths without empty/dot/parent segments, backslashes,
case aliases, or file/directory collisions are accepted. This conservative path
subset may reject legitimate sources and must surface as unsupported input,
not silently rename or omit files. Buffer input must be bounded during transport
BEFORE allocation; this decoder's size check alone is not streaming protection.
No archive or executable-image format is accepted. JS source contents remain
uninterpreted bytes. It must run inside the sealed guest for real packages.

## Exact production gates in dev 91bda02

- `Tests/ExtensionPrototype/LinuxGuest/prepare.py` places selected sources and
  dependencies into initramfs (`sample.cjs` etc.) and builds phase-specific images.
  This is not a generic dependency resolver/build service.
- `LinuxGuest/init.c` starts the built-in worker with restricted process creation;
  there is no reviewed generic source-data ingress/build-result export channel.
- `LinuxGuest/Host.swift` validates signed resources and known image/stage paths.
  Accepting an arbitrary external .cpio instead would undermine that boundary.
- `scripts/package.sh` does not yet ship a verified generic Store guest and runner.

Next step: sealed guest ingress over a dedicated bounded transport, transfer ID,
ordered chunks, acknowledgments, deadline/cancellation, and host-authenticated
identity; complete validation before exposing files in a guest-only workspace.
Builds must have no host shares/network/credentials and must not run package
lifecycle scripts on macOS. Export a bounded data-only built module with an exact
request identity; execute it only in a fresh isolated guest with host-selected
capabilities. Keep kernel/runner/runtime signature validation unchanged.
Do not make this gate an alternative installation registry or backend API.

## Verification

`node Tests/ExtensionPrototype/StoreTransport/verify-package-data.cjs` executes
only repository-owned decoder/tests and synthetic fixture bytes. Covers positive
roundtrip, inert code contents, traversal/path ambiguity, duplicates, collisions,
invalid UTF-8/base64/digests, version and file/byte/wire limits. This is a local
protocol-unit test, not a signed VM, real extension, package, or UI acceptance.

## Guest ingress fixture (follow-up)

`receive-package.cjs` adds sequential pull transfer with a fixed transfer ID,
8 KiB chunks, exact offsets/lengths, canonical base64, full-envelope SHA256,
an absolute 15-second deadline and abort cleanup. A host-owned descriptor bounds
allocation. It calls an injected transport, not a network or filesystem API.
`guest-fixture.cjs` adapts fd 3 inherited from the existing unprivileged Linux
worker to this receiver; it returns only file count and bytes, never executes
source. `IngressFixtureHost.swift` boots only its own signed bundle's fixed Image
and ingress.cpio. It has no network, shared directory or disk device, a 25-second
VM lifetime bound and confirms VM stop. No external image path is accepted.

Real Mac fixture evidence (2026-11-19): Apple Development signed test bundle,
strict nested signature validation before and after; valid 37,500-byte inert
file in a multichunk envelope received; oversized declaration, bad chunk offset
and corrupted envelope rejected. All four runs confirmed VM stop. Early valid
runs failed the HARNESS's erroneous 36,000-byte expectation; corrected to 37,500.
This was not a transport failure. Local receiver tests cover cancellation while
waiting and malformed/replayed chunks. Guest cancellation and parent death are
NOT yet accepted; this harness is NOT a production process supervisor.

Hardware probe: sandboxed `swift -module-cache-path /tmp/keylane-store-seam-swift-cache
-e 'import Virtualization; print(VZVirtualMachine.isSupported)'` reports false;
the same permitted command outside the command sandbox reports true. Boot tests
also require that supported execution context. No OS/security setting changed.

Reproduction: use a separate scratch directory, run `prepare-fixture.py` with the
existing pinned Alpine/Node cache and scratch destination; compile
`IngressFixtureHost.swift` into an App bundle, copy the resulting Image and
ingress.cpio into Contents/Resources, include CFBundleExecutable, and sign the
entire bundle with the existing Apple Development identity and ONLY
com.apple.security.virtualization entitlement. Run the executable with `valid`,
`oversize`, `replay`, `corrupt`. Keep the App separate from the installed Keylane.

Production readiness remains runtimeUnavailable: no build/export service,
dependency resolution, signed shipping package integration, permission broker
binding, installation identity/generation binding, or real Store launch exists
in this slice. Preserve signature/identity gates when integrating; do not expose
this diagnostic harness as the Store backend.

Final reproduction used `KEYLANE_VM_SIGN_IDENTITY='Apple Development' bash
Tests/ExtensionPrototype/StoreTransport/verify-vm.sh <pinned-cache> <fresh-scratch>`.
All four VM cases passed again after the final frame-bound fix; strict bundle
verification passed before/after. Both Node test suites, version check and all
23 ReleaseTests passed. Full application Swift tests and production installer
verification were not run (no app/package changes in this slice).

### Next build gate

The existing pinned Linux esbuild executable is staged by
`LinuxGuest/prepare.py:stage_build`, but `init.c:build_bundle` runs it as a separate
unprivileged child BEFORE the Node worker starts. The worker's seccomp policy
rejects non-thread process creation. Calling esbuild from the new Node receiver
would therefore fail; allowing spawn in that receiver would weaken isolation.
A safe next step is a distinct trusted init supervisor phase: receive and validate
in an unprivileged receiver, exit; validate a bounded guest-only handoff, launch
pinned esbuild with a host-selected recipe as another restricted child; export
only bounded CJS bytes plus digest. Then transfer that data into a FRESH run VM.
Keep entrypoint/path selection separate from flags; no lifecycle scripts, plugins
or extension-selected executable. Initially test only a dependency-free fixture
with an explicit external @raycast/api import and a trusted stub in the run VM.
Do not change the active compatibility owner's init or production callbacks.

## Fixed build → artifact → fresh guest proof (fixture only)

`verify-vm.sh <pinned-cache> <fresh-scratch> stage` now exercises a self-authored,
no-dependency TypeScript command. The sealed receiver permits exactly one
`src/fixture.ts` file of at most 4096 bytes for this test recipe. It never accepts
package scripts, build options, plugins, executable paths, or dependencies.
After receiver exit, trusted init verifies a regular single-link handoff file,
changes it and its directory to root-owned read-only, then calls the existing
fixed `build_bundle` and unchanged `enter_worker` seccomp functions. All children
have an 8192-byte file limit, the VM has 384 MiB memory, and init has a 20-second
alarm in addition to the host deadline. There is no network, disk, or shared
host filesystem device.

The pinned esbuild binary produces a CommonJS artifact in guest-only `/work`.
A separate unprivileged exporter checks a 4096-byte output limit and returns
base64 plus SHA-256; the host rechecks both and handles the artifact as **data**.
The first VM is stopped. A new host process constructs a fresh signed VM, sends
the artifact through the same bounded transport, seals the received file, then
executes it only inside that VM. No host evaluation, unsigned image, or guest
filesystem reuse is involved. `@raycast/api` is explicitly a tiny trusted stub
that captures `showToast`'s title, not the real API. The expected result is
`sealed-build-run-ok`. This is not a Store installer or production build service.

Verified: build/run success, source recipe/path rejection before compilation,
and corrupted artifact digest rejection before VM construction. Existing ingress
codec/replay/bounds/cancellation tests remain unchanged. Valid output in the
initial run was 564 bytes, digest
`c601919fa3ee3cdc888b12567e4322fb65be31615e07abe3c5b2b04ab91d93da`.
The source and recipe are fixture-specific test controls, **not** a proposed
per-extension allowlist. Production recipes, source-revision binding, dependency
closure, artifact identity, runtime API/session binding, installation integration,
process-death guarantees, and user-facing permissions remain separate gates.

### Next runtime/dependency contract (not implemented)

The next narrow integration should retain immutable signed runtime modules from
`LinuxGuest/prepare.py` (the `raycast-api`/`view-api` adapters, utils and React
shims), not copy npm's Raycast package into the guest. For a no-view self-authored
fixture, use the existing `api.connect()`, `api.runNoViewCommand()` and real
host broker session rather than replacing `showToast`. For a view command, the
existing `view.cjs` also requires `view.input`, environment, preference/cache/ID
snapshot handling and rendering. Neither is provided by this test harness.
The artifact must be bound to source commit/content digest, fixed recipe and
runtime ABI plus installation generation before a production launch is ready.

Existing UUID build requirements demonstrate a dependency *graph*, not an
extension allowlist: uuid 11.1.1, typeid-js with its nested uuid v10, ulidx and
layerr are independently digest-pinned in `uuid-suite-packages.sha256`. CHMOD's
recorded build uses source-only TSX and external runtime adapters. A general
first supported dependency class can be locked pure-JS packages without install
scripts/native addons, resolved entirely from verified archives, preserving
nested versions and licenses; package entries/exports still need validation.
The current `stage_npm_package` supports known archive dist layouts, but is not
a general lockfile resolver or complete bounded archive validator. Network npm
install, lifecycle scripts, dynamic fetch, native addons and unpinned resolution
must remain unsupported until their own safe design exists. Do not broaden
this fixture's accepted source recipe into a claimed production catalogue path.

## Real API/session checkpoint

Pass `real` instead of `stage` to build a **separate** sealed test bundle that
uses the existing `LinuxGuest/raycast-api.cjs` and its recursively discovered
static relative CommonJS dependency closure, without editing those modules.
The cache must also contain `icu-data-en.apk` with the same digest already
required by the existing view/noview preparation. ICU libraries alone are not
sufficient for the API's Unicode regular expressions. The first attempt proved
this missing-data failure; adding the exact pinned ICU data is required, not
removing or replacing the real image/API validation.

The fresh VM calls `api.connect()` and `api.runNoViewCommand()` around the
self-authored compiled command. The host compiles the existing Core
`ExtensionPrototypeSession.swift` and `ExtensionClipboardContent.swift`, grants
only toast and echo, and validates the actual `feedback.toast` event's expected
title and operation. It records `real-host-toast-received=true`. The API receives
the broker response; a request for ungranted `files.trash` must be denied, and a
final echo receipt confirms the round trip. The session's deliberate stale hello
is rejected without reply, using the existing session implementation. The host
handler is a test event sink: no app toast/window is shown, no clipboard or files
are changed, and no production App helper/session lifecycle is claimed.

### Artifact handoff shape

The test host exports `{artifact: base64, sha256, provenance}`. Provenance is
host-authored and contains `version`, `sourceDigest`, `recipe`, `runtimeDigest`,
`installationID`, and `installationGeneration`. The source digest binds the
exact self-authored source bytes; the recipe identifies the fixed compiler
arguments; runtimeDigest binds the ordered kernel+initramfs bytes containing
the compiler, adapters and init. Installation ID/generation are explicit fixture
values. Before creating the next VM the host verifies the artifact hash and
requires all provenance fields to equal its independently computed expectation.
This is not a signature on arbitrary package metadata or a production registry.

For Store integration, the existing SourcePackage's verified slug/revision and
content digest must replace the fixture source identity, and the backend must
supply current installation ID/generation rather than accepting those claims
from the artifact. The existing API protocol currently uses generation 1 in
this fixture, separate from the installation-generation validation. Dynamic
production generation and capability binding remain integration work. The
Store worker owns dependency locking; no dependency-lock implementation or
new installation API is added here.

The run invocation additionally requires the **expected output SHA-256 from the
trusted build caller** as a separate argument. A package cannot supply its own
expected identity: even replacing the artifact and recomputing its internal hash
is rejected against that independently retained receipt. In this test,
`verify-vm.sh` captures the digest from the successful controlled build before
any mutation tests. The Store backend must retain this expected identity in its
own trusted preparation/install record, not read it back from untrusted package
metadata. This test does not create a signing key or pretend the JSON receipt is
a portable signed attestation. `verify-provenance.sh` covers mismatched source,
recipe, runtime, installation ID/generation and a replacement with recomputed
hash. All must fail before creating a VM.

### Typed host bridge fixture

The `real` verification also drives the app-side `StoreRuntimeBridge` through
a test-only adapter for the fixed fixture recipe. The Swift bridge produces
the real guest envelope, records the output SHA-256 separately from the
artifact, and checks a separately authorized current installation generation
before launch. The fixture adapter checks the strict bundle seal, then binds
the exact signed kernel, ramdisk, fixed recipe and API mode to the receipt.
The two VM objects are created independently; both must stop successfully,
and the actual host toast receipt must be observed. A no-connection deadline
case must stop its VM with a failure (not mark the command prepared). No
third-party extension executes and no app installation or personal data is
modified. This adapter is not the production catalog builder, command
registration, VM authorization/revocation implementation or launcher wiring.

2026-11-20 local verification: the typed fixture host compiled and its test
bundle passed strict signature verification. Both that bundle and the
previously passing signed real-API bundle returned VZErrorDomain code 2 at VM
configuration validation when launched from the same ordinary command sandbox;
neither booted. This matches the earlier supported-context distinction above.
The typed two-VM roundtrip and timeout/stop assertions are not yet verified on
hardware. Rerun the fixed fixture only in a supported local context with
virtualization available and the existing signing identity; do not change OS
settings or fall back to running a Store extension on the host.

Supported-context follow-up on 2026-11-20: one scoped local launch of the
same strictly verified Apple Development fixture completed the typed bridge's
two-VM roundtrip (exit 0). The first sealed guest built the synthetic source;
the second fresh guest executed the artifact and produced the real host toast
receipt. Both reported `fixture=passed vmStopped=true`. The independently
checked artifact SHA-256 was
`c601919fa3ee3cdc888b12567e4322fb65be31615e07abe3c5b2b04ab91d93da`.
This launch did not rerun the timeout/stop test, execute a third-party
extension, or verify a production installer or launcher.

The checked-in fixture now builds against `StoreSignedGuestEngine`, the
app-callable resource adapter. Its public path verifies a fixed Apple-anchored
team and signing identifier, strict bundle resources, then binds the kernel,
ramdisk and recipe to the independent artifact receipt. A changed receipt or
resource selection fails before driver dispatch. Production must supply a
pinned trust policy, app-controlled immutable resources and a reviewed driver
that creates fresh guests and enforces live installation-generation revocation.
The fixture's driver is not a shipping or catalog-executable driver.

This refactor compiled with the fixture; six focused Mac XCTest cases passed in
an isolated, dependency-free test package. The two-VM receipt above predates
this refactor, so rerun the signed fixture when virtualization is available.

### Installed helper admission (not yet shipped)

The app-owned locator resolves only
`Keylane.app/Contents/Helpers/KeylaneStoreGuest.app`, checks its expected
identifier, recipe and application-owned Apple signing team, and verifies its
sealed resources before use. Packaging is unchanged unless a build explicitly
sets `KEYLANE_STORE_GUEST_ASSETS`. That path cannot point at the fixture
cache: packaging refuses until a separately reviewed
`Resources/StoreGuest.lock.json` (version 2) pins the two production guest images
in `files` and the exact `StoreGuestNotices.json` SHA-256 in `notices`, and a
release-built `KeylaneStoreGuest` executable is available. The fixed notice file
must be beside the two images in the opt-in asset directory. Its exact JSON
keys are `version` (1), `recipe`, `files`, and `components`. The recipe and
image digest map must match the lock. Each component has a distinct `id`, a
nonempty `assets` array of exact names from the lock, complete inline `notice`
text, and a nonempty `sources` array of HTTPS `url` and `sha256` records for
corresponding source artifacts. Both images must be covered. The packager seals
the exact verified notice bytes alongside the images in the signed helper; it
does not download or execute source materials. A separate review must establish
component completeness, exact corresponding source, digest verification,
availability, and completeness of notice text before approving a real lock.
The future app-owned recipe should identify the exact API/runtime combination.
The nested helper receives the virtualization entitlement; the outer
application's entitlements are unchanged. No ad-hoc-signed helper is admitted.

The production guest image, lock and release helper are deliberately absent.
The test initramfs only admits the fixture input and is not promoted into
a distribution. Run the pure packaging admission tests with
`python3 -m unittest discover -s scripts -p test_store_guest_packaging.py`.
They use inert local inputs; the signature commands and disk-image writer are
mocked. The ordinary packaging entry point still skips the guest by default.
Neither signing a production guest bundle nor a packaged Store run occurred.

### General data staging and deterministic image tooling

`project-stage.cjs` validates the entire bounded transfer through the shared
decoder, then writes inert files once into a unique guest-only staging tree.
It requires an explicitly selected, present entry of a supported source type.
Only the future sealed supervisor may choose the parent and entry; it must
provide an isolated parent, bind the entry to the request identity, and seal
the materialized tree before invoking the fixed compiler. There is no compiler
or runtime invocation in this module and it is not wired into a shipping VM.

`python3 scripts/store_guest_newc.py <prepared-tree> <new-output.cpio>`
writes deterministic archive order, owner, group and timestamps from an
already prepared, trusted tree. It refuses replacement, unusual filesystem
records, unsafe link targets and over-budget images. No prebuilt guest binary or
qualification lock is created or checked in. This normalizes image archive
metadata; the prepared tree bytes and toolchain must still be independently
pinned and reproduced before admitting them to package signing. The unit tests
and archive smoke use inert repository-authored fixtures exclusively.

`store-init.c` and `store-stage.cjs` provide a non-fixture candidate guest
compile and run entry. The trusted init launches only the fixed esbuild
recipe (no lifecycle scripts), passes a checked `src/` entry inside the
received project, and exposes compiler output only through bounded,
hash-labeled chunk frames. The run phase's fresh guest receives one artifact,
seals it read-only, and uses the bundled Raycast bridge for a no-view command.
This guest requires the existing signed runtime isolation and app-owned broker;
no host-side fallbacks apply. The host protocol supervisor, production asset
build/admission, launch, command authorization and per-API compatibility
are still pending. The candidate init cross-compiled for Linux aarch64 and
stage/transport tests used only synthetic inert data; no production VM boot
or catalog code execution was attempted.

### Nested launcher target

The isolated `KeylaneStoreGuest` product now exists as a one-shot helper.
It checks its own signature and fixed signed resource paths before opening a
bounded app IPC session. There is no path/command input for creating a VM:
the supervisor selects only build/run, a checked source entry and a session
UUID. It configures one fresh VM with a single virtio socket and no host shares,
storage or network, forwards run broker frames only to its app caller, limits
lifetime, and returns success/output only after confirmed VM stop. The app
caller must pin team/recipe, clear the helper environment, independently
validate output digest and bind broker authorization to a currently enabled
installation throughout execution. Wire: first stdin 4-byte big-endian length
then the full envelope; after that stdin/stdout exchange bounded JSON newline
frames. Build result uses ordered artifact frames; run result uses a stopped
receipt. The app-owned process driver and production asset lock are pending.

Native Swift compilation and both unsigned/unbundled rejection smoke cases
passed. The runner target has not been signed or booted against an actual
production asset yet. Keep the existing package opt-in disabled.

### App-owned helper transport and live authorization

`StoreGuestProcessDriver` resolves only the signed helper's sibling executable
after resource verification. It starts it with an empty inherited environment,
a private local socket and bounded framing; no extension supplies a launcher
path or process args. It independently checks build output size and SHA-256
and requires the helper's successful exit. No app permissions flow down.
The run adapter forwards only to `ExtensionPrototypeSession` and offers a
single, explicitly granted toast capability in this candidate. Every frame's
enabled installation generation is checked in the same MainActor turn as the
effect. An idle watchdog ends the helper when that generation is revoked.
Integrators must use app-owned live state, advancing its generation before
publishing a disable/permission change and withholding all grants by default.
The old API handshake's deliberately stale probe gets no guest reply.
Synthetic XCTest cases covered digest rejection, ungranted capability denial,
and revocation between requests. Real helper/VM wiring is still unqualified,
and no packager or application startup path is enabled by this code.

### Reproduce and sign a local candidate, not a qualified distribution

`python3 scripts/prepare_store_guest.py <existing-pinned-cache> <fresh-output>`
takes only the existing hash-checked Alpine kernel/modules, known Node
packages, ICU and pinned esbuild bytes; it stages the checked-in generic
Store receiver, init and repo-owned no-view broker adapter. No extension
sources or scripts are incorporated. The inputs are not downloaded. Build
in an app-owned scratch path with the reviewed Zig toolchain; run twice and
compare both Image and ingress.cpio before considering a change to the pin.
This command intentionally does not create a shipping lock or change the
packager opt-in. The no-view test recipe is not a compatibility assertion.

Local Mac candidate verification (2026-11-20, Zig 0.16.0): two builds from
the same pinned cache produced byte-identical Image and ingress.cpio (92
records). The archive inventory confirmed Linux arm64 init/esbuild/Node,
the four pinned virtio/vsock modules, four data transport modules, ICU, our
own API redirect and no third-party command or shell. The release SwiftPM
helper was nested in a scratch-only probe bundle; Apple Development signature
and strict nested verification passed before and after a ZIP roundtrip.
Only the nested helper held the virtualization entitlement. The actual
app-owned resource locator admitted the signed test recipe and rejected an
incorrect team and recipe. The image has not booted, the app-owned driver has
not yet performed a guest request in this image, and there is still no
production lock, API qualification, or released package. Verify a
repository-authored signed test roundtrip and revocation/cleanup before any
proposal to ship.

An exact scratch candidate sandbox-authorized roundtrip was attempted with a
self-authored TypeScript toast on the Mac. Strict bundle/runtime/harness
hash checks passed, but the app-owned driver returned an undifferentiated
helper failure before emitting a build digest. No guest boot, broker toast,
revocation, deadline, or VM stop was established for that attempt. No retry
was made. To diagnose a future authorized run, helper and driver now share
finite phase exit codes only; no guest output, locations or user data are
emitted as diagnostics. The driver also observes the actual helper process
exit after cooperative IPC shutdown (with a bounded TERM fallback). That
observation is independent of, and not a substitute for, the successful VM
stop receipt. Three focused Mac tests passed, including an inert child
cooperative exit, and the release helper returned only the expected
request/signature status codes for malformed and unsigned/unbundled input.

Follow-up: the signed diagnostic scratch run stopped generically before
starting the helper. A no-VM replay of its exact launch predicate reproduced
the false mismatch: Foundation URL objects differed despite the same regular
signed executable at the expected filesystem path. The resolver now uses
explicit path components and canonical filesystem-path checks, rejecting
symlinks. A signed, no-VM probe used the actual process driver path and socket
with intentional zero input; it reached the expected finite stdin/channel
status (66) and independently observed the helper exit. Four focused Mac
tests passed. This verifies the corrected launch/IPC boundary, not a VM boot
or Store extension execution.

Post-fix signed scratch Mac acceptance (2026-11-20, runtime `ccd0cc9`):
strict outer and nested signatures and the hashes of the exact helper, test
driver, Image and initramfs were checked before launch. The app-owned driver
built a two-file self-authored TypeScript project in a sealed build guest,
independently verified the bundle SHA-256
`5ad936bc59b1ae75490680055068ff04809008bf98407002afef26fbed81f75b`,
and ran it in a separate fresh guest. The app broker observed exactly one
synthetic toast. The helper returned its success receipt only after confirmed
VM stop and its own successful exit; the disabled generation rejected another
run before launch. The process exited 0. In-flight revocation and timeout/stop
have not yet been proven in this VM path. Neither a real catalog installation
nor a shipping build was tested; no default backend or package pin was enabled.

Candidate no-view launches now support bounded, app-selected string arguments
and an optional ordinary preference snapshot. The app must validate argument
names against the installed command, resolve ordinary preference defaults,
and exclude password/secret fields before constructing `StoreGuestLaunchContext`.
The guest only receives the args in a second sealed file; ordinary prefs are
read separately through the live session when explicitly granted. Its command
gets `{arguments: ...}`, not environment variables or executable arguments.
In addition to explicit toast, the candidate grants only opted-in string copy,
text-only HUD and ordinary preference read. HUD routing never honors extension
navigation preferences. Paste, clipboard read, view mode and LocalStorage
remain unavailable. Synthetic tests used an in-memory copy/HUD sink, never the
personal clipboard. Six focused native tests and eight Node groups passed;
the updated guest init cross-compiled. The preceding signed VM receipt predates
this wire revision, so the new image needs a new first-party signed test before
any catalog install acceptance. No SDK version is thereby qualified.

Context-v2 signed scratch Mac acceptance (2026-11-20, runtime `d05f6fc`):
Image, initramfs, exact helper and test harness digests plus strict outer and
nested signatures were checked before launch. In one isolated build guest
the app driver built only its own two-file TypeScript fixture (artifact
SHA-256 `a5d80f6e416b237033b4b2725aee4bad3f3b3d303f944c98d4a33e02d7c03a2d`).
A fresh run guest received the exact bounded string argument and ordinary
string/boolean/number preferences. Its in-memory broker sinks observed
one string copy and one plain HUD message; paste was denied and the guest
stopped successfully. After disabling the generation, a repeat request
was rejected before launch. Exit was 0. This did not touch the Mac pasteboard,
run a catalog extension, exercise in-flight revocation/timeout, or
qualify a production pin/API version.

Context-v2 in-flight revocation (separate signed synthetic fixture): the
build succeeded with artifact SHA-256
`78f2743fd7abbe8161e20d6f5087a25d19057953faafa9ad653748f1376e73aa`.
The run guest sent one ready HUD; the enabled generation was revoked while
it was running, and the in-memory sink recorded zero late copies. The
helper eventually emitted trusted exchange failure (69) after successful
Virtualization stop, and the app independently observed the helper process
exit. However run elapsed time was 31,170 ms and failed the <4 s prompt
teardown bar (probe exit 1). A stopped helper process alone is not a VM
stop receipt. This is evidence for late effect denial and eventual stop,
not prompt in-flight revocation acceptance. The timeout mode was not run.

The helper now checks the app socket every 25 ms without consuming broker
bytes, so app revocation can interrupt a silent guest rather than wait for
its next frame or the absolute deadline. It only returns the new finite
caller-closed status (72) after Virtualization confirms stop. If start/stop
callbacks do not acknowledge teardown within the bounded grace, it reports
teardown failure instead. The owned socket tests confirmed immediate EOF
detection and that queued broker frames remain byte-identical after repeated
checks. Eight focused Mac tests and helper typecheck passed. This change is
not a passing signed in-flight revocation or timeout receipt; no VM was
started for it.

Post-fix in-flight revocation acceptance (Mac, signed exact `bb2f4c8`): build
artifact SHA-256
`5633be947a25bcd7c6d5c168ae56dc9f5dfab251e113bd4083668034856bdd4e`;
the fresh run guest produced one ready HUD and then the app invalidated its
generation while the guest was running. The synthetic copy sink observed
zero late effects. The helper emitted caller-closed (72) only after its
Virtualization stop callback acknowledged success, and the app independently
observed the helper process exit. Invalidation to both confirmations was
29 ms (1,817 ms total run); probe exit 0. The test touched no system clipboard
and ran no catalog extension. The separate timeout mode remains unverified.

Deadline follow-up: the guest retains its independent 25-second PID1
watchdog; the host helper now requests and confirms teardown at its earlier
24-second absolute deadline, rather than waiting until 30 seconds for a
guest alarm or exchange failure. Socket poll timeout and peer closure are
classified separately, and an interrupted poll reuses the original deadline.
A worker that actually reaches the deadline propagates the same typed
timeout into the VM stop path; app peer closure still uses caller-closed.
Three owned-socket tests (nine focused Mac tests total) and a native helper
typecheck passed. This is not signed VM timeout acceptance; that remains a
separate authorized synthetic test.
