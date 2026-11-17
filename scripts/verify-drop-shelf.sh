#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneDropShelf.XXXXXX)"
if [[ "${1:-}" != "--prepare" ]]; then trap 'rm -rf "$task_directory"' EXIT; fi
source_directory="$task_directory/source"
app="$task_directory/Keylane Shelf Fixture.app"
mkdir -p "$source_directory/Tests/KeylaneCoreTests" "$app/Contents/MacOS" "$task_directory/home/Library/Preferences"
cp -R Package.swift Sources "$source_directory/"
cp Tests/KeylaneCoreTests/LauncherTests.swift "$source_directory/Tests/KeylaneCoreTests/"
python3 - "$source_directory" "$app" <<'PY'
import plistlib, sys, uuid
from pathlib import Path
main = Path(sys.argv[1]) / 'Sources/Keylane/main.swift'
source = main.read_text()
entry = 'let application = NSApplication.shared\nConfigurationTransfer.finishPending()\nlet delegate = Delegate()\napplication.delegate = delegate\napplication.run()\n'
if not source.endswith(entry):
    raise SystemExit('Update the fixture for the new Keylane entry point')
main.write_text(source.removesuffix(entry) + '\n' + Path('Tests/Integration/drop-shelf-main.swift').read_text())
(Path(sys.argv[2]) / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'org.keylane.test.drop-shelf.' + str(uuid.uuid4()),
    'CFBundleExecutable': 'verify', 'CFBundleName': 'Keylane Shelf Fixture', 'CFBundlePackageType': 'APPL',
}))
PY
export CLANG_MODULE_CACHE_PATH="$task_directory/cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_directory/cache"
swift build --package-path "$source_directory" --scratch-path "$task_directory/build" --disable-sandbox --product Keylane
cp "$task_directory/build/debug/Keylane" "$app/Contents/MacOS/verify"
codesign --force --sign - "$app"
provider_app="$task_directory/Keylane Promise Source.app"
mkdir -p "$provider_app/Contents/MacOS"
swiftc -swift-version 5 Tests/Integration/drop-shelf-source.swift -o "$provider_app/Contents/MacOS/provider"
python3 - "$provider_app" <<'PYPROVIDER'
import plistlib, sys, uuid
from pathlib import Path
(Path(sys.argv[1]) / 'Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'org.keylane.test.promise-source.' + str(uuid.uuid4()),
    'CFBundleExecutable': 'provider', 'CFBundleName': 'Keylane Promise Source', 'CFBundlePackageType': 'APPL',
}))
PYPROVIDER
codesign --force --sign - "$provider_app"
printf 'Promise source: %s\n' "$provider_app"
printf 'Fixture: %s\nRoot: %s\n' "$app" "$task_directory"
if [[ "${1:-}" != "--prepare" ]]; then
    /usr/bin/open -n -W --env "CFFIXED_USER_HOME=$task_directory/home" --env "KEYLANE_SHELF_FIXTURE=$task_directory" \
        --stdout "$task_directory/results.log" --stderr "$task_directory/errors.log" "$app"
    cat "$task_directory/results.log"
    if ! rg -q '^PASS production shelf integration' "$task_directory/results.log"; then
        cat "$task_directory/errors.log"
        exit 1
    fi
fi
