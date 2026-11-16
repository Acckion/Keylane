#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneApplicationMenu.XXXXXX)"
if [[ "${1:-}" != "--interactive" && "${1:-}" != "--prepare" ]]; then trap 'rm -rf "$task_directory"' EXIT; fi
source_directory="$task_directory/source"
app="$task_directory/Keylane Menu Verification.app"
mkdir -p "$source_directory/Tests/KeylaneCoreTests" "$app/Contents/MacOS" "$task_directory/home/Library/Preferences"
cp -R Package.swift Sources "$source_directory/"
cp Tests/KeylaneCoreTests/LauncherTests.swift "$source_directory/Tests/KeylaneCoreTests/"
python3 - "$source_directory" "$app" <<'PY'
import plistlib, sys, uuid
from pathlib import Path
main = Path(sys.argv[1]) / 'Sources/Keylane/main.swift'
source = main.read_text()
entry = 'let delegate = Delegate()\nNSApplication.shared.delegate = delegate\nNSApplication.shared.run()\n'
if not source.endswith(entry):
    raise SystemExit('Update the fixture for the new Keylane entry point')
main.write_text(source.removesuffix(entry) + '\n' + Path('Tests/Integration/application-menu-ui-main.swift').read_text())
(Path(sys.argv[2]) / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'org.keylane.test.application-menu.' + str(uuid.uuid4()),
    'CFBundleExecutable': 'verify', 'CFBundleName': 'Keylane Menu Verification', 'CFBundlePackageType': 'APPL',
}))
PY
export CLANG_MODULE_CACHE_PATH="$task_directory/cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_directory/cache"
swift build --package-path "$source_directory" --scratch-path "$task_directory/build" --disable-sandbox --product Keylane
cp "$task_directory/build/debug/Keylane" "$app/Contents/MacOS/verify"
printf 'Fixture: %s\n' "$app"
if [[ "${1:-}" != "--prepare" ]]; then
    /usr/bin/open -n -W --env "CFFIXED_USER_HOME=$task_directory/home" \
        --stdout "$task_directory/results.log" --stderr "$task_directory/errors.log" "$app" --args "${1:-}"
    cat "$task_directory/results.log"
    if [[ "${1:-}" != "--interactive" ]]; then
        python3 - "$task_directory/results.log" <<'PYTEST'
from pathlib import Path
import sys
expected = "PASS application menu UI regression checks (synthetic native composition; physical IME still requires manual acceptance)"
if expected not in Path(sys.argv[1]).read_text().splitlines():
    raise SystemExit("UI assertions did not finish successfully; see the preceding output")
PYTEST
    fi
else
    printf 'Home: %s\n' "$task_directory/home"
fi
