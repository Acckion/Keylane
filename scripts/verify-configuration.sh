#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneConfiguration.XXXXXX)"
task_suite="org.keylane.configuration-fixture.$(uuidgen)"
task_app="$task_directory/ConfigurationDemo.app"
task_binary="$task_app/Contents/MacOS/ConfigurationDemo"
cleanup() {
    local task_status=$?
    if [[ -x "$task_binary" ]]; then
        if ! "$task_binary" cleanup "$task_suite" "$task_directory"; then task_status=1; fi
    fi
    rm -rf "$task_directory"
    exit "$task_status"
}
trap cleanup EXIT
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Frameworks"
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
swiftc -package-name Keylane -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_app/Contents/Frameworks/libKeylaneCore.dylib"
cp Tests/Integration/configuration-main.swift "$task_directory/main.swift"
swiftc -package-name Keylane -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_app/Contents/Frameworks" -lKeylaneCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks Sources/Keylane/ShortcutManager.swift Sources/Keylane/ConfigurationTransfer.swift Tests/Integration/configuration-ui-stubs.swift "$task_directory/main.swift" -o "$task_binary"
python3 - "$task_app/Contents/Info.plist" "$task_suite" <<'PY'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps(dict(CFBundleExecutable='ConfigurationDemo', CFBundleIdentifier=sys.argv[2], CFBundleName='Configuration Demo', CFBundlePackageType='APPL', LSUIElement=True, LSMinimumSystemVersion='26.0')))
PY
codesign --force --sign - --timestamp=none "$task_app"
for phase in seed no-pending stage apply hotkeys cancel-next undo preview-ui-light preview-ui-dark startup-failure preparation-ui; do
    "$task_binary" "$phase" "$task_suite" "$task_directory"
done
