#!/bin/bash
# Expects the pinned kernel.apk, apks/ and npm/ archives in the scratch directory.
set -euo pipefail
test "$#" -le 2 || { echo "usage: verify.sh scratch-directory [pinned-formatUuid.ts]" >&2; exit 2; }
scratch=$(cd "${1:?usage: verify.sh scratch-directory}" && pwd -P)
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../../.." && pwd -P)

xcrun swiftc -swift-version 5 -module-cache-path "$scratch/swift-cache" \
    "$repo/Sources/KeylaneCore/ExtensionPrototypeSession.swift" "$here/Host.swift" -o "$scratch/host"
cat > "$scratch/virtualization.plist" <<'PLIST'
<plist version="1.0"><dict><key>com.apple.security.virtualization</key><true/></dict></plist>
PLIST
codesign --force --sign "${KEYLANE_VM_SIGN_IDENTITY:--}" --timestamp=none --options runtime     --entitlements "$scratch/virtualization.plist" "$scratch/host"
codesign --verify --strict "$scratch/host"
codesign -dvv "$scratch/host" 2>&1 | grep 'flags=.*runtime' >/dev/null

sentinel=$(mktemp "$scratch/host-sentinel.XXXXXX")
tamper=$(mktemp -d "$scratch/tamper.XXXXXX")
trap 'rm -f "$sentinel"; rm -rf "$tamper"' EXIT
printf 'host-only-synthetic\n' > "$sentinel"

boot() {
    "$scratch/host" "$scratch/Image" "$scratch/$1.cpio" "$sentinel" "$2" "$3" \
        > "$scratch/$2.out" 2> "$scratch/$2.log"
}

python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" probe
boot probe probe loopback-only-host-file-absent
if boot probe stall unused; then
    echo 'stall unexpectedly succeeded' >&2
    exit 1
fi
grep -q 'keylane: intentionally waiting' "$scratch/stall.log"
grep -q 'guest deadline expired' "$scratch/stall.log"
grep -q 'guest probe failed, .*state=0' "$scratch/stall.out"
python3 "$here/verify_host_exit.py" "$scratch" "$sentinel"

reject() {
    local mode=$1 reason=$2 marker=$3
    if boot probe "$mode" unused; then
        echo "$mode unexpectedly succeeded" >&2
        exit 1
    fi
    grep -q "$marker" "$scratch/$mode.log"
    grep -q "guest protocol: $reason" "$scratch/$mode.log"
    grep -q 'guest probe failed, .*state=0' "$scratch/$mode.out"
}
reject malformed malformed 'sending malformed frame'
reject oversize limit 'sending oversized frame'
reject replay malformed 'replaying request ID'
reject partial malformed 'sending partial frame'
echo 'virtio: rejected malformed, oversized, replayed and partial frames'

mkdir "$tamper/npm"
ln -s "$scratch/apks" "$tamper/apks"
ln -s "$scratch/zig-cache" "$tamper/zig-cache"
for package in esbuild.tgz uuid.tgz; do
    rm -f "$tamper/npm/esbuild.tgz" "$tamper/npm/uuid.tgz"
    for candidate in esbuild.tgz uuid.tgz; do
        if test "$candidate" = "$package"; then
            printf 'modified package\n' > "$tamper/npm/$candidate"
        else
            ln -s "$scratch/npm/$candidate" "$tamper/npm/$candidate"
        fi
    done
    if python3 "$here/prepare.py" "$scratch/kernel.apk" "$tamper" build > "$tamper/check.log" 2>&1; then
        echo "modified $package unexpectedly accepted" >&2
        exit 1
    fi
    grep -Fq "SHA-256 mismatch: $package" "$tamper/check.log"
    test ! -e "$tamper/build.cpio"
done
echo 'integrity: rejected modified esbuild and uuid before guest boot'

python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" build
boot build build -
sed -n 's/^guest-result=//p' "$scratch/build.out" | base64 -D > "$scratch/built.cjs"
test -s "$scratch/built.cjs"

python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" run "$scratch/built.cjs"
expected_uuid=$(python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS, "Keylane extension fixture"))')
boot run run "$(printf '%s' "$expected_uuid" | base64)"
grep -q 'build spawn denied, worker thread passed' "$scratch/build.log"
grep -q 'run spawn denied, worker thread passed' "$scratch/run.log"
test "$(cat "$sentinel")" = host-only-synthetic
grep -h "^guest probe passed" "$scratch/probe.out" "$scratch/build.out" "$scratch/run.out"
printf 'offline bundle: %s bytes, runtime UUID %s\n' "$(wc -c < "$scratch/built.cjs" | tr -d ' ')" "$expected_uuid"
echo 'stall: deadline reached and VM stopped'

if test "$#" -eq 2; then
    python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" uuid-build "$2"
    boot uuid-build uuid-build -
    sed -n 's/^guest-result=//p' "$scratch/uuid-build.out" | base64 -D > "$scratch/uuid-format.cjs"
    python3 "$here/prepare.py" "$scratch/kernel.apk" "$scratch" noview "$scratch/uuid-format.cjs"

    boot noview noview-wire node-confirmed
    grep -q '^guest-result=node-confirmed' "$scratch/noview-wire.out"
    echo 'no-view: Node received correlated result and permission error through virtio'
    python3 "$here/verify_host_exit.py" "$scratch" "$sentinel" no-view

    for mode in log-flood noview-flood; do
        image=probe
        limit='guest serial output limit'
        if test "$mode" = noview-flood; then
            image=noview
            limit='guest protocol output limit'
        fi
        if boot "$image" "$mode" unused; then
            echo "$mode unexpectedly succeeded" >&2
            exit 1
        fi
        grep -q "$limit" "$scratch/$mode.log"
        grep -q 'guest probe failed, .*state=0' "$scratch/$mode.out"
        test "$(wc -c < "$scratch/$mode.log")" -lt 34000
    done
    if boot noview noview-backpressure unused; then
        echo 'reply backpressure unexpectedly succeeded' >&2
        exit 1
    fi
    grep -q 'Node withholding reply reads' "$scratch/noview-backpressure.log"
    grep -Eq 'guest protocol output limit|guest deadline expired' "$scratch/noview-backpressure.log"
    grep -q 'guest probe failed, .*state=0' "$scratch/noview-backpressure.out"
    echo 'limits: serial flood, protocol flood and reply backpressure stopped their VMs'

    boot noview noview-copy node-confirmed
    boot noview noview-denied node-confirmed
    python3 - "$scratch" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
def events(phase):
    return [json.loads(line.removeprefix("broker-event "))
            for line in (root / f"{phase}.log").read_text().splitlines()
            if line.startswith("broker-event ")]

uuid = "550e8400-e29b-41d4-a716-446655440000"
copy = events("noview-copy")
denied = events("noview-denied")
if copy != [
    {"capability": "clipboard.copy", "text": uuid},
    {"capability": "feedback.hud", "text": f"✅ Copied formatted UUID: {uuid}"},
]:
    raise SystemExit(f"unexpected copy events: {copy!r}")
if len(denied) != 1 or denied[0]["capability"] != "feedback.toast" or (
    "Capability unavailable for this command" not in denied[0]["text"]
):
    raise SystemExit(f"unexpected denied events: {denied!r}")
print(f"UUID Generator formatUuid: copied {uuid} to named pasteboard; paste denied and reported")
PY

    input_uuid=550e8400e29b41d4a716446655440000
    formatted_uuid=550e8400-e29b-41d4-a716-446655440000
    for action in copy paste; do
        printf '{"defaultAction":"%s","upperCaseLetters":false}' "$action" |
            "$scratch/host" "$scratch/Image" "$scratch/noview.cpio" "$sentinel" noview-app "$action:$formatted_uuid" "$input_uuid" \
                > "$scratch/noview-preferences-$action.out" 2> "$scratch/noview-preferences-$action.log"
        grep -Fxq "guest-result=$action:$formatted_uuid" "$scratch/noview-preferences-$action.out"
        grep -q '^guest probe passed, .*state=0' "$scratch/noview-preferences-$action.out"
    done
    echo 'preferences: the same signed guest honored both copy and paste'

fi
