#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneFileActions.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
export KEYLANE_FILE_ACTION_TEST_ROOT="$task_directory"
mkdir -p "$task_directory/KeylaneOpenHelper.app/Contents/MacOS" "$task_directory/helper-source"
cp Tests/Integration/file-open-helper.swift "$task_directory/helper-source/main.swift"
swiftc -swift-version 5 -target "$(uname -m)-apple-macos26.0" "$task_directory/helper-source/main.swift" -o "$task_directory/KeylaneOpenHelper.app/Contents/MacOS/Helper"
python3 - "$task_directory" <<'PY'
import pathlib,plistlib,sys,uuid
p=pathlib.Path(sys.argv[1])/'KeylaneOpenHelper.app/Contents/Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.keylane.test.open.'+uuid.uuid4().hex,CFBundleName='KeylaneOpenHelper',CFBundleExecutable='Helper',CFBundlePackageType='APPL',LSUIElement=True,LSMinimumSystemVersion='26.0')))
PY
codesign --force --sign - "$task_directory/KeylaneOpenHelper.app"
cp Tests/Integration/file-actions-main.swift "$task_directory/main.swift"
swiftc -Xfrontend -disable-sandbox -swift-version 5 -target "$(uname -m)-apple-macos26.0" Sources/Keylane/FileActions.swift "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
