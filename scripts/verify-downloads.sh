#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/keylane-downloads-check.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/cache"
swiftc -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore \
    -emit-module-path "$task_directory/KeylaneCore.swiftmodule" Sources/KeylaneCore/IncomingFiles.swift -o "$task_directory/libKeylaneCore.dylib"
swiftc -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" \
    -lKeylaneCore -Xlinker -rpath -Xlinker "$task_directory" \
    Sources/Keylane/{ResultFileDrag,DownloadsController,FolderAccessScope,FolderChangeWatcher}.swift \
    Tests/Integration/downloads-main.swift -o "$task_directory/verify"
"$task_directory/verify"
