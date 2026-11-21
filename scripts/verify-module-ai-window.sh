#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_binary_directory="${KEYLANE_AI_BINARY_DIR:?Set to the completed Debug build directory}"
task_directory="$(mktemp -d /private/tmp/keylane-module-ai-ui.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
task_objects="$task_binary_directory/../../Intermediates.noindex/Keylane.build/Debug/Keylane-p.build/Objects-normal/$(uname -m)"
mkdir -p "$task_directory/Dependencies" "${KEYLANE_AI_UI_EVIDENCE:?Set evidence directory}"
python3 - "$task_objects" "$task_binary_directory" "$task_directory" <<'PY'
from pathlib import Path
import shlex, shutil, sys
objects, binary, task = map(Path, sys.argv[1:])
paths=shlex.split((objects/'Keylane.LinkFileList').read_text())
deps=task/'Dependencies'
for p in map(Path, paths): shutil.copy2(p, deps/p.name)
for p in [objects/'Keylane.swiftmodule', *(binary/n for n in ['KeylaneCore.swiftmodule','KeylaneProviderConfig.swiftmodule','Yams.swiftmodule'])]:
    if p.is_dir(): shutil.copytree(p,deps/p.name)
    else: shutil.copy2(p,deps/p.name)
(task/'objects.rsp').write_text('\n'.join(str(deps/Path(p).name) for p in paths))
PY
task_compile_fixture() {
swiftc -D KEYLANE_LINKED_PRODUCTION_TEST -swift-version 5 -target "$(uname -m)-apple-macos26.0" -parse-as-library -module-name ModuleAIFixture \
    -I "$task_directory/Dependencies" -I "$task_binary_directory/../../../checkouts/Yams/Sources/CYaml/include" \
    "${KEYLANE_AI_FIXTURE_SOURCE:-Tests/Integration/module-ai-window.swift}" "$@" @"$task_directory/objects.rsp" -lsqlite3 \
    -Xlinker -e -Xlinker _KeylaneModuleAIFixtureMain -o "$task_directory/fixture"
}
if [[ -n "${KEYLANE_AI_FIXTURE_SUPPORT_SOURCE:-}" ]]; then task_compile_fixture "$KEYLANE_AI_FIXTURE_SUPPORT_SOURCE"; else task_compile_fixture; fi
task_app="$task_directory/ModuleAIFixture.app"
mkdir -p "$task_app/Contents/MacOS"
mv "$task_directory/fixture" "$task_app/Contents/MacOS/fixture"
python3 - "$task_app" <<'PY'
from pathlib import Path
import plistlib,subprocess,sys
sys.path.insert(0,'scripts')
from signing import signing_identity
app=Path(sys.argv[1])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='fixture',CFBundleIdentifier='org.keylane.tests.module-ai-window',CFBundleName='Keylane AI Fixture',CFBundlePackageType='APPL',NSHighResolutionCapable=True)))
identity=signing_identity(require_apple_development=True)
subprocess.run(['codesign','--force','--sign',identity,'--timestamp=none',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
PY
"$task_app/Contents/MacOS/fixture"
codesign --verify --deep --strict "$task_app"
echo 'Apple Development verified before/after; original app main not run; no installation.'
