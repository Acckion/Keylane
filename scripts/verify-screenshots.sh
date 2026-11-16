#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/keylane-screenshot-check.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
task_target="$(uname -m)-apple-macos26.0"
export CLANG_MODULE_CACHE_PATH="$task_directory/cache"
swiftc -target "$task_target" -emit-library -emit-module -module-name KeylaneCore \
    -emit-module-path "$task_directory/KeylaneCore.swiftmodule" \
    Sources/KeylaneCore/{ScreenshotCatalog,SettingsCatalog}.swift -o "$task_directory/libKeylaneCore.dylib"
swiftc -Xfrontend -disable-sandbox -target "$task_target" -I "$task_directory" -L "$task_directory" \
    -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" \
    Sources/Keylane/{ScreenshotLibrary,FolderChangeWatcher,ImageTextRecognition,ResultGrid,ResultList,VisualStyle}.swift \
    Tests/Integration/screenshot-library-main.swift -o "$task_directory/verify"
"$task_directory/verify"
