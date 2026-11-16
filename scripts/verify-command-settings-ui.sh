#!/bin/bash
# Interactive native fixture, not an assertion that installed-app acceptance passed.
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/keylane-command-settings.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$PWD/.build-current/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
swift build --scratch-path .build-current --disable-sandbox
task_binary_directory="$(swift build --scratch-path .build-current --show-bin-path --disable-sandbox)"
python3 - "$task_directory/main.swift" <<'PY'
import pathlib
import sys

source = pathlib.Path("Sources/Keylane/main.swift").read_text()
entry = "let delegate = Delegate()\nNSApplication.shared.delegate = delegate\nNSApplication.shared.run()"
assert source.count(entry) == 1, "App entry changed; review fixture isolation before running"
fixture = pathlib.Path("Tests/Integration/command-settings-disclosure.swift").read_text()
pathlib.Path(sys.argv[1]).write_text(source.replace(entry, fixture))
PY
task_sources=()
for task_source in Sources/Keylane/*.swift; do
    [[ "$task_source" == "Sources/Keylane/main.swift" ]] || task_sources+=("$task_source")
done
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" \
    -module-name Keylane -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -I "$task_binary_directory" "${task_sources[@]}" "$task_directory/main.swift" \
    "$task_binary_directory/KeylaneCore.o" -lsqlite3 -o "$task_directory/KeylaneDisclosureFixture"
task_app="$task_directory/KeylaneDisclosureFixture.app"
mkdir -p "$task_app/Contents/MacOS"
mv "$task_directory/KeylaneDisclosureFixture" "$task_app/Contents/MacOS/KeylaneDisclosureFixture"
python3 - "$task_app/Contents/Info.plist" <<'PY'
import pathlib
import plistlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleExecutable": "KeylaneDisclosureFixture",
    "CFBundleIdentifier": "org.keylane.tests.command-disclosure",
    "CFBundleName": "Keylane Disclosure Fixture",
    "CFBundlePackageType": "APPL",
    "NSHighResolutionCapable": True,
}))
PY
"$task_app/Contents/MacOS/KeylaneDisclosureFixture"
