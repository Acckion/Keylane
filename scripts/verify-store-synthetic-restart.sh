#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
build_log="$(mktemp /private/tmp/keylane-store-synthetic-build.XXXXXX)"
swift test --disable-sandbox --filter 'RaycastStoreMacProfileReservationTests.testFinalizedReservationAndSelectedReadbackGiveSameLiveOwner' >"$build_log" 2>&1
suite="$(swift build --show-bin-path)/KeylaneCoreTests.xctest"
caseName=KeylaneCoreTests.RaycastStoreMacProfileReservationTests/testProcessIsolatedSelectedReadback
snapshot() {
    find "$scratch/profiles" "$scratch/slots" -type f -print | LC_ALL=C sort |
        while IFS= read -r file; do /usr/bin/shasum -a 256 "$file"; done
}
for state in enabled disabled; do
    scratch="$(mktemp -d /private/tmp/keylane-store-synthetic-restart.XXXXXX)"
    printf 'Synthetic restart receipts (%s): %s\n' "$state" "$scratch"
    cp "$build_log" "$scratch/build.log"
    KEYLANE_SYNTHETIC_RESTART_EXPECTATION="$state" KEYLANE_SYNTHETIC_RESTART_ROOT="$scratch" KEYLANE_SYNTHETIC_RESTART_PHASE=publish \
    /usr/bin/xcrun xctest -XCTest "$caseName" "$suite" >"$scratch/publish.log" 2>&1
    snapshot >"$scratch/before.sha"
    KEYLANE_SYNTHETIC_RESTART_EXPECTATION="$state" KEYLANE_SYNTHETIC_RESTART_ROOT="$scratch" KEYLANE_SYNTHETIC_RESTART_PHASE=readback \
    /usr/bin/xcrun xctest -XCTest "$caseName" "$suite" >"$scratch/readback.log" 2>&1
    snapshot >"$scratch/after.sha"
    cmp "$scratch/before.sha" "$scratch/after.sha"
    grep -E 'synthetic-.*pid|Executed' "$scratch/publish.log" "$scratch/readback.log"
done
