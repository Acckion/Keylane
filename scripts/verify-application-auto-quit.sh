#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/keylane-auto-quit-check.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
app="$task_directory/Keylane Auto Quit Fixture.app"
mkdir -p "$app/Contents/MacOS"
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos26.0" \
    -module-cache-path "$task_directory/cache" \
    Sources/Keylane/ApplicationAutoQuit.swift Tests/Integration/application-auto-quit-main.swift \
    -o "$task_directory/verify"
cp "$task_directory/verify" "$app/Contents/MacOS/verify"
python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib
import sys
import uuid

with open(sys.argv[1], "wb") as output:
    plistlib.dump({
        "CFBundleExecutable": "verify",
        "CFBundleIdentifier": f"org.keylane.auto-quit-fixture.{uuid.uuid4().hex}",
        "CFBundleName": "Keylane Auto Quit Fixture",
        "CFBundlePackageType": "APPL",
    }, output)
PY
codesign --force --sign - "$app"
printf 'Production source commit: %s\n' "$(git rev-parse HEAD)"
"$task_directory/verify" "$app"
