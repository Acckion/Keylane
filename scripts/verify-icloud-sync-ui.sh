#!/bin/bash
# Production settings components, isolated defaults, no Model, services, or real cloud access.
set -euo pipefail
cd "$(dirname "$0")/.."
task_binary_directory="${KEYLANE_SYNC_BINARY_DIR:?Set KEYLANE_SYNC_BINARY_DIR to a completed Debug build directory}"
task_directory="$(mktemp -d /private/tmp/keylane-sync-ui.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
task_cyaml_include="$task_binary_directory/../../../checkouts/Yams/Sources/CYaml/include"
task_object_directory="$task_binary_directory/../../Intermediates.noindex/Keylane.build/Debug/Keylane-p.build/Objects-normal/$(uname -m)"
mkdir -p "$task_directory/Dependencies" "${KEYLANE_SYNC_UI_EVIDENCE:?Set KEYLANE_SYNC_UI_EVIDENCE to the screenshot directory}"
python3 - "$task_object_directory" "$task_binary_directory" "$task_directory" <<'PYIN'
import pathlib, shlex, shutil, sys
objects, binary, task = map(pathlib.Path, sys.argv[1:])
deps = task / 'Dependencies'
paths = shlex.split((objects / 'Keylane.LinkFileList').read_text())
for source in map(pathlib.Path, paths):
    shutil.copy2(source, deps/source.name)
for source in [objects/'Keylane.swiftmodule', *(binary/name for name in ['KeylaneCore.swiftmodule', 'KeylaneProviderConfig.swiftmodule', 'Yams.swiftmodule'])]:
    target = deps/source.name
    if source.is_dir(): shutil.copytree(source, target)
    else: shutil.copy2(source, target)
(task/'objects.rsp').write_text('\n'.join(str(deps/pathlib.Path(p).name) for p in paths))
PYIN
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" -parse-as-library \
    -module-name KeylaneSyncFixture -I "$task_directory/Dependencies" -I "$task_cyaml_include" \
    Tests/Integration/icloud-sync-settings.swift @"$task_directory/objects.rsp" -lsqlite3 \
    -Xlinker -e -Xlinker _KeylaneSyncFixtureMain -o "$task_directory/KeylaneSyncFixture"
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
