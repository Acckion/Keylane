#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_directory="$(mktemp -d /private/tmp/KeylaneFilesIntegration.XXXXXX)"
trap 'rm -rf "$task_directory"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_directory/modules"
export KEYLANE_FILE_TEST_ROOT="$task_directory"
swift_optimization=-Onone
if [[ "${KEYLANE_FILE_TEST_RELEASE:-0}" == "1" ]]; then swift_optimization=-O; fi
swiftc "$swift_optimization" -package-name Keylane -swift-version 5 -target "$(uname -m)-apple-macos26.0" -emit-library -emit-module -module-name KeylaneCore Sources/KeylaneCore/*.swift -lsqlite3 -emit-module-path "$task_directory/KeylaneCore.swiftmodule" -o "$task_directory/libKeylaneCore.dylib"
cp "${KEYLANE_FILE_TEST_SOURCE:-Tests/Integration/files-main.swift}" "$task_directory/main.swift"
swiftc "$swift_optimization" -package-name Keylane -D KEYLANE_FILE_EVENT_TESTING -swift-version 5 -target "$(uname -m)-apple-macos26.0" -I "$task_directory" -L "$task_directory" -lKeylaneCore -lsqlite3 -Xlinker -rpath -Xlinker "$task_directory" Sources/Keylane/AIFileToolIndexSource.swift Sources/Keylane/FileSearchController.swift "$task_directory/main.swift" -o "$task_directory/verify"
"$task_directory/verify"
