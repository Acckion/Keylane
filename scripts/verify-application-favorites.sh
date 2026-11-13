#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneApplicationFavorites.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
source_directory="$task_directory/source"
app="$task_directory/Fixture.app"
mkdir -p "$source_directory/Tests/KeylaneCoreTests" "$app/Contents/MacOS" "$task_directory/home/Library/Preferences"
cp -R Package.swift Sources "$source_directory/"
cp Tests/KeylaneCoreTests/LauncherTests.swift "$source_directory/Tests/KeylaneCoreTests/"
# Keep the production model and action handlers, replacing only the app's entry point.
python3 - "$source_directory" "$app" <<'PY'
import plistlib
import sys
import uuid
from pathlib import Path

main = Path(sys.argv[1]) / "Sources/Keylane/main.swift"
source = main.read_text()
entry_point = "let delegate = Delegate()\nNSApplication.shared.delegate = delegate\nNSApplication.shared.run()\n"
if not source.endswith(entry_point):
    raise SystemExit("Update the fixture for the new Keylane entry point")
main.write_text(source.removesuffix(entry_point) + "\n" + Path("Tests/Integration/application-favorites-main.swift").read_text())
(Path(sys.argv[2]) / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "org.keylane.test.application-favorites." + str(uuid.uuid4()),
    "CFBundleExecutable": "verify",
    "CFBundlePackageType": "APPL",
    "LSUIElement": True,
}))
PY
swift build --package-path "$source_directory" --scratch-path "$task_directory/build" --disable-sandbox --product Keylane
cp "$task_directory/build/debug/Keylane" "$app/Contents/MacOS/verify"
CFFIXED_USER_HOME="$task_directory/home" "$app/Contents/MacOS/verify"
