#!/bin/bash
# Production settings components, isolated defaults, no Model, services, or real cloud access.
set -euo pipefail
cd "$(dirname "$0")/.."
task_binary_directory="${KEYLANE_SYNC_BINARY_DIR:?Set KEYLANE_SYNC_BINARY_DIR to a completed Debug build directory}"
task_directory="$(mktemp -d /private/tmp/keylane-sync-ui.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
task_cyaml_include="$task_binary_directory/../../../checkouts/Yams/Sources/CYaml/include"
mkdir -p "$task_directory/Dependencies"
for task_dependency in KeylaneCore.o KeylaneProviderConfig.o Yams.o CYaml.o KeylaneCore.swiftmodule KeylaneProviderConfig.swiftmodule Yams.swiftmodule; do
    cp -RL "$task_binary_directory/$task_dependency" "$task_directory/Dependencies/$task_dependency"
done
task_binary_directory="$task_directory/Dependencies"
mkdir -p "${KEYLANE_SYNC_UI_EVIDENCE:?Set KEYLANE_SYNC_UI_EVIDENCE to the screenshot directory}"
python3 - "$task_directory/main.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('Sources/Keylane/main.swift').read_text()
entry = 'let application = NSApplication.shared\nConfigurationTransfer.finishPending()\nlet delegate = Delegate()\napplication.delegate = delegate\napplication.run()'
assert source.count(entry) == 1, 'Review fixture isolation after an application entry change'
fixture = pathlib.Path('Tests/Integration/icloud-sync-settings.swift').read_text()
pathlib.Path(sys.argv[1]).write_text(source.replace(entry, fixture))
PY
task_sources=()
for task_source in Sources/Keylane/*.swift; do
    [[ "$task_source" == "Sources/Keylane/main.swift" ]] || task_sources+=("$task_source")
done
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -module-name Keylane \
    -I "$task_binary_directory" -I "$task_cyaml_include" "${task_sources[@]}" "$task_directory/main.swift" \
    "$task_binary_directory/KeylaneCore.o" "$task_binary_directory/KeylaneProviderConfig.o" \
    "$task_binary_directory/Yams.o" "$task_binary_directory/CYaml.o" \
    -lsqlite3 -o "$task_directory/KeylaneSyncFixture"
task_app="$task_directory/KeylaneSyncFixture.app"
mkdir -p "$task_app/Contents/MacOS"
mv "$task_directory/KeylaneSyncFixture" "$task_app/Contents/MacOS/KeylaneSyncFixture"
python3 - "$task_app" <<'PY'
import pathlib, plistlib, subprocess, sys
sys.path.insert(0, 'scripts')
from signing import signing_identity
app = pathlib.Path(sys.argv[1])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleExecutable='KeylaneSyncFixture', CFBundleIdentifier='org.keylane.tests.icloud-sync',
    CFBundleName='Keylane Sync Preview', CFBundlePackageType='APPL', NSHighResolutionCapable=True)))
identity = signing_identity(require_apple_development=True)
subprocess.run(['codesign', '--force', '--sign', identity, '--timestamp=none', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
PY
export KEYLANE_SYNC_UI_IMAGE="$KEYLANE_SYNC_UI_EVIDENCE/icloud-sync-dark.png"
"$task_app/Contents/MacOS/KeylaneSyncFixture"
codesign --verify --deep --strict "$task_app"
test -s "$KEYLANE_SYNC_UI_IMAGE"
echo 'Isolated sync settings window captured; Apple Development signature verified; no installation or cloud access.'
